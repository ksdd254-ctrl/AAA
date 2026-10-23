# JDO x QHT - first boot (once, in the background after the desktop is up, under a minute):
# power plan, memory manager, scheduled tasks, devices - the parts that need the running PC and its hardware.
# Every JDO-Tools step runs in its own process with a time limit: a device or WMI call that never answers must not
# hold up setup or the first sign-in (the VM install test found one that did).
$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:WINDIR 'Setup\Scripts'
$marker = Join-Path $dir 'firstboot.done'
if (Test-Path $marker) { return }
# runs at the first sign-in (FirstLogonCommands): make sure it has the full admin token. UAC is set to elevate
# administrators without asking, so this does not show a prompt.
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}
Start-Transcript (Join-Path $dir 'firstboot.log') -Append | Out-Null
$tools = Join-Path $env:SystemDrive 'JDO\JDO-Tools.ps1'

function Run-Step([string]$Switch, [int]$Seconds, [string]$Script = $tools) {
  $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" $Switch" -PassThru -WindowStyle Hidden
  if (-not $p.WaitForExit($Seconds * 1000)) {
    Write-Host "  $Switch did not finish in $Seconds s - stopped, carrying on"
    & taskkill.exe /T /F /PID $p.Id | Out-Null
  } else { Write-Host "  $Switch done" }
}

# (services, Windows Update and every registry tweak are already in the image - only what needs the running PC is here)
# JDO Ultimate power plan (full speed, real CPU usage, no sleep / USB / PCIe power saving, no hibernation file)
Run-Step '-Power' 120

# one desktop folder with the toolbox, the tweaks and the app installer (replaces the single JDO Tools shortcut)
$deskDir = Join-Path $env:PUBLIC 'Desktop\JDO x QHT'
New-Item -ItemType Directory -Force $deskDir | Out-Null
$sh = New-Object -ComObject WScript.Shell
$icons = Join-Path $env:SystemDrive 'JDO\Icons'
foreach ($i in @(@('1 - Toolbox (fixes, priorities, Store)', 'JDO-Tools.cmd', 'tools'), @('2 - Tweaks (JDO x QHT)', 'JDO-x-QHT.cmd', 'tweaks'),
                 @('3 - Apps (Brave, Chrome, Epic, Discord, AnyDesk, NVIDIA, Voicemeeter)', 'JDO-Apps.cmd', 'apps'))) {
  $l = $sh.CreateShortcut((Join-Path $deskDir ($i[0] + '.lnk')))
  $l.TargetPath = Join-Path $env:SystemDrive ('JDO\' + $i[1]); $l.WorkingDirectory = Join-Path $env:SystemDrive 'JDO'
  $l.IconLocation = "$icons\$($i[2]).ico,0"; $l.Save()
}
# the folder itself gets the JDO folder icon
Set-Content (Join-Path $deskDir 'desktop.ini') "[.ShellClassInfo]`r`nIconResource=$icons\folder.ico,0`r`n" -Encoding Unicode
& attrib.exe +s +h (Join-Path $deskDir 'desktop.ini'); & attrib.exe +r $deskDir
Remove-Item (Join-Path $env:PUBLIC 'Desktop\JDO Tools.lnk') -Force -ErrorAction SilentlyContinue
# the Start menu entry gets the same icon
$sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\JDO Tools.lnk'
if (Test-Path $sm) { $l = $sh.CreateShortcut($sm); $l.IconLocation = "$icons\tools.ico,0"; $l.Save() }

# JDO x QHT: the merged FoxOS / SharawyOS / SapphireOS tweaks + Fortnite FPS + the name in the boot menu (also runs 5 s after every desktop)
# (the JDO x QHT tweaks start 5 s after the desktop from the Run key, and restart the PC once everything here is finished)

# no Memory Compression process, no page combining scans
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue
Disable-MMAgent -PageCombining -ErrorAction SilentlyContinue

# scheduled tasks that only collect data or run maintenance in the background
$folders = '\Microsoft\Windows\Application Experience\', '\Microsoft\Windows\Customer Experience Improvement Program\',
           '\Microsoft\Windows\Feedback\Siuf\', '\Microsoft\Windows\Windows Error Reporting\', '\Microsoft\Windows\Maps\',
           '\Microsoft\Windows\Flighting\', '\Microsoft\Windows\Location\', '\Microsoft\Windows\Work Folders\',
           '\Microsoft\Windows\Power Efficiency Diagnostics\', '\Microsoft\Windows\DiskFootprint\', '\Microsoft\Windows\PI\',
           '\Microsoft\Windows\NetTrace\', '\Microsoft\Windows\Diagnosis\', '\Microsoft\Windows\RetailDemo\',
           '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WaaSMedic\',
           '\Microsoft\Windows\Servicing\',   # StartComponentCleanup: TiWorker (Windows Modules Installer Worker) at idle
           '\Microsoft\Windows\XblGameSave\', '\Microsoft\Windows\Bluetooth\',
           '\Microsoft\Windows\Shell\', '\Microsoft\Windows\Speech\', '\Microsoft\Windows\Maintenance\',
           '\Microsoft\Windows\.NET Framework\',   # NGEN: native images are removed from this build on purpose
           # from the five-build comparison (owner's list): backups to the cloud, cross-device, memory / disk checks
           # nobody asked for, hotpatch, printing, power-grid telemetry, AI, Xbox save sync, usage insights
           '\Microsoft\Windows\CloudRestore\', '\Microsoft\Windows\CrossDevice\', '\Microsoft\Windows\Data Integrity Scan\',
           '\Microsoft\Windows\ExploitGuard\', '\Microsoft\Windows\FileHistory\', '\Microsoft\Windows\Hotpatch\',
           '\Microsoft\Windows\MemoryDiagnostic\', '\Microsoft\Windows\PerformanceTrace\', '\Microsoft\Windows\Printing\',
           '\Microsoft\Windows\RemoteAssistance\', '\Microsoft\Windows\SettingSync\', '\Microsoft\Windows\Sustainability\',
           '\Microsoft\Windows\UsageAndQualityInsights\', '\Microsoft\Windows\WindowsAI\', '\Microsoft\Windows\AccountHealth\',
           '\Microsoft\XblGameSave\'
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend' -ErrorAction SilentlyContinue).Start -eq 4) {
  $folders += '\Microsoft\Windows\Windows Defender\'
}
# the language-pack installer: its failed jobs made Windows show "Getting Windows ready" at every restart
$folders += '\Microsoft\Windows\LanguageComponentsInstaller\', '\Microsoft\Windows\MUI\', '\Microsoft\Windows\International\'
foreach ($f in $folders) {
  Get-ScheduledTask -TaskPath $f -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
}
# tasks the other gaming builds switch off (not network, Store updates, time sync or disk TRIM)
$folders += '\Microsoft\Windows\MemoryDiagnostic\', '\Microsoft\Windows\Printing\', '\Microsoft\Windows\RemoteAssistance\',
            '\Microsoft\Windows\CloudRestore\', '\Microsoft\Windows\Data Integrity Scan\', '\Microsoft\Windows\FileHistory\',
            '\Microsoft\Windows\SettingSync\', '\Microsoft\Windows\Sustainability\', '\Microsoft\Windows\PerformanceTrace\',
            '\Microsoft\Windows\UsageAndQualityInsights\', '\Microsoft\Windows\WindowsAI\', '\Microsoft\Windows\AccountHealth\',
            '\Microsoft\Windows\Hotpatch\', '\Microsoft\Windows\DUSM\', '\Microsoft\Windows\Device Setup\'
foreach ($f in $folders) { Get-ScheduledTask -TaskPath $f -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
foreach ($t in @{ p='\Microsoft\Windows\DiskCleanup\'; n='SilentCleanup' }, @{ p='\Microsoft\Windows\Registry\'; n='RegIdleBackup' },
               @{ p='\Microsoft\Windows\Device Information\'; n='Device User' }, @{ p='\Microsoft\Windows\DiskDiagnostic\'; n='Microsoft-Windows-DiskDiagnosticResolver' },
               @{ p='\Microsoft\Windows\WDI\'; n='ResolutionHost' }, @{ p='\Microsoft\Windows\EnterpriseMgmt\'; n='MDMMaintenenceTask' },
               @{ p='\Microsoft\Windows\ExploitGuard\'; n='ExploitGuard MDM policy Refresh' }, @{ p='\Microsoft\Windows\AppID\'; n='SmartScreenSpecific' }) {
  Disable-ScheduledTask -TaskPath $t.p -TaskName $t.n -ErrorAction SilentlyContinue | Out-Null
}
foreach ($t in @{ p='\Microsoft\Windows\Autochk\'; n='Proxy' }, @{ p='\Microsoft\Windows\CloudExperienceHost\'; n='CreateObjectTask' },
               @{ p='\Microsoft\Windows\DiskDiagnostic\'; n='Microsoft-Windows-DiskDiagnosticDataCollector' },
               @{ p='\Microsoft\Windows\Device Information\'; n='Device' },
               @{ p='\Microsoft\Windows\DiskDiagnostic\'; n='Microsoft-Windows-DiskDiagnosticResolver' },
               @{ p='\Microsoft\Windows\WDI\'; n='ResolutionHost' }, @{ p='\Microsoft\Windows\Registry\'; n='RegIdleBackup' },
               @{ p='\'; n='StartOobeAppsScanAfterUpdate' }) {
  Disable-ScheduledTask -TaskPath $t.p -TaskName $t.n -ErrorAction SilentlyContinue | Out-Null
}
# Edge is not in the image; drop its updater tasks
Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# component store cleanup, when the PC that built the image could not do it (NTFS compression off there)
if (Test-Path (Join-Path $dir 'cleanup-at-first-boot')) {
  # DISM needs the Windows Modules Installer, which SetupComplete switched off (no update may hang a restart): on for
  # the cleanup only, 10 minutes at most, then off again - the VM test caught first boot waiting here forever
  & sc.exe config TrustedInstaller start= demand | Out-Null
  $d = Start-Process dism.exe -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet' -WindowStyle Hidden -PassThru
  if (-not $d.WaitForExit(600000)) { & taskkill.exe /T /F /PID $d.Id | Out-Null; Write-Host '  component cleanup stopped after 10 minutes' }
  & sc.exe stop TrustedInstaller | Out-Null
  & sc.exe config TrustedInstaller start= disabled | Out-Null
  Remove-Item (Join-Path $dir 'cleanup-at-first-boot') -Force
}

# temp files left by setup
Remove-Item "$env:WINDIR\Temp\*", "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

# done before the device step, so even a stuck device can never make first boot run again at every sign-in
New-Item -ItemType File $marker -Force | Out-Null
# devices + per-device power saving (JDO-Tools > 2 does the same again after drivers are installed)
Run-Step '-Devices' 180
New-Item -ItemType File (Join-Path $dir 'firstboot.finished') -Force | Out-Null
Stop-Transcript | Out-Null
