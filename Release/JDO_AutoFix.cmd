@echo off
:: ============================================================
::  JDO Al-Shayeb Tweak - Auto Fix
::  Detects common Windows / app / tweak problems and fixes them.
::  Safe to run any time. Creates a restore point first.
:: ============================================================
setlocal EnableExtensions
title JDO Auto Fix

:: --- self-elevate ---
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

set "LOG=%USERPROFILE%\Desktop\JDO_AutoFix_log.txt"
set "MODE=%~1"
echo JDO Auto Fix - %date% %time% > "%LOG%"

echo.
echo   =============================================
echo      JDO AL-SHAYEB TWEAK  -  AUTO FIX
echo   =============================================
echo.
echo   [1] Quick fix   (2-5 min)  - services, network, Store, temp, tweak problems
echo   [2] Full fix    (20-40 min) - quick fix + DISM + SFC system file repair
echo   [3] Undo tweaks only        - put tweaked settings back to Windows defaults
echo.
if not "%MODE%"=="" goto :start
choice /c 123 /n /m "  Choose 1, 2 or 3: "
set "MODE=%errorlevel%"
:start

call :step "Creating restore point"
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" /v SystemRestorePointCreationFrequency /t REG_DWORD /d 0 /f >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-ComputerRestore -Drive \"$env:SystemDrive\\\" -EA 0; Checkpoint-Computer -Description 'JDO AutoFix' -RestorePointType MODIFY_SETTINGS -EA 0" >>"%LOG%" 2>&1

if "%MODE%"=="3" goto :undo

:: ------------------------------------------------------------
call :step "Scanning for problems"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$found = 0;" ^
 "function P($m){ Write-Host ('   [!] ' + $m) -ForegroundColor Yellow; Add-Content $env:LOG ('PROBLEM: ' + $m); $script:found++ }" ^
 "$d = Get-PSDrive C; if ($d.Free/1GB -lt 15) { P ('Low disk space on C: ' + [int]($d.Free/1GB) + ' GB free') };" ^
 "foreach ($s in 'AudioSrv','AudioEndpointBuilder','Dnscache','Dhcp','BFE','CryptSvc','EventLog','Schedule','Winmgmt','Themes','Power','AppXSvc','ClipSVC','StateRepository','nsi','NlaSvc') { $v = (Get-ItemProperty \"HKLM:\SYSTEM\CurrentControlSet\Services\$s\" -EA 0).Start; if ($v -eq 4) { P \"Essential service disabled: $s\" } };" ^
 "if (-not (Get-AppxPackage -AllUsers Microsoft.WindowsStore)) { P 'Microsoft Store is missing' };" ^
 "try { [void][Net.Dns]::GetHostEntry('www.microsoft.com') } catch { P 'DNS / internet name resolution is failing' };" ^
 "$bad = Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' -EA 0; foreach ($b in $bad) { P ('Driver problem: ' + $b.Name) };" ^
 "$bcd = (bcdedit /enum '{current}') -join ' '; if ($bcd -match 'useplatformclock|disabledynamictick|useplatformtick') { P 'Boot timer tweaks found (can cause stutter)' }; if ($bcd -match 'testsigning\s+Yes') { P 'Test signing is on (blocks anti-cheat)' };" ^
 "if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -EA 0).DisableTaskMgr -eq 1) { P 'Task Manager is locked' };" ^
 "if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -EA 0).ProxyEnable -eq 1) { P 'A proxy is enabled' };" ^
 "if ($found -eq 0) { Write-Host '   No problems detected - running maintenance anyway.' -ForegroundColor Green }"

:: ------------------------------------------------------------
call :step "Restoring essential Windows services"
for %%S in (AudioSrv AudioEndpointBuilder Dnscache Dhcp NlaSvc nsi iphlpsvc LanmanWorkstation BFE mpssvc CryptSvc EventLog Schedule Winmgmt Themes FontCache Power ProfSvc UserManager gpsvc ShellHWDetection SENS EventSystem SystemEventsBroker CDPSvc DPS PcaSvc WpnService BITS UsoSvc Wcmsvc WlanSvc) do call :svc %%S auto
for %%S in (netprofm TimeBrokerSvc StorSvc TokenBroker StateRepository AppXSvc ClipSVC InstallService LicenseManager wlidsvc wuauserv TrustedInstaller W32Time KeyIso VaultSvc msiserver hidserv TabletInputService bthserv XboxGipSvc XblAuthManager XblGameSave XboxNetApiSvc DeviceAssociationService) do call :svc %%S demand
for %%S in (AudioSrv Dnscache BFE CryptSvc Schedule Themes) do net start %%S >nul 2>&1

call :step "Unlocking Task Manager / Regedit / CMD"
for %%H in (HKCU HKLM) do (
  reg delete "%%H\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /f >nul 2>&1
  reg delete "%%H\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableRegistryTools /f >nul 2>&1
  reg delete "%%H\Software\Policies\Microsoft\Windows\System" /v DisableCMD /f >nul 2>&1
)

call :step "Removing boot tweaks that cause stutter"
for %%V in (useplatformclock useplatformtick disabledynamictick tscsyncpolicy x2apicpolicy) do bcdedit /deletevalue %%V >nul 2>&1
bcdedit /set testsigning off >nul 2>&1
bcdedit /set nointegritychecks off >nul 2>&1

call :step "Repairing network"
netsh winsock reset >>"%LOG%" 2>&1
netsh int ip reset >>"%LOG%" 2>&1
netsh winhttp reset proxy >>"%LOG%" 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
ipconfig /flushdns >nul
ipconfig /registerdns >nul

call :step "Repairing Microsoft Store and apps"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$s = Get-AppxPackage -AllUsers Microsoft.WindowsStore;" ^
 "if ($s) { $s | % { Add-AppxPackage -DisableDevelopmentMode -Register \"$($_.InstallLocation)\AppXManifest.xml\" -EA 0 }; Write-Host '   Store re-registered' }" ^
 "else { Write-Host '   Store missing - reinstalling from Microsoft...'; Start-Process wsreset.exe -ArgumentList '-i' -Wait }" ^
 "foreach ($n in 'Microsoft.Windows.ShellExperienceHost','Microsoft.Windows.StartMenuExperienceHost','Microsoft.DesktopAppInstaller') { Get-AppxPackage -AllUsers $n | % { Add-AppxPackage -DisableDevelopmentMode -Register \"$($_.InstallLocation)\AppXManifest.xml\" -EA 0 } }" >>"%LOG%" 2>&1

call :step "Repairing WMI"
winmgmt /verifyrepository >>"%LOG%" 2>&1 || winmgmt /salvagerepository >>"%LOG%" 2>&1

call :step "Syncing clock"
w32tm /resync /force >nul 2>&1

call :step "Rescanning hardware"
pnputil /scan-devices >nul 2>&1

call :step "Cleaning temporary files"
del /f /s /q "%TEMP%\*" >nul 2>&1
del /f /s /q "%SystemRoot%\Temp\*" >nul 2>&1
del /f /s /q "%LOCALAPPDATA%\D3DSCache\*" >nul 2>&1

if "%MODE%"=="2" (
  call :step "DISM - repairing the Windows image (this takes a while)"
  DISM /Online /Cleanup-Image /RestoreHealth
  call :step "SFC - repairing system files (this takes a while)"
  sfc /scannow
)
goto :finish

:: ------------------------------------------------------------
:undo
call :step "Undoing tweaks: input devices"
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters" /v MouseDataQueueSize /f >nul 2>&1
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" /v KeyboardDataQueueSize /f >nul 2>&1
for %%S in (usbxhci USBHUB3 nvlddmkm mouclass kbdclass) do reg delete "HKLM\SYSTEM\CurrentControlSet\Services\%%S\Parameters" /v ThreadPriority /f >nul 2>&1
call :step "Undoing tweaks: CPU, memory, GPU"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 2 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 20 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 10 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v LargeSystemCache /t REG_DWORD /d 0 /f >nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler" /v EnablePreemption /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\Dwm" /v OverlayTestMode /f >nul 2>&1
powershell -NoProfile -Command "Enable-MMAgent -MemoryCompression -EA 0" >nul 2>&1
call :step "Undoing tweaks: network"
netsh int tcp reset >>"%LOG%" 2>&1
netsh int tcp set global autotuninglevel=normal >nul 2>&1
call :step "Undoing tweaks: power plans"
powercfg -restoredefaultschemes
call :step "Undoing tweaks: services"
for %%S in (AudioSrv Dnscache BFE CryptSvc Schedule Themes SysMain WSearch Spooler BITS UsoSvc DiagTrack) do call :svc %%S auto
for %%S in (wuauserv XboxGipSvc XblAuthManager XblGameSave XboxNetApiSvc bthserv W32Time) do call :svc %%S demand
call :step "Undoing tweaks: boot"
for %%V in (useplatformclock useplatformtick disabledynamictick tscsyncpolicy) do bcdedit /deletevalue %%V >nul 2>&1

:finish
echo.
echo   =============================================
echo      Done. Log saved to: %LOG%
echo      Restart your PC to finish the repairs.
echo   =============================================
echo.
choice /c YN /n /m "  Restart now? (Y/N): "
if %errorlevel%==1 shutdown /r /t 5
exit /b 0

:: ---------------- helpers ----------------
:step
echo.
echo   ^>^> %~1
echo [%time%] %~1 >> "%LOG%"
exit /b 0

:svc
reg query "HKLM\SYSTEM\CurrentControlSet\Services\%~1" >nul 2>&1 || exit /b 0
sc config "%~1" start= %~2 >nul 2>&1
exit /b 0
