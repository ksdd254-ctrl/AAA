# JDO Tweak - plan-box test, runs INSIDE the throw-away test VM (started from the USB share as D:\b.cmd).
# Ultimate box, then "Apply all" in every section: apply -> restart -> check Windows -> revert -> restart -> check.
# Everything is written to C:\JDO-BOXTEST\report.txt; the host reads it from the VM disk.
$ErrorActionPreference = 'Continue'
$dir = 'C:\JDO-BOXTEST'
New-Item -ItemType Directory -Force $dir | Out-Null
$rep = "$dir\report.txt"; $stateFile = "$dir\stage.txt"; $exe = "$dir\JdoTweak.exe"
function Say([string]$t) { Add-Content -LiteralPath $rep -Value ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $t) -Encoding UTF8 }

# elevate silently (the test image has UAC on with no prompts)
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}

# first run: copy the test files from the USB share onto C: (the share isn't needed after that)
if (-not (Test-Path $stateFile)) {
  $src = Split-Path -Parent $MyInvocation.MyCommand.Path
  Copy-Item "$src\JdoTweak.exe" $exe -Force
  if (Test-Path "$src\mode.txt") { Copy-Item "$src\mode.txt" "$dir\mode.txt" -Force } else { Set-Content "$dir\mode.txt" 'all' }
  Copy-Item $MyInvocation.MyCommand.Path "$dir\boxtest.ps1" -Force
  Set-Content $stateFile '0'
  Set-Content $rep "JDO Tweak box test  $(Get-Date -Format s)" -Encoding UTF8
  $os = Get-CimInstance Win32_OperatingSystem
  Say "Windows: $($os.Caption) $($os.Version)"
}

function Health([string]$label) {
  Start-Sleep -Seconds 45   # let services settle after sign-in
  $os = Get-CimInstance Win32_OperatingSystem
  $up = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
  $bad = @()
  if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { $bad += 'desktop (explorer) not running' }
  foreach ($s in 'Audiosrv', 'AudioEndpointBuilder', 'Dnscache', 'Dhcp', 'nsi', 'EventLog', 'Winmgmt', 'CryptSvc', 'BFE', 'mpssvc', 'LanmanWorkstation', 'ProfSvc', 'Power', 'PlugPlay', 'RpcSs') {
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { $bad += "service $s is $($svc.Status)" }
  }
  $dns = $false; try { [void][Net.Dns]::GetHostEntry('www.microsoft.com'); $dns = $true } catch { }
  if (-not $dns) { $bad += 'DNS lookup failed' }
  $web = $false; try { $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 20; $web = $r.Content -match 'Microsoft' } catch { }
  if (-not $web) { $bad += 'no internet (HTTP)' }
  if (-not (Get-AppxPackage Microsoft.WindowsStore -ErrorAction SilentlyContinue)) { $bad += 'Microsoft Store missing' }
  $crit = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $os.LastBootUpTime } -ErrorAction SilentlyContinue)
  $svcCount = @(Get-Service | Where-Object Status -eq 'Running').Count
  $state = if ($bad.Count -eq 0) { 'HEALTHY' } else { 'PROBLEMS' }
  Say ("HEALTH {0}: {1} (booted {2} min ago, {3} services running, {4} system errors since boot)" -f $label, $state, $up, $svcCount, $crit.Count)
  foreach ($b in $bad) { Say "  - $b" }
  $crit | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { Say ("  event: {0} x{1}: {2}" -f $_.Name, $_.Count, ($_.Group[0].Message -split "`n")[0].Trim()) }
}

function Tool([string[]]$a) {
  $p = Start-Process $exe -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
  if ($p.ExitCode -eq 99) { Say 'REFUSED: the app says this is not a test VM - stopping.'; exit }
  return $p.ExitCode
}

function Next([int]$n, [bool]$restart) {
  Set-Content $stateFile "$n"
  if ($restart) {
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'JDO box test' "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $dir\boxtest.ps1"
    Say "restarting..."
    Restart-Computer -Force
    exit
  }
}

$stage = [int](Get-Content $stateFile)
$mode = (Get-Content "$dir\mode.txt" -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $mode) { $mode = 'all' } else { $mode = $mode.Trim() }
# mode reg / cmd: only the settings or only the commands of "Apply all", with an extra plain restart before the revert
# 20 apply | 21 check | 22 check after a 2nd restart, revert | 23 check | 24 check after another restart, done
# 0 health + snapshot | 1 Ultimate box | 2 check, revert | 3 check, compare | 4 Apply all (every section, commands too)
# 5 check, revert | 6 check, done
switch ($stage) {
  0 {
    Health 'before any tweak'
    Tool @('--boxtest', 'snapshot', "$dir\baseline.txt") | Out-Null
    Get-Content "$dir\baseline.txt.txt" | ForEach-Object { Say $_ }
    if ($mode -ne 'all') { Say "MODE: $mode"; Next 20 $false } else { Next 1 $false }
    & $MyInvocation.MyCommand.Path; return
  }
  20 { Say "----- APPLY ALL: $mode only -----"; Tool @('--boxtest', 'applyall', $mode, $rep) | Out-Null; Next 21 $true }
  21 { Health "after Apply all ($mode) + restart"; Next 22 $true }
  22 { Health "after a 2nd restart ($mode applied)"; Tool @('--boxtest', 'revert', $rep) | Out-Null; Next 23 $true }
  23 { Health "after reverting ($mode) + restart"; Next 24 $true }
  24 { Health "after another restart"; Say 'ALL DONE'; Set-Content "$dir\done.txt" (Get-Date -Format s); Stop-Computer -Force }
  1 { Say '----- ULTIMATE BOX -----'; Tool @('--boxtest', 'apply', '3', $rep) | Out-Null; Next 2 $true }
  2 { Health 'after the Ultimate box + restart'; Tool @('--boxtest', 'revert', $rep) | Out-Null; Next 3 $true }
  3 {
    Health 'after reverting the box + restart'
    $diff = Tool @('--boxtest', 'compare', "$dir\baseline.txt", $rep)
    Say ("RESULT box: {0}" -f $(if ($diff -eq 0) { 'everything back to the original' } else { "$diff values not back to the original" }))
    Next 4 $false; & "$dir\boxtest.ps1"; return
  }
  4 { Say '----- APPLY ALL (every section, commands included) -----'; Tool @('--boxtest', 'applyall', $rep) | Out-Null; Next 5 $true }
  5 { Health 'after Apply all + restart'; Tool @('--boxtest', 'revert', $rep) | Out-Null; Next 6 $true }
  6 {
    Health 'after reverting Apply all + restart'
    Say 'ALL DONE'
    Set-Content "$dir\done.txt" (Get-Date -Format s)
    Stop-Computer -Force
  }
}
