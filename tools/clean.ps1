# JDO Tweak - pack cleaner
# Goes through every tweak file line by line and writes a clean copy:
#   * duplicates (same key + value, or same command) are dropped - first one wins
#   * only these are removed: boot/BCD, Task Scheduler breakers, serial/HWID, MAC and static-IP changes, cheat files
#   * network lines are moved out of mixed files into a separate Network tree
#   * everything else (security / Defender / Store / Xbox / services...) is kept
# Every removed item is written to _Reports\removed.csv with the reason.
# Usage: powershell -ExecutionPolicy Bypass -File clean.ps1 -Out E:\JDO_CLEAN <source dirs...>
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Sources
)
$ErrorActionPreference = 'Continue'
$ansi = [Text.Encoding]::Default
$utf16 = [Text.Encoding]::Unicode
$utf8bom = New-Object Text.UTF8Encoding($true)

# ---------------- rules ----------------
$cheatPath = '(?i)\\cheats?\\|\\aim[^\\]*\\|aim ?bot|soft ?aim|aim ?assist|triggerbot|\besp\b|recoil|spoof|hwid|serial ?changer|unban|\.gpc$'

$rules = @(
  @{ r='serial'; k='(?i)MachineGuid|HwProfileGuid|\\ProductId$|DigitalProductId|SusClientId|SystemSerialNumber|BaseBoard(Manufacturer|Product|Version|Serial)|SystemProductName|SystemManufacturer|SystemFamily|SystemSKU|BIOSVendor|BIOSVersion|BIOSReleaseDate|ComputerHardwareIds?|\\InstallDate$|\\InstallTime$|\\IDConfigDB\\|\\HARDWARE\\DESCRIPTION\\|\\ComputerName\\ComputerName\\|\\SQMClient\\MachineId|\\Cryptography\\MachineGuid';
     c='(?i)\bvolumeid(64)?\b|wmic .*(serial|uuid|csproduct)|\bAMIDE(WIN|FI)\b|\bAFUWIN|\bSMBIOS\b|MachineGuid|HwProfileGuid|DigitalProductId|SusClientId|SerialNumber|\bRename-Computer\b|\\ProductId\b|InstallDate|ComputerHardwareId' },
  @{ r='mac';    k='(?i)\\NetworkAddress$'; c='(?i)/v +"?NetworkAddress\b|-RegistryKeyword +"?NetworkAddress|-MacAddress\b|\bmacshift\b|\btmac(\.exe)?\b' },
  @{ r='ip';     k='(?i)\\Tcpip6?\\Parameters\\Interfaces\\[^\\]+\\(IPAddress|SubnetMask|DefaultGateway|EnableDHCP|DhcpIPAddress)$';
     c='(?i)netsh .*(set address|add address|static)|New-NetIPAddress|Set-NetIPAddress|Remove-NetIPAddress|New-NetRoute' },
  @{ r='boot';   k='(?i)\\BCD00000000\\|\\BCD0'; c='(?i)\bbcdedit\b|\bbcdboot\b|\bbootcfg\b|\bbootrec\b' },
  @{ r='tasksched'; k='(?i)\\Schedule\\TaskCache\\|\\Services\\Schedule\\Start$';
     c='(?i)schtasks(\.exe)? .*/delete .*/tn +"?\*|Unregister-ScheduledTask(?!.*-TaskName)|Get-ScheduledTask *\| *Unregister|(rd|rmdir|del|Remove-Item).*\\System32\\Tasks|TaskCache|sc(\.exe)? +(config|stop) +"?Schedule"?\b' }
)
$review = '(?i)\bformat +[a-z]:|\bdiskpart\b|cipher +/w|vssadmin +delete|wevtutil +cl|(rd|rmdir|del) .*\\Windows\\System32\b|takeown .*\\System32|icacls .*\\System32'

$netKey = '(?i)\\Services\\Tcpip6?\\|\\Services\\Psched|\\Policies\\Microsoft\\Windows\\Psched|\\Services\\LanmanServer|\\Services\\LanmanWorkstation|\\Services\\AFD\\|\\Services\\NDIS\\|\\Services\\Dnscache\\|\\Services\\NetBT\\|\\Class\\\{4d36e972-e325-11ce-bfc1-08002be10318\}|\\NetworkThrottlingIndex$|\\MSMQ\\|\\Services\\Winsock|\\WinHttp|\\Internet Settings\\|\\QoS\\|\\NlaSvc\\|\\Services\\Dhcp\\|\\Services\\iphlpsvc|\\NetworkList\\|\\Services\\WlanSvc|\\Services\\Tcpip\\ServiceProvider'
$netCmd = '(?i)^\s*(netsh|ipconfig|route|arp|nbtstat)\b|\b(Set|Disable|Enable|Reset|New|Remove)-Net[A-Za-z]+|Set-DnsClient|Clear-DnsClientCache|Disable-NetAdapterBinding|Enable-NetAdapterBinding|NetworkThrottlingIndex|\\Tcpip\\|\\Psched|LanmanServer|LanmanWorkstation|\\AFD\\|TcpAckFrequency|TCPNoDelay|\{4d36e972-e325-11ce-bfc1-08002be10318\}'
$cmdLine = '(?i)^\s*(@?(reg(\.exe)?|regedit|powercfg|netsh|sc(\.exe)?|fsutil|bcdedit|bcdboot|schtasks|dism|ipconfig|route|wmic|taskkill|net +(stop|start)|bootcfg|volumeid\w*|takeown|icacls|wevtutil|vssadmin|cipher|diskpart|format)\b|(Set|New|Remove|Disable|Enable|Get|Stop|Start|Unregister|Register|Rename|Reset|Clear|Add)-[A-Za-z]+)'

$hives = @{ 'HKLM'='HKEY_LOCAL_MACHINE'; 'HKCU'='HKEY_CURRENT_USER'; 'HKCR'='HKEY_CLASSES_ROOT'; 'HKU'='HKEY_USERS'; 'HKCC'='HKEY_CURRENT_CONFIG' }
function NormKey([string]$k) {
  $k = $k.Trim().Trim('"').TrimEnd('\')
  $p = $k.Split('\')[0].ToUpper()
  if ($hives.ContainsKey($p)) { $k = $hives[$p] + $k.Substring($p.Length) }
  return $k
}
function Reason([string]$path, [string]$cmd) {
  foreach ($r in $rules) {
    if ($path -and $path -match $r.k) { return $r.r }
    if ($cmd -and $cmd -match $r.c) { return $r.r }
  }
  return $null
}

# ---------------- state ----------------
$seenFile = New-Object 'System.Collections.Generic.HashSet[string]'
$seenSet  = New-Object 'System.Collections.Generic.HashSet[string]'
$removed  = New-Object IO.StreamWriter((Join-Path (New-Item -ItemType Directory -Force "$Out\_Reports").FullName 'removed.csv'), $false, $utf8bom)
$removed.WriteLine('Reason,File,Item')
$reviewW  = New-Object IO.StreamWriter("$Out\_Reports\review_kept.csv", $false, $utf8bom)
$reviewW.WriteLine('File,Line')
$st = [ordered]@{ files=0; dupFiles=0; cheatFiles=0; emptyAfterClean=0; written=0; netFiles=0; dupLines=0; netLines=0; keptLines=0; serial=0; mac=0; ip=0; boot=0; tasksched=0; review=0; assets=0 }
function Rem($reason, $file, $item) {
  $st[$reason]++
  $removed.WriteLine(('{0},"{1}","{2}"' -f $reason, $file.Replace('"','""'), $item.Replace('"','""')))
}
$sha = [Security.Cryptography.SHA1]::Create()
function Hash($bytes) { [BitConverter]::ToString($sha.ComputeHash($bytes)) }

# \\?\ prefix so deep pack folders don't hit the 260-character path limit
function LongPath($dir, $rel) { '\\?\' + (Join-Path $dir ($rel -replace '[<>:"|?*]', '_')) }
function WriteOut($dir, $rel, $text, $enc) {
  $p = LongPath $dir $rel
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
  [IO.File]::WriteAllText($p, $text, $enc)
}
function WriteBytes($dir, $rel, $bytes) {
  $p = LongPath $dir $rel
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
  [IO.File]::WriteAllBytes($p, $bytes)
}

# ---------------- .reg ----------------
function CleanReg($file, $rel) {
  $text = [IO.File]::ReadAllText($file)
  $text = $text -replace "\\\r?\n\s*", ''
  $main = New-Object Text.StringBuilder; $net = New-Object Text.StringBuilder
  $mainKey = $null; $netKey2 = $null; $key = $null; $keyLine = $null; $kept = 0; $netn = 0
  foreach ($line in $text -split "\r?\n") {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith(';') -or $l -like 'Windows Registry Editor*' -or $l -eq 'REGEDIT4') { continue }
    if ($l -match '^\[(-?)(.+)\]$') {
      $key = NormKey $matches[2]; $keyLine = $l
      if ($matches[1] -eq '-') {
        $id = "-$key".ToLower()
        $why = Reason "$key\" $null
        if ($why) { Rem $why $rel $l; $key = $null; continue }
        if (-not $seenSet.Add($id)) { $st.dupLines++; $key = $null; continue }
        if ("$key\" -match $netKey) { [void]$net.AppendLine("`r`n$l"); $netn++ } else { [void]$main.AppendLine("`r`n$l"); $kept++ }
        $key = $null
      }
      continue
    }
    if (-not $key) { continue }
    if ($l -notmatch '^(@|"((?:[^"\\]|\\.)*)")\s*=') { continue }
    $name = if ($matches[1] -eq '@') { '(Default)' } else { $matches[2] }
    $full = "$key\$name"
    $why = Reason $full $null
    if ($why) { Rem $why $rel "$keyLine $l"; continue }
    if (-not $seenSet.Add(("$full=" + ($l.Substring($l.IndexOf('=') + 1).Trim())).ToLower())) { $st.dupLines++; continue }
    if ($full -match $netKey) {
      if ($netKey2 -ne $key) { [void]$net.AppendLine("`r`n$keyLine"); $netKey2 = $key }
      [void]$net.AppendLine($l); $netn++
    } else {
      if ($mainKey -ne $key) { [void]$main.AppendLine("`r`n$keyLine"); $mainKey = $key }
      [void]$main.AppendLine($l); $kept++
    }
  }
  $hdr = "Windows Registry Editor Version 5.00`r`n"
  if ($kept -gt 0) { WriteOut "$Out\Tweaks" $rel ($hdr + $main.ToString()) $utf16; $st.written++; $st.keptLines += $kept }
  if ($netn -gt 0) { WriteOut "$Out\Network" $rel ($hdr + $net.ToString()) $utf16; $st.netFiles++; $st.netLines += $netn }
  if ($kept -eq 0 -and $netn -eq 0) { $st.emptyAfterClean++ }
}

# ---------------- .bat / .cmd / .ps1 ----------------
function CleanScript($file, $rel, $isPs) {
  $enc = if ($isPs) { $utf8bom } else { $ansi }
  $lines = [IO.File]::ReadAllLines($file, $(if ($isPs) { [Text.Encoding]::UTF8 } else { $ansi }))
  $main = New-Object Text.StringBuilder; $net = New-Object Text.StringBuilder
  $hadCmd = $false; $kept = 0; $netn = 0
  foreach ($line in $lines) {
    $l = $line.Trim()
    $isCmd = $l -match $cmdLine
    if (-not $isCmd) { [void]$main.AppendLine($line); continue }
    $hadCmd = $true
    $why = Reason $null $l
    if ($why) { Rem $why $rel $l; continue }
    if ($l -match $review) { $st.review++; $reviewW.WriteLine(('"{0}","{1}"' -f $rel.Replace('"','""'), $l.Replace('"','""'))) }
    $norm = (($l -replace '\s*(>\s*nul|2>&1|>nul 2>&1|\|\s*Out-Null)\s*', ' ') -replace '\s+', ' ').Trim().ToLower()
    if (-not $seenSet.Add("cmd:$norm")) { $st.dupLines++; continue }
    if ($l -match $netCmd) { [void]$net.AppendLine($line); $netn++ } else { [void]$main.AppendLine($line); $kept++ }
  }
  if (-not $hadCmd) {
    # menu / helper script with no recognisable tweak commands - keep as is
    WriteOut "$Out\Tweaks" $rel ([string]::Join("`r`n", $lines)) $enc; $st.written++; return
  }
  if ($kept -gt 0) { WriteOut "$Out\Tweaks" $rel $main.ToString() $enc; $st.written++; $st.keptLines += $kept }
  if ($netn -gt 0) {
    $head = if ($isPs) { "# Network tweaks extracted from: $rel`r`n" } else { "@echo off`r`nrem Network tweaks extracted from: $rel`r`n" }
    WriteOut "$Out\Network" $rel ($head + $net.ToString()) $enc; $st.netFiles++; $st.netLines += $netn
  }
  if ($kept -eq 0 -and $netn -eq 0) { $st.emptyAfterClean++ }
}

# ---------------- main ----------------
foreach ($root in $Sources) {
  $root = $root.TrimEnd('\')
  $pack = Split-Path $root -Leaf
  Write-Host "== $pack"
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File) {
    $ext = $f.Extension.ToLower()
    if ($ext -notin '.reg','.bat','.cmd','.ps1','.pow','.nip') { continue }
    $st.files++
    $relIn = $f.FullName.Substring($root.Length).TrimStart('\')
    # archives extracted as A01, A02 ... -> use the original archive name
    $top = ($relIn -split '\\')[0]
    if (Test-Path -LiteralPath "$root\$top.txt") { $relIn = (Get-Content -LiteralPath "$root\$top.txt" -TotalCount 1) + $relIn.Substring($top.Length) }
    $rel = "$pack\$relIn"
    if ($rel -match $cheatPath) { $st.cheatFiles++; $removed.WriteLine(('cheat,"{0}",""' -f $rel.Replace('"','""'))); continue }
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if (-not $seenFile.Add((Hash $bytes))) { $st.dupFiles++; continue }
    try {
      if ($ext -eq '.pow') { WriteBytes "$Out\Power Plans" $rel $bytes; $st.assets++ }
      elseif ($ext -eq '.nip') { WriteBytes "$Out\NVIDIA Profiles" $rel $bytes; $st.assets++ }
      elseif ($ext -eq '.reg') { CleanReg $f.FullName $rel }
      else { CleanScript $f.FullName $rel ($ext -eq '.ps1') }
    } catch { Write-Host "ERR $rel : $_" }
  }
}
$removed.Close(); $reviewW.Close()
$summary = ($st.GetEnumerator() | ForEach-Object { "{0,-18} {1}" -f $_.Key, $_.Value }) -join "`r`n"
[IO.File]::WriteAllText("$Out\_Reports\summary.txt", $summary, $utf8bom)
$summary
