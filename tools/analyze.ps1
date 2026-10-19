# JDO Tweak - source analyzer
# Reads every tweak file line by line, splits it into single settings,
# drops cheats / spoofers / serial changes, dedupes, and writes a catalog.
# Usage: powershell -ExecutionPolicy Bypass -File analyze.ps1 -Out <dir> <source dirs...>
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Sources
)
$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force $Out | Out-Null

# --- exclusion rules -------------------------------------------------------
# Whole files/folders: cheats, aim, spoofers, serial changers, cracks.
$badPath = '(?i)\\cheats?\\|\\aim[^\\]*\\|spoof|hwid|serial|cheat|recoil|aimbot|soft ?aim|triggerbot|\besp\b|bypass|unban|inject|crack|keygen|\bloader\b|\.gpc$'
# Single settings: anything that rewrites machine identity or breaks the OS.
$badKey = '(?i)MachineGuid|HwProfileGuid|\\ProductId|DigitalProductId|SusClientId|SystemSerialNumber|BaseBoardSerial|ComputerHardwareId|\\NetworkAddress|InstallDate|InstallTime|\\IDConfigDB|\\Cryptography\b|\\SystemInformation\\(ComputerHardwareId|BIOS)|\\HARDWARE\\DESCRIPTION|\\BIOS\\|VolumeId|\\WindowsStore|\\AppxAllUserStore|\\Xbox|GamingServices|TaskCache|\\BCD0'
$badCmd = '(?i)\bvolumeid\b|\bbcdedit\b|\bbcdboot\b|wmic .*(serial|uuid)|Set-ItemProperty.*(MachineGuid|ProductId)|Remove-AppxPackage.*(Store|Xbox|GamingServices)|Get-AppxPackage.*(Store|Xbox).*Remove|\bsc(\.exe)? +delete\b|takeown .*System32|icacls .*System32|\bdel\b.*\\System32|\brd\b.*\\System32|format +[a-z]:|diskpart|cipher /w|vssadmin delete|wevtutil cl'

$hives = @{ 'HKLM'='HKEY_LOCAL_MACHINE'; 'HKCU'='HKEY_CURRENT_USER'; 'HKCR'='HKEY_CLASSES_ROOT'; 'HKU'='HKEY_USERS'; 'HKCC'='HKEY_CURRENT_CONFIG' }
function NormKey([string]$k) {
  $k = $k.Trim().Trim('"').TrimEnd('\')
  $p = $k.Split('\')[0].ToUpper()
  if ($hives.ContainsKey($p)) { $k = $hives[$p] + $k.Substring($p.Length) }
  return $k
}
function NormData([string]$type, [string]$data) {
  $data = $data.Trim()
  if ($type -eq 'REG_DWORD' -or $type -eq 'REG_QWORD') {
    try {
      if ($data -match '^0x') { return [string][Convert]::ToUInt64($data.Substring(2),16) }
      return [string][UInt64]$data
    } catch { return $data }
  }
  return $data.Trim('"')
}

$settings = @{}   # id -> object
$commands = @{}   # normalized cmd -> object
$excluded = New-Object System.Collections.ArrayList
$stats = @{ files=0; regFiles=0; scriptFiles=0; skippedFiles=0; settingHits=0; cmdHits=0; badSettings=0; badCmds=0 }

function AddSetting($key, $name, $type, $data, $src) {
  $key = NormKey $key
  if ($key -match $badKey -or $name -match $badKey) { $script:stats.badSettings++; return }
  $id = ($key + '|' + $name).ToLower()
  $script:stats.settingHits++
  if (-not $settings.ContainsKey($id)) {
    $settings[$id] = [pscustomobject]@{ Key=$key; Name=$name; Values=@{}; Sources=@{} }
  }
  $s = $settings[$id]
  $v = "$type=$data"
  if ($s.Values.ContainsKey($v)) { $s.Values[$v]++ } else { $s.Values[$v] = 1 }
  $s.Sources[$src] = 1
}

function ParseReg($path, $src) {
  $text = [IO.File]::ReadAllText($path)   # detects UTF-16 BOM
  $text = $text -replace "\\\r?\n\s*", ''  # join hex continuations
  $key = $null
  foreach ($line in $text -split "\r?\n") {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith(';')) { continue }
    if ($l -match '^\[(-?)(.+)\]$') {
      if ($matches[1] -eq '-') { $key = $null; AddSetting $matches[2] '(delete key)' 'DELETE' '' $src } else { $key = $matches[2] }
      continue
    }
    if (-not $key) { continue }
    if ($l -match '^(@|"((?:[^"\\]|\\.)*)")\s*=\s*(.*)$') {
      $name = if ($matches[1] -eq '@') { '(Default)' } else { $matches[2] -replace '\\\\','\' }
      $raw = $matches[3]
      if ($raw -eq '-') { AddSetting $key $name 'DELETE' '' $src }
      elseif ($raw -match '^dword:([0-9a-fA-F]+)') { AddSetting $key $name 'REG_DWORD' ([string][Convert]::ToUInt32($matches[1],16)) $src }
      elseif ($raw -match '^hex\(b\):(.*)') { $b = $matches[1] -split ',' | Where-Object { $_ } ; $n=[UInt64]0; for($i=$b.Count-1;$i -ge 0;$i--){ $n = $n*256 + [Convert]::ToUInt64($b[$i],16) }; AddSetting $key $name 'REG_QWORD' ([string]$n) $src }
      elseif ($raw -match '^hex(\((\w)\))?:(.*)') { $t = switch($matches[2]){ '2'{'REG_EXPAND_SZ'} '7'{'REG_MULTI_SZ'} default{'REG_BINARY'} }; AddSetting $key $name $t ($matches[3].ToLower()) $src }
      elseif ($raw -match '^"(.*)"$') { AddSetting $key $name 'REG_SZ' $matches[1] $src }
    }
  }
}

function ParseScript($path, $src) {
  $lines = [IO.File]::ReadAllLines($path)
  foreach ($line in $lines) {
    $l = $line.Trim()
    if ($l -eq '' -or $l -match '^(rem\b|::|#|echo\b|@echo|pause|cls|title|color|goto|:|exit|timeout|chcp|setlocal|endlocal|mode )' ) { continue }
    $l = $l -replace '\s*>\s*nul.*$','' -replace '\s+2>&1.*$',''
    if ($l -match '(?i)^(reg(\.exe)?)\s+add\s+"?([^"]+?)"?\s+(/v\s+"?([^"/]+?)"?|/ve)\s+(/t\s+(\w+)\s+)?(/d\s+"?([^"]*?)"?\s+)?/f') {
      $name = if ($matches[4] -match '^/ve') { '(Default)' } else { $matches[5].Trim() }
      $type = if ($matches[7]) { $matches[7].ToUpper() } else { 'REG_SZ' }
      AddSetting $matches[3] $name $type (NormData $type $matches[9]) $src
      continue
    }
    if ($l -match '(?i)^(reg(\.exe)?)\s+delete\s+"?([^"]+?)"?\s+/v\s+"?([^"/]+?)"?\s+/f') { AddSetting $matches[3] $matches[4].Trim() 'DELETE' '' $src; continue }
    if ($l -match '(?i)^(powercfg|netsh|sc(\.exe)?\s+config|fsutil|Disable-MMAgent|Enable-MMAgent|Set-NetAdapter|Set-NetTCPSetting|Set-NetOffloadGlobalSetting|Disable-NetAdapter|Set-ProcessMitigation|Set-MpPreference|dism|bcdedit|schtasks|Set-Service|Stop-Service|Set-ItemProperty|New-ItemProperty|Remove-AppxPackage|Get-AppxPackage)\b') {
      if ($l -match $badCmd) { $script:stats.badCmds++; continue }
      $n = ($l -replace '\s+',' ').ToLower()
      $script:stats.cmdHits++
      if ($commands.ContainsKey($n)) { $commands[$n].Count++; $commands[$n].Sources[$src]=1 }
      else { $commands[$n] = [pscustomobject]@{ Command=$l; Count=1; Sources=@{ $src=1 } } }
    }
  }
}

foreach ($root in $Sources) {
  $root = $root.TrimEnd('\')
  $packName = Split-Path $root -Leaf
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File) {
    $stats.files++
    $rel = $f.FullName.Substring($root.Length)
    $ext = $f.Extension.ToLower()
    if ($ext -notin '.reg','.bat','.cmd','.ps1') { continue }
    if ($rel -match $badPath) { $stats.skippedFiles++; [void]$excluded.Add("$packName$rel"); continue }
    $src = $packName + '\' + (($rel.TrimStart('\') -split '\\')[0])
    if ($ext -eq '.reg') { $stats.regFiles++; ParseReg $f.FullName $src } else { $stats.scriptFiles++; ParseScript $f.FullName $src }
  }
}

# --- output ----------------------------------------------------------------
$rows = foreach ($s in $settings.Values) {
  $top = $s.Values.GetEnumerator() | Sort-Object Value -Descending
  [pscustomobject]@{
    Key = $s.Key; Name = $s.Name
    TopValue = $top[0].Key; TopCount = $top[0].Value
    Variants = $s.Values.Count
    AllValues = ($top | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ' | '
    Packs = $s.Sources.Count
  }
}
$rows | Sort-Object Packs, TopCount -Descending | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Out 'settings.csv')
$commands.Values | Sort-Object Count -Descending | Select-Object Count, @{n='Packs';e={$_.Sources.Count}}, Command | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Out 'commands.csv')
$excluded | Set-Content -Encoding UTF8 (Join-Path $Out 'excluded_files.txt')
$stats.uniqueSettings = $settings.Count
$stats.uniqueCommands = $commands.Count
$stats | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Out 'stats.json')
$stats | ConvertTo-Json
