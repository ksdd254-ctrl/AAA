# JDO Lite - checks run INSIDE the test virtual machine after the first sign-in.
# Writes C:\JDO-TEST\report.txt (read from the VM disk afterwards) and a copy next to this script, then shuts down.
$ErrorActionPreference = 'Continue'
$out = 'C:\JDO-TEST'; New-Item -ItemType Directory -Force $out | Out-Null
$rep = Join-Path $out 'report.txt'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
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
foreach ($s in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'wlidsvc', 'InstallService', 'PushToInstall') {
  Check "first boot turned off $s" ((Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue).StartMode -eq 'Disabled')
}
Check 'Task Scheduler running' ((Get-Service Schedule).Status -eq 'Running')
Check 'scheduled tasks readable' ((Get-ScheduledTask -ErrorAction SilentlyContinue | Measure-Object).Count -gt 10)
Check 'Run as administrator service (Appinfo) starts' ($(Start-Service Appinfo -ErrorAction SilentlyContinue; (Get-Service Appinfo).Status -eq 'Running'))
Check 'UAC on, no prompts' ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA -eq 1)
Check 'black desktop' ((Get-ItemProperty 'HKCU:\Control Panel\Colors').Background -eq '0 0 0')
Check 'dark mode' ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme -eq 0)

# ---------- 2. idle processes after things settle ----------
Say '== 2. processes at idle'
Start-Sleep -Seconds 240
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
foreach ($p in 'explorer', 'StartMenuExperienceHost', 'ShellExperienceHost', 'sihost', 'ctfmon') { Check "running: $p" ([bool](Get-Process $p -ErrorAction SilentlyContinue)) }
Check 'Start menu search app present' (Test-Path 'C:\Windows\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy\SearchApp.exe')
Check 'Arabic keyboard in the list' ((Get-WinUserLanguageList).InputMethodTips -match '0401:00000401')
Check 'no Microsoft Store' (-not (Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue))
$bad = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Ok' }
Check 'all registered packaged apps are healthy' (-not $bad) (($bad | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')
foreach ($e in 'notepad.exe', 'mspaint.exe', 'cmd.exe', 'taskmgr.exe', 'regedit.exe', 'mmc.exe') { Check "exists: $e" ([bool](Get-Command $e -ErrorAction SilentlyContinue)) }
# side-by-side assemblies: a program that needs common controls v6 / GDI+ must start
$p = Start-Process taskmgr.exe -PassThru; Start-Sleep 5; Check 'Task Manager opens (common controls v6)' (-not $p.HasExited); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
$p = Start-Process mmc.exe -ArgumentList 'devmgmt.msc' -PassThru; Start-Sleep 8; Check 'Device Manager opens (MMC)' (-not $p.HasExited); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
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
Check 'tool 16 never touched a Windows program name' (-not (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' | Where-Object { (Test-Path "C:\Windows\System32\$($_.PSChildName)") -and (Test-Path "$($_.PSPath)\PerfOptions") -and $_.PSChildName -notmatch '^(SearchApp|TextInputHost)\.exe$' }))
try { Install-Store *> $null; $s = [bool](Get-AppxPackage -Name Microsoft.WindowsStore); Check 'tool 18: Store comes back from C:\JDO\Store' $s } catch { Check 'tool 18' $false $_.Exception.Message }
if (Get-AppxPackage -Name Microsoft.WindowsStore) {
  $p = Start-Process 'shell:AppsFolder\Microsoft.WindowsStore_8wekyb3d8bbwe!App' -PassThru -ErrorAction SilentlyContinue; Start-Sleep 15
  Check 'tool 18: Store window opens' ([bool](Get-Process WinStore.App -ErrorAction SilentlyContinue))
  Get-Process WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force
}
try { Remove-Store *> $null; Check 'tool 19: Store removed again' (-not (Get-AppxPackage -Name Microsoft.WindowsStore)) } catch { Check 'tool 19' $false $_.Exception.Message }

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
