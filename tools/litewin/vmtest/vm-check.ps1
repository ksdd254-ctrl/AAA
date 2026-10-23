# JDO Lite - checks run INSIDE the test virtual machine after the first sign-in.
# Writes C:\JDO-TEST\report.txt (read from the VM disk afterwards) and a copy next to this script, then shuts down.
$ErrorActionPreference = 'Continue'
$out = 'C:\JDO-TEST'; New-Item -ItemType Directory -Force $out | Out-Null
$rep = Join-Path $out 'report.txt'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# The JDO x QHT tweaks run 5 s after the first desktop and restart the PC: the checks wait for that restart and run
# at the sign-in after it (from a copy on C:, the install media may be gone by then)
if (-not (Test-Path 'C:\JDO\qht.done')) {
  Copy-Item $MyInvocation.MyCommand.Path "$out\vm-check.ps1" -Force
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'JDO VM check' "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $out\vm-check.ps1"
  Set-Content "$out\waiting.txt" "waiting for the JDO x QHT restart $(Get-Date -Format s)"
  return
}
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}
# second pass, after a restart: the real idle numbers (no installers, no Store updates running) -> C:\JDO-TEST\idle.txt
if (Test-Path "$out\idle-pass") {
  Remove-Item "$out\idle-pass" -Force
  Start-Sleep -Seconds 300   # 5 min: start-up jobs (licence refresh, Store, COM hosts) are over
  # runonce.exe is this check's own launcher (RunOnce): not counted
  $p = Get-Process | Where-Object { $_.Id -ne 0 -and $_.Id -ne $PID -and $_.Name -notin 'powershell', 'conhost', 'runonce' }
  $os2 = Get-CimInstance Win32_OperatingSystem
  $lines = @("idle after restart  $(Get-Date -Format s)", "processes: $($p.Count)",
             ('RAM in use: {0:N0} MB' -f (($os2.TotalVisibleMemorySize - $os2.FreePhysicalMemory) / 1KB)),
             ('  ' + (($p | Sort-Object Name | ForEach-Object { $_.Name }) -join ', ')), '--- svchost groups ---')
  $lines += & tasklist.exe /svc /fi 'imagename eq svchost.exe'
  # after every JDO-Tools option ran: the PC must come back to a normal desktop
  $lines += "boot after the tools: explorer $([bool](Get-Process explorer -ErrorAction SilentlyContinue)), CoreMessaging $((Get-Service CoreMessagingRegistrar).Status), disabled system devices: $(@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 22 -and $_.Class -in 'System','Display','Computer' }).Count)"
  Set-Content "$out\idle.txt" $lines
  return
}
$win11 = [Environment]::OSVersion.Version.Build -ge 22000
function Say([string]$t) { Add-Content -LiteralPath $rep -Value $t -Encoding UTF8 }
function Check([string]$name, [bool]$ok, [string]$detail = '') { Say ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail) }
Set-Content -LiteralPath $rep -Value "JDO Lite VM test  $(Get-Date -Format s)" -Encoding UTF8

# ---------- 1. the system came up ----------
Say '== 1. install and first boot'
$os = Get-CimInstance Win32_OperatingSystem
Say "  $($os.Caption) $($os.Version) build $($os.BuildNumber)  installed $($os.InstallDate)"
Check 'first boot script finished' (Test-Path 'C:\Windows\Setup\Scripts\firstboot.done')
if (Test-Path 'C:\Windows\Setup\Scripts\firstboot.log') { Say '  --- firstboot.log (errors only) ---'; Get-Content 'C:\Windows\Setup\Scripts\firstboot.log' | Where-Object { $_ -match 'error|exception|denied|fail' } | Select-Object -First 30 | ForEach-Object { Say "    $_" } }
$plan = powercfg /getactivescheme
Check 'power plan JDO Ultimate active' ($plan -match 'JDO Ultimate') $plan
Check 'hibernation off' (-not (Test-Path 'C:\hiberfil.sys'))
foreach ($s in 'UsoSvc', 'WaaSMedicSvc', 'DoSvc') {
  Check "$s off" ((Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue).StartMode -eq 'Disabled')
}
# the Store needs these: on demand, as Windows ships them
foreach ($s in 'wuauserv', 'wlidsvc', 'InstallService') {
  Check "$s can start (Store)" ((Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue).StartMode -in 'Manual', 'Auto')
}
Check 'JDO x QHT tweaks applied (first run finished)' (Test-Path 'C:\JDO\qht.done')
$ql = Get-ChildItem 'C:\JDO\logs' -Filter 'JDO-x-QHT.log' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ql) { Say '  --- JDO-x-QHT.log [FAIL] lines ---'; Select-String -LiteralPath $ql.FullName -Pattern '\[FAIL\]|fix:' | Select-Object -First 40 | ForEach-Object { Say "    $($_.Line.Trim())" } }
Check 'timer service JDOTimer running' ((Get-Service JDOTimer -ErrorAction SilentlyContinue).Status -eq 'Running')
Check 'Open-Shell installed' (Test-Path "$env:ProgramFiles\Open-Shell\StartMenu.exe")
Check 'Task Scheduler running' ((Get-Service Schedule).Status -eq 'Running')
Check 'scheduled tasks readable' ((Get-ScheduledTask -ErrorAction SilentlyContinue | Measure-Object).Count -gt 10)
Check 'Run as administrator service (Appinfo) starts' ($(Start-Service Appinfo -ErrorAction SilentlyContinue; (Get-Service Appinfo).Status -eq 'Running'))
Check 'UAC on, no prompts' ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA -eq 1)
Check 'black desktop' ((Get-ItemProperty 'HKCU:\Control Panel\Colors').Background -eq '0 0 0')
Check 'dark mode' ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme -eq 0)

# ---------- 2. idle processes after things settle ----------
Say '== 2. processes at idle'
# the apps step after the restart (Brave, AnyDesk, Store update) must be finished first, or its installers are counted
for ($i = 0; $i -lt 60 -and -not (Test-Path 'C:\JDO\postsetup.done'); $i++) { Start-Sleep -Seconds 10 }
Start-Sleep -Seconds 180
# tasklist itself starts WMI hosts: take the snapshot first, list the services per svchost afterwards
$procs = Get-Process | Where-Object { $_.Id -ne 0 }   # Idle (pid 0) is not a real process
$mine = $procs | Where-Object { $_.Id -eq $PID -or $_.Name -in 'powershell', 'conhost' }   # this test itself
$count = $procs.Count - $mine.Count
Say "  processes (without this test's own powershell / conhost): $count"
Say ('  ' + (($procs | Where-Object { $_.Id -notin $mine.Id } | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '))
$svc = Get-CimInstance Win32_Service | Where-Object State -eq 'Running'
Say "  running services: $($svc.Count)"
Say ('  ' + (($svc | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '))
$cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 5 -ErrorAction SilentlyContinue).CounterSamples | Measure-Object CookedValue -Average
Say ('  CPU at idle: {0:N1} %' -f $cpu.Average)
Say ('  RAM in use: {0:N0} MB' -f (($os.TotalVisibleMemorySize - (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory) / 1KB))
Say ('  C: used: {0:N2} GB' -f ((Get-PSDrive C).Used / 1GB))
Check 'Windows Audio running (sound service; the VM itself has no sound card)' ((Get-Service Audiosrv).Status -eq 'Running' -and (Get-Service AudioEndpointBuilder).Status -eq 'Running')
Say '  --- svchost groups ---'
& tasklist.exe /svc /fi 'imagename eq svchost.exe' | Select-Object -Skip 3 | ForEach-Object { Say "  $_" }

# ---------- 3. network (stock) ----------
Say '== 3. network'
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { Say "  adapter $($_.Name): $($_.InterfaceDescription) $($_.Status) $($_.LinkSpeed)" }
Check 'got an IP by DHCP' ([bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }))
Check 'DNS works' ([bool](Resolve-DnsName www.microsoft.com -ErrorAction SilentlyContinue))
try { $r = Invoke-WebRequest https://www.epicgames.com -UseBasicParsing -TimeoutSec 30; Check 'HTTPS to epicgames.com' ($r.StatusCode -eq 200) } catch { Check 'HTTPS to epicgames.com' $false $_.Exception.Message }
Check 'firewall service running (stock)' ((Get-Service mpssvc).Status -eq 'Running')
Check 'firewall profiles on (stock)' (-not (Get-NetFirewallProfile | Where-Object { -not $_.Enabled }))

# ---------- 4. shell and apps ----------
Say '== 4. desktop, search, typing, Arabic keyboard'
foreach ($p in 'explorer', 'StartMenu', 'sihost', 'ctfmon') { Check "running: $p" ([bool](Get-Process $p -ErrorAction SilentlyContinue)) }   # StartMenu = Open-Shell
$searchExe = if ($win11) { 'C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\SearchHost.exe' } else { 'C:\Windows\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy\SearchApp.exe' }
Check 'Start menu search app present' (Test-Path $searchExe)
Check 'Arabic keyboard in the list' ((Get-WinUserLanguageList).InputMethodTips -match '0401:00000401')
Check 'Microsoft Store installed' ([bool](Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue))
if ($win11) {
  Check 'Windows 11: no Widgets process' (-not (Get-Process Widgets, WidgetService -ErrorAction SilentlyContinue))
  Check 'Windows 11: typing service present' ([bool](Get-Service TextInputManagementService -ErrorAction SilentlyContinue))
}
$bad = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Ok' }
Check 'all registered packaged apps are healthy' (-not $bad) (($bad | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')
foreach ($e in 'notepad.exe', 'cmd.exe', 'taskmgr.exe', 'regedit.exe', 'mmc.exe') { Check "exists: $e" ([bool](Get-Command $e -ErrorAction SilentlyContinue)) }
# side-by-side assemblies: a program that needs common controls v6 / GDI+ must start
$p = Start-Process taskmgr.exe -PassThru; Start-Sleep 5; Check 'Task Manager opens (common controls v6)' (-not $p.HasExited); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
$p = Start-Process mmc.exe -ArgumentList 'devmgmt.msc' -PassThru; Start-Sleep 8; Check 'Device Manager opens (MMC)' (-not $p.HasExited); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
try { Start-Process 'ms-settings:' ; Start-Sleep -Seconds 60; $sp = Get-Process SystemSettings -ErrorAction SilentlyContinue; Check 'Settings opens' ([bool]$sp); $sp | Stop-Process -Force -ErrorAction SilentlyContinue } catch { Check 'Settings opens' $false $_.Exception.Message }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try { $b = New-Object System.Drawing.Bitmap 10, 10; $b.Dispose(); Check '.NET + GDI+ work' $true } catch { Check '.NET + GDI+ work' $false $_.Exception.Message }

# ---------- 5. JDO-Tools ----------
Say '== 5. JDO-Tools'
$t = 'C:\JDO\JDO-Tools.ps1'
$e = $null; [void][Management.Automation.Language.Parser]::ParseFile($t, [ref]$null, [ref]$e); Check 'JDO-Tools parses' ($e.Count -eq 0)
# load its functions without the menu
$ast = [Management.Automation.Language.Parser]::ParseFile($t, [ref]$null, [ref]$null)
$defs = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -or ($args[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $args[0].Parent -eq $ast.EndBlock) }, $false)
$code = $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Add-Type' }, $false) | Select-Object -First 1
. ([scriptblock]::Create("`$root = 'C:\JDO'`n" + $code.Extent.Text + "`n" + (($defs | Where-Object { $_.Extent.Text -notmatch '^\$(switches|actions|first) ' } | ForEach-Object { $_.Extent.Text }) -join "`n")))
function Read-Host { '1' }   # answers the yes / no prompts
function Done([bool]$r) { }
try { Repair-TaskScheduler *> $null; Check 'tool 6: Task Scheduler repair runs, scheduler still running' ((Get-Service Schedule).Status -eq 'Running') } catch { Check 'tool 6' $false $_.Exception.Message }
try { Set-GamePriority *> $null; Check 'tool 16: priority option runs' $true } catch { Check 'tool 16' $false $_.Exception.Message }
Check 'tool 16 never touched a Windows program name' (-not (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' | Where-Object { (Test-Path "C:\Windows\System32\$($_.PSChildName)") -and (Test-Path "$($_.PSPath)\PerfOptions") -and $_.PSChildName -notmatch '^(SearchApp|SearchHost|TextInputHost)\.exe$' }))
if (Get-AppxPackage -Name Microsoft.WindowsStore) {
  $p = Start-Process 'shell:AppsFolder\Microsoft.WindowsStore_8wekyb3d8bbwe!App' -PassThru -ErrorAction SilentlyContinue; Start-Sleep 15
  Check 'Store window opens' ([bool](Get-Process WinStore.App -ErrorAction SilentlyContinue))
  Get-Process WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force
}
# 19 then 18: the Store ends up installed, as the image ships it
try { Remove-Store *> $null; Check 'tool 19: Store removed (Windows 11: switched off)' $(if ($win11) { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\InstallService').Start -eq 4 } else { -not (Get-AppxPackage -AllUsers -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue) }) } catch { Check 'tool 19' $false $_.Exception.Message }
try { Install-Store *> 'C:\JDO-TEST\tool18.txt'; $s = [bool](Get-AppxPackage -Name Microsoft.WindowsStore); Check 'tool 18: Store comes back from C:\JDO\Store' $s } catch { Check 'tool 18' $false $_.Exception.Message }

# ---------- 6. errors logged since setup ----------
Say '== 6. errors in the event logs'
foreach ($log in 'System', 'Application') {
  $ev = Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2 } -ErrorAction SilentlyContinue
  Say "  $log critical / error events: $($ev.Count)"
  $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    $m = ($_.Group[0].Message -split "`n")[0]; Say ("    {0}x {1}: {2}" -f $_.Count, $_.Name, $(if ($m.Length -gt 150) { $m.Substring(0, 150) } else { $m }))
  }
}
$crash = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000 } -ErrorAction SilentlyContinue
Check 'no program crashed (event 1000)' (-not $crash) (($crash | ForEach-Object { ($_.Message -split "`n")[0] } | Select-Object -Unique) -join ' | ')
$failedSvc = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Level = 2 } -ErrorAction SilentlyContinue
Check 'no service failed to start' (-not $failedSvc) (($failedSvc | ForEach-Object { ($_.Message -split "`n")[0] } | Select-Object -Unique) -join ' | ')
Check 'no unknown / failed devices' (-not (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Error' -and $_.ConfigManagerErrorCode -ne 22 })) ((Get-PnpDevice -PresentOnly | Where-Object { $_.Status -eq 'Error' -and $_.ConfigManagerErrorCode -ne 22 } | ForEach-Object { "$($_.FriendlyName) ($($_.ConfigManagerErrorCode))" }) -join ', ')

$fails = (Select-String -LiteralPath $rep -Pattern '^FAIL').Count
$passes = (Select-String -LiteralPath $rep -Pattern '^PASS').Count
Say ''
Say "RESULT: $passes passed, $fails failed"
Copy-Item $rep (Join-Path $here 'report.txt') -Force -ErrorAction SilentlyContinue
# the VM stays on: the report is read from its disk while it runs, so more checks / fixes can follow
Set-Content -LiteralPath (Join-Path $out 'done.txt') -Value (Get-Date -Format s)
# ---------- 7. every JDO-Tools option, one by one (a real PC froze after one of them) ----------
Say '== 7. every JDO-Tools option'
$tools = 'C:\JDO\JDO-Tools.ps1'
function Health {
  $bad = @()
  if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { $bad += 'explorer not running' }
  $cm = Get-Service CoreMessagingRegistrar -ErrorAction SilentlyContinue; if ($cm.Status -ne 'Running') { $bad += 'CoreMessaging not running (black screen)' }
  $im = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoreMessagingRegistrar').ImagePath; if ($im -notmatch 'LocalServiceNoNetwork') { $bad += "CoreMessaging moved: $im" }
  foreach ($d in Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 22 }) {
    if ($d.InstanceId -match '^ROOT\\RDPBUS|^ACPI\\PNP0800|^ACPI\\PNP0501') { continue }   # the safe ones option 2 switches off on purpose
    if ($d.Class -in 'System', 'Display', 'Computer', 'Processor', 'HDC', 'SCSIAdapter', 'DiskDrive', 'Keyboard', 'Mouse', 'HIDClass', 'USB', 'Net') { $bad += "device disabled: $($d.FriendlyName) ($($d.Class))" }
  }
  $bad
}
$plan = @(); foreach ($k in 1..20) { $plan += ,@("$k", '') }
for ($k = 23; $k -le 31; $k++) { $plan += ,@("$k", '0'); $plan += ,@("$k", '1') }
$plan += ,@('22', ''); $plan += ,@('21', '')
foreach ($p in $plan) {
  if ($p[0] -eq '23' -and $p[1] -eq '1') { $p[1] = '0' }   # notifications: off is the default, end on off
  $label = "option $($p[0])$(if ($p[1]) { " set $($p[1])" })"
  $log = Join-Path $out ("tool-{0}{1}.txt" -f $p[0], $p[1])
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tools`" -Run $($p[0])$(if ($p[1]) { " -Set $($p[1])" }) < nul > `"$log`" 2>&1"
  $t0 = Get-Date; $pr = Start-Process cmd.exe -ArgumentList "/c $cmd" -WindowStyle Hidden -PassThru
  $done = $pr.WaitForExit(600000)
  if (-not $done) { & taskkill.exe /T /F /PID $pr.Id | Out-Null }
  $h = @(Health)
  $err = @(Select-String -LiteralPath $log -Pattern 'Exception|is not recognized|Cannot find|ParserError' -ErrorAction SilentlyContinue | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() })
  Check ("tool $label  ({0:N0} s)" -f ((Get-Date) - $t0).TotalSeconds) ($done -and -not $h -and -not $err) ((@($(if (-not $done) { 'did not finish in 10 min' })) + $h + $err) -join '; ')
}
# the switches back to how the image ships them
# every switch back to how the image ships it (23 notifications off, 24 touch keyboard on, 25 Bluetooth off, 26 Windows Update off,
# 27 Defender off, 28 UAC prompts off (no prompts), 29 printing off, 30 iGPU on, 31 clipboard history off)
foreach ($pair in @(@('23', '0'), @('24', '1'), @('25', '0'), @('26', '0'), @('27', '0'), @('28', '0'), @('29', '0'), @('30', '1'), @('31', '0'))) {
  & cmd.exe /c "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tools`" -Run $($pair[0]) -Set $($pair[1]) < nul > nul 2>&1"
}
$fails = (Select-String -LiteralPath $rep -Pattern '^FAIL').Count; $passes = (Select-String -LiteralPath $rep -Pattern '^PASS').Count
Say "RESULT after the tools: $passes passed, $fails failed"
# then one restart for the idle numbers (second pass above)
Set-Content "$out\idle-pass" '1'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'JDO VM idle' "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $out\vm-check.ps1"
Copy-Item $MyInvocation.MyCommand.Path "$out\vm-check.ps1" -Force -ErrorAction SilentlyContinue
& shutdown.exe /r /t 20
