# JDO Tweak - library generator
# Builds Data\library.json for the app from:
#   1. analysis\settings.csv  -> one "option" tweak per popular setting, values ordered by popularity (best first)
#   2. E:\JDO_CLEAN\Tweaks / Network -> one "bundle" tweak per cleaned pack file
# Usage: powershell -File gen_catalog.ps1 -Settings settings.csv -Clean E:\JDO_CLEAN -Out library.json
param([string]$Settings, [string]$Clean, [string]$Out, [int]$MinPacks = 4)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue

# ---------- categories ----------
$catRules = [ordered]@{
  advanced = '(?i)defender|smartscreen|deviceguard|enablelua|\buac\b|featuresettingsoverride|mitigation|sehop|firewall|securityhealth|wscsvc|hvci|\bvbs\b|tamper|windowsupdate|wuauserv|usosvc|waasmedic|exploit|spectre|meltdown|DisableAntiSpyware|MpPreference'
  mouse    = '(?i)mouse|mouclass|pointer|smoothmouse|cursor|\bdpi\b'
  keyboard = '(?i)keyboard|kbdclass|stickykeys|togglekeys|keyboard response|filterkeys'
  network  = '(?i)\\tcpip|psched|lanman|\\afd\\|ndis|netsh|ping|network|ethernet|wifi|wi-fi|dns|tcp|udp|nagle|internet|\\dnscache|\{4d36e972|qos|winsock|bandwidth|adapter'
  gpu      = '(?i)nvidia|nvlddmkm|\bamd\b|radeon|graphicsdrivers|\\dwm|\{4d36e968|directx|direct3d|\bgpu\b|nvcpl|nvtweak|igfx|intel graphics|\bhags\b|\bmpo\b|overlay|vsync|shader'
  power    = '(?i)power|powercfg|throttl|hibernat|powersettings|coalescingtimer|latencytolerance|\bidle\b|c-state|cstate|parking|\.pow\b'
  cpu      = '(?i)prioritycontrol|win32priorityseparation|processor|\bcpu\b|kernel\\|distributetimers|threaddpc|dpcwatchdog|\bcore(s)?\b|affinity|scheduler|priority'
  ram      = '(?i)memory management|memory|\bram\b|pagingfiles|pagefile|svchost|sysmain|superfetch|prefetch|mmagent|standby'
  latency  = '(?i)latency|delay|timer|\bdpc\b|interrupt|\bmsi\b|\birq\b|input lag|responsiveness|\bhpet\b|tick'
  gaming   = '(?i)\bgame|gamedvr|gamebar|gameconfigstore|fortnite|valorant|\bfps\b|\bcs2\b|csgo|warzone|apex|minecraft|roblox|steam|epic|rust|cod\b|pubg|overwatch|league'
  privacy  = '(?i)telemetry|datacollection|privacy|advertisinginfo|diagtrack|siuf|activity|location|capabilityaccessmanager|tracking|cortana|feedback|ceip|sqm|census'
  storage  = '(?i)fsutil|ntfs|\bdisk\b|storage|\bssd\b|\btrim\b|defrag|storport|8dot3|lastaccess|\bnvme\b|\bhdd\b'
  windows  = '(?i)services|contentdeliverymanager|explorer|appx|bloat|clean|visual|animation|themes|search|edge|onedrive|widget|copilot|start menu|taskbar|notification|startup|debloat'
}
function CatOf([string]$name, [string]$body) {
  $best = 'windows'; $score = 0
  foreach ($c in $catRules.Keys) {
    $s = ([regex]::Matches($name, $catRules[$c])).Count * 6 + [Math]::Min(([regex]::Matches($body, $catRules[$c])).Count, 30)
    if ($s -gt $score) { $score = $s; $best = $c }
  }
  return $best
}
$riskHigh = '(?i)defender|smartscreen|deviceguard|enablelua|featuresettingsoverride|mitigation|sehop|firewall|securityhealth|hvci|tamper|DisableAntiSpyware|wuauserv|usosvc|windowsupdate|takeown|icacls|\bdel\b .*system32|format |diskpart'
$riskMid  = '(?i)\\services\\[^\\]+\\start\b|sc(\.exe)? +config|start= *disabled|threadpriority|preemption|bcd|Remove-Appx|appxpackage|uninstall'

# ---------- device-specific keys -> apply to every matching subkey ----------
function MapKey([string]$k) {
  if ($k -match '^(?i)HKEY_USERS\\S-1-') { return $null }                    # someone else's user profile
  if ($k -match '(?i)\\Enum\\') { return $null }                              # one specific physical device
  if ($k -match '^(?i)(.+\\Tcpip6?\\Parameters\\Interfaces)\\\{[0-9a-f-]+\}$') { return @{ each = $matches[1] } }
  if ($k -match '^(?i)(.+\\Control\\Class\\\{[0-9a-f-]+\})\\\d{4}$') { return @{ each = $matches[1] } }
  if ($k -match '(?i)\\Interfaces\\\{[0-9a-f-]+\}\\|\\Class\\\{[0-9a-f-]+\}\\\d{4}\\') { return $null }
  if ($k -match '(?i)\\ControlSet00\d\\') { $k = $k -replace '(?i)\\ControlSet00\d\\', '\CurrentControlSet\' }
  return @{ reg = $k }
}
function ValueAction($map, [string]$name, [string]$type, [string]$data) {
  $a = @{}
  foreach ($kv in $map.GetEnumerator()) { $a[$kv.Key] = $kv.Value }
  $a.n = $name
  switch ($type) {
    'REG_DWORD'     { $v = 0L; if ($data -match '^0x') { $v = [Convert]::ToInt64($data.Substring(2),16) } elseif (-not [long]::TryParse($data, [ref]$v)) { if ($data -match '^[0-9a-fA-F]{1,8}$') { $v = [Convert]::ToInt64($data,16) } else { return $null } }; $a.dw = $v }
    'REG_QWORD'     { $v = 0L; if (-not [long]::TryParse($data, [ref]$v)) { return $null }; $a.qw = $v }
    'REG_SZ'        { $a.sz = $data }
    'REG_EXPAND_SZ' { $a.esz = $data }
    'REG_BINARY'    { if ($data -notmatch '^[0-9a-fA-F,]*$') { return $null }; $a.bin = $data }
    'REG_MULTI_SZ'  { $a.msz = $data }
    'DELETE'        { $a.del = $true }
    default         { return $null }
  }
  return $a
}
function Words([string]$s) {
  $s = $s -replace '([a-z])([A-Z])', '$1 $2' -replace '([A-Z]+)([A-Z][a-z])', '$1 $2' -replace '[_\-]+', ' '
  return ($s -replace '\s+', ' ').Trim()
}

$tweaks = New-Object System.Collections.ArrayList
$ids = New-Object 'System.Collections.Generic.HashSet[string]'
$stats = [ordered]@{ optionTweaks=0; optionChoices=0; bundleTweaks=0; bundleActions=0; scriptBundles=0; skippedInteractive=0; skippedEmpty=0; skippedForeignKeys=0 }

# ---------- 1. option tweaks ----------
Write-Host 'options...'
foreach ($r in Import-Csv $Settings) {
  if ([int]$r.Packs -lt $MinPacks) { continue }
  if ($r.Name -eq '(delete key)') { continue }
  $map = MapKey $r.Key
  if (-not $map) { $stats.skippedForeignKeys++; continue }
  $opts = New-Object System.Collections.ArrayList
  $seenV = @{}
  foreach ($part in ($r.AllValues -split ' \| ')) {
    if ($part -notmatch '^(\w+)=(.*) x(\d+)$') { continue }
    $type = $matches[1]; $data = $matches[2]; $cnt = [int]$matches[3]
    if ($cnt -lt 2 -and $opts.Count -gt 0) { continue }
    $a = ValueAction $map $r.Name $type $data
    if (-not $a) { continue }
    $label = if ($type -eq 'DELETE') { 'Delete value' } elseif ($type -eq 'REG_BINARY') { 'Binary preset ' + ($opts.Count + 1) } else { "$data" }
    if ($seenV.ContainsKey($label)) { continue }; $seenV[$label] = 1
    if ($label.Length -gt 40) { $label = $label.Substring(0, 37) + '...' }
    if ($opts.Count -eq 0) { $label = "$label  ★" }
    [void]$opts.Add(@{ ar = $label; en = $label; uses = $cnt; apply = @($a) })
    if ($opts.Count -ge 8) { break }
  }
  if ($opts.Count -eq 0) { continue }
  [void]$opts.Add(@{ ar = 'الأصلي (قيمة جهازك)'; en = 'Original (your PC value)'; def = $true; apply = @() })
  $leaf = ($r.Key -split '\\')[-1]
  $title = (Words $r.Name)
  if ($r.Name -eq '(Default)' -or $title.Length -lt 4) { $title = (Words $leaf) + ' ' + $title }
  $id = 'opt.' + ($r.Key + '|' + $r.Name).ToLower().GetHashCode().ToString('x8')
  if (-not $ids.Add($id)) { continue }
  $packs = [int]$r.Packs
  $body = "$($r.Key)\$($r.Name)"
  [void]$tweaks.Add(@{
    id = $id; cat = (CatOf $title $body); tier = $(if ($packs -ge 30) { 1 } elseif ($packs -ge 10) { 2 } else { 3 })
    risk = $(if ($body -match $riskHigh) { 2 } elseif ($body -match $riskMid) { 1 } else { 0 })
    ar = $title; en = $title
    dar = "$leaf  ·  يستخدمه $packs باك تويك. الخيارات مرتبة من الأكثر استخداماً."
    den = "$leaf  ·  Used by $packs tweak packs. Options are ordered by popularity."
    path = $body; packs = $packs; options = $opts.ToArray()
  })
  $stats.optionTweaks++; $stats.optionChoices += $opts.Count - 1
}

# ---------- 2. bundle tweaks from cleaned pack files ----------
function CleanName([string]$file) {
  $n = [IO.Path]::GetFileNameWithoutExtension($file)
  $n = $n -replace '^\s*[\[\(]?\d{1,3}[\]\)\.\-_ ]+\s*', '' -replace '(?i)\(\s*run as admin(istrator)?\s*\)', '' -replace '(?i)\b(by|made by|from) [\w\.]+$', '' -replace '[_]+', ' '
  $n = ($n -replace '\s+', ' ').Trim(' ', '-', '.')
  if ($n.Length -lt 3) { $n = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($file)) + ' ' + $n }
  return $n
}
$interactive = '(?im)^\s*(set\s+/p\b|choice\b|.*\bRead-Host\b|.*\$host\.UI\.PromptForChoice)'
$names = @{}
foreach ($tree in 'Tweaks', 'Network') {
  $root = Join-Path $Clean $tree
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Write-Host "bundles: $tree..."
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File) {
    $ext = $f.Extension.ToLower()
    $rel = $f.FullName.Substring($root.Length + 1)
    $pack = ($rel -split '\\')[0]
    $name = CleanName $f.FullName
    $acts = New-Object System.Collections.ArrayList
    $text = [IO.File]::ReadAllText($f.FullName)
    if ($ext -eq '.reg') {
      $key = $null; $map = $null
      foreach ($line in $text -split "\r?\n") {
        $l = $line.Trim()
        if ($l -match '^\[(-?)(.+)\]$') {
          $key = $matches[2]; $map = MapKey $key
          if ($matches[1] -eq '-') { if ($map -and $map.reg) { [void]$acts.Add(@{ reg = $map.reg; delkey = $true }) }; $key = $null }
          continue
        }
        if (-not $key -or -not $map) { continue }
        if ($l -notmatch '^(@|"((?:[^"\\]|\\.)*)")\s*=\s*(.*)$') { continue }
        $vn = if ($matches[1] -eq '@') { '' } else { $matches[2] -replace '\\\\', '\' }
        $raw = $matches[3]; $a = $null
        if ($raw -eq '-') { $a = ValueAction $map $vn 'DELETE' '' }
        elseif ($raw -match '^dword:([0-9a-fA-F]+)') { $a = ValueAction $map $vn 'REG_DWORD' ('0x' + $matches[1]) }
        elseif ($raw -match '^hex\(b\):(.*)') { $b = $matches[1] -split ',' | Where-Object { $_ }; $nn = [UInt64]0; for ($i = $b.Count - 1; $i -ge 0; $i--) { $nn = $nn * 256 + [Convert]::ToUInt64($b[$i], 16) }; $a = ValueAction $map $vn 'REG_QWORD' ([string][BitConverter]::ToInt64([BitConverter]::GetBytes([UInt64]$nn), 0)) }
        elseif ($raw -match '^hex\(2\):(.*)') { $a = ValueAction $map $vn 'REG_EXPAND_SZ' ([Text.Encoding]::Unicode.GetString([byte[]]($matches[1] -split ',' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })).TrimEnd([char]0)) }
        elseif ($raw -match '^hex\(7\):(.*)') { $a = ValueAction $map $vn 'REG_MULTI_SZ' ([Text.Encoding]::Unicode.GetString([byte[]]($matches[1] -split ',' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })).TrimEnd([char]0)) }
        elseif ($raw -match '^hex:(.*)') { $a = ValueAction $map $vn 'REG_BINARY' $matches[1] }
        elseif ($raw -match '^"(.*)"$') { $a = ValueAction $map $vn 'REG_SZ' ($matches[1] -replace '\\\\', '\' -replace '\\"', '"') }
        if ($a) { [void]$acts.Add($a) }
      }
    } else {
      if ($text -match $interactive) { $stats.skippedInteractive++; continue }
      $body = ($text -split "\r?\n" | Where-Object { $_ -notmatch '(?i)^\s*@?(pause|timeout\b.*|cls)\s*$' }) -join "`r`n"
      if ($body -notmatch '(?i)\b(reg|powercfg|netsh|sc|fsutil|schtasks|dism|wmic|Set-|New-|Remove-|Disable-|Enable-|Stop-|Start-)') { $stats.skippedEmpty++; continue }
      [void]$acts.Add(@{ script = $body; ext = $ext })
      $stats.scriptBundles++
    }
    if ($acts.Count -eq 0) { $stats.skippedEmpty++; continue }
    if ($names.ContainsKey($name.ToLower())) { $name = "$name ($pack)" }
    if ($names.ContainsKey($name.ToLower())) { continue }
    $names[$name.ToLower()] = 1
    $catName = if ($tree -eq 'Network') { 'network' } else { CatOf $name $text }
    [void]$tweaks.Add(@{
      id = 'lib.' + $rel.ToLower().GetHashCode().ToString('x8'); cat = $catName; tier = 3
      risk = $(if ($text -match $riskHigh) { 2 } elseif ($text -match $riskMid) { 1 } else { 0 })
      ar = $name; en = $name; lib = $true
      dar = "من: $pack  ·  $($acts.Count) تعديل" ; den = "From: $pack  ·  $($acts.Count) change(s)"
      apply = $acts.ToArray()
    })
    $stats.bundleTweaks++; $stats.bundleActions += $acts.Count
  }
}

$json = $js.Serialize(@{ version = (Get-Date -Format 'yyyy.MM.dd'); tweaks = $tweaks.ToArray() })
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding($false)))
$stats.totalTweaks = $tweaks.Count
$stats.sizeMB = [math]::Round((Get-Item $Out).Length / 1MB, 1)
$stats.byCategory = ($tweaks | Group-Object { $_.cat } | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
$stats | ConvertTo-Json
