# Reads every extracted tweak script (.bat .cmd .ps1 .reg .yml) and builds one table of what they set:
#   kind | key | name | type | value | systems that set it
# Network, serial / identity and renaming of Windows programs are flagged "DENY" so they never reach the merged file.
# Usage: powershell -File catalog.ps1   -> E:\win 10 JDO\iso-tweaks\catalog.csv and catalog-allowed.csv
param([string]$Root = 'E:\win 10 JDO\iso-tweaks')
$rows = New-Object System.Collections.Generic.List[object]
function Add-Row($sys, $kind, $key, $name, $type, $val) { $rows.Add([pscustomobject]@{ System = $sys; Kind = $kind; Key = $key; Name = $name; Type = $type; Value = $val }) }

$deny = '(?i)Tcpip|Tcpip6|NDIS|Winsock|AFD\\|\\Dnscache|DNSClient|NetBT|\{4d36e972|NetworkSetup|NetworkList|Nsi\\|\\Psched|QoS|Lanman|\\mrxsmb|\\srv|SharedAccess|FirewallPolicy|WindowsFirewall|DeliveryOptimization|\\Netman|\\NlaSvc|NetworkConnectivity|InterfaceMetric|MSMQ|\\Wcmsvc|\\WlanSvc|NetworkThrottling|MachineGuid|SQMClient|HwProfile|ComputerName|SystemInformation|SystemBiosDate|BIOS|\\IDConfigDB|\\Cryptography|ProductId|InstallDate|BuildGUID|MAC|NetworkAddress|Hostname|SerialNumber|\\Services\\(TokenBroker|DevQueryBroker|FontCache|Themes|FrameServer|Schedule|TimeBrokerSvc|SystemEventsBroker|BrokerInfrastructure|AppXSvc|ClipSVC|StateRepository|LicenseManager|InstallService|wlidsvc|StorSvc|Appinfo|gpsvc|ProfSvc|UserManager|CryptSvc|Winmgmt|RpcSs|RpcEptMapper|DcomLaunch|EventLog|EventSystem|LSM|nsi|Dhcp|Dnscache|NlaSvc|netprofm|iphlpsvc|mpssvc|BFE|Audiosrv|AudioEndpointBuilder|BITS|wuauserv|UsoSvc|DeviceInstall|DsmSvc|CoreMessagingRegistrar|SENS)\\'

foreach ($sysDir in Get-ChildItem $Root -Directory | Where-Object { $_.Name -notmatch '^_' }) {
  $sys = $sysDir.Name
  foreach ($f in Get-ChildItem $sysDir.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.bat', '.cmd', '.ps1', '.reg', '.yml', '.yaml' -and $_.Length -lt 3MB }) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    $text = $text -replace "`0", ''
    if ($f.Extension -eq '.reg') {
      $key = $null
      foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^\[(-?)(HKEY_[^\]]+)\]') { $key = $Matches[2]; continue }
        if ($key -and $l -match '^"([^"]+)"=(dword:([0-9a-fA-F]+)|"(.*)"|hex[^:]*:(.*))') {
          $t = if ($Matches[3]) { 'DWORD' } elseif ($null -ne $Matches[4]) { 'SZ' } else { 'BIN' }
          $v = if ($Matches[3]) { [Convert]::ToUInt32($Matches[3], 16) } elseif ($null -ne $Matches[4]) { $Matches[4] } else { $Matches[5] }
          Add-Row $sys 'reg' $key $Matches[1] $t $v
        }
      }
      continue
    }
    if ($f.Extension -in '.yml', '.yaml') {
      # AME playbook: - !registryValue: {path: , value: , data: , type: }
      foreach ($m in [regex]::Matches($text, '(?ms)registryValue:\s*\r?\n(.*?)(?=\r?\n\s*-\s|\z)')) {
        $blk = $m.Groups[1].Value
        $p = [regex]::Match($blk, 'path:\s*[''"]?([^\r\n''"]+)').Groups[1].Value.Trim()
        $n = [regex]::Match($blk, 'value:\s*[''"]?([^\r\n''"]+)').Groups[1].Value.Trim()
        $d = [regex]::Match($blk, 'data:\s*[''"]?([^\r\n''"]*)').Groups[1].Value.Trim()
        $t = [regex]::Match($blk, 'type:\s*[''"]?([^\r\n''"]+)').Groups[1].Value.Trim()
        if ($p) { Add-Row $sys 'reg' $p $n $t $d }
      }
      foreach ($m in [regex]::Matches($text, '(?i)bcdedit(\.exe)?\s+(/set\s+(\{?\w+\}?\s+)?\w+\s+\S+|/timeout\s+\d+|/deletevalue\s+\S+)')) { Add-Row $sys 'bcd' '' $m.Value '' '' }
      continue
    }
    foreach ($l in ($text -split "`r?`n")) {
      $l = $l.Trim()
      if ($l -match '^(::|rem\s|#)') { continue }
      if ($l -match '(?i)reg(\.exe)?\s+add\s+"?([^"]+?)"?\s+(/v\s+"?([^"]+?)"?|/ve)\s+(/t\s+(\S+)\s+)?(/d\s+(.+?))?\s*(/f.*)?$') {
        $name = if ($Matches[4]) { $Matches[4] } else { '(default)' }
        Add-Row $sys 'reg' $Matches[2] $name $Matches[6] ($Matches[8] -replace '^"|"$', '')
      }
      elseif ($l -match '(?i)bcdedit(\.exe)?\s+(/set|/timeout|/deletevalue)\s+(.+)$') { Add-Row $sys 'bcd' '' ($l -replace '^.*?(?=bcdedit)', '') '' '' }
      elseif ($l -match '(?i)powercfg(\.exe)?\s+(-|/)(setacvalueindex|setdcvalueindex|attributes|change|h)\b.*$') { Add-Row $sys 'power' '' $l '' '' }
      elseif ($l -match '(?i)^(powershell|pwsh)\b.*(Set-ProcessMitigation|Disable-MMAgent|Set-MpPreference|Set-NetTCPSetting|Set-NetAdapter)') { Add-Row $sys 'ps' '' $l '' '' }
      elseif ($l -match '(?i)\b(fsutil|wevtutil|netsh|bcdboot|dism)\b.*') { Add-Row $sys 'cmd' '' $l '' '' }
    }
  }
}
$rows | Export-Csv "$Root\catalog.csv" -NoTypeInformation -Encoding UTF8
$allowed = $rows | Where-Object { $_.Kind -ne 'reg' -or (($_.Key + '\' + $_.Name) -notmatch $deny -and $_.Key -notmatch '\\Services\\[^\\]+$' -or $_.Name -notmatch '^Start$') }
$allowed = $rows | Where-Object { -not (($_.Key + '\' + $_.Name) -match $deny) }
$allowed | Export-Csv "$Root\catalog-allowed.csv" -NoTypeInformation -Encoding UTF8
"rows: $($rows.Count)  allowed: $($allowed.Count)  systems: $(($rows | Select -Expand System -Unique).Count)"
