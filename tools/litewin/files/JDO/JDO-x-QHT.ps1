# JDO x QHT - the merged tweaks of FoxOS, SharawyOS and SapphireOS, de-duplicated, one best value per setting.
# Runs once at the first desktop (firstboot.ps1) and any time again from JDO-Tools. Safe to run repeatedly.
#
# Left out ON PURPOSE (these were in the three systems and break things):
#   * every network setting, hostname / computer name, serials, MAC, DMA remapping (writes to network driver keys too)
#   * renaming RuntimeBroker / ShellExperienceHost / StartMenuExperienceHost / SearchApp / backgroundTaskHost /
#     TextInputHost / ctfmon / CompPkgSrv / upfc / mobsync / smartscreen  -> kills Start search, the Store, the NVIDIA
#     Control Panel and anything packaged
#   * disabling TokenBroker, DevQueryBroker, FontCache, Themes, FrameServer, EFS, iphlpsvc, Dnscache and the other
#     service lists (Store / sign-in / NVIDIA App / network need them)
#   * DEP / process-mitigation changes (anti-cheats need them), Windows Update server blanking, HDCP off,
#     NVIDIA telemetry removal (breaks the NVIDIA App), ECC, Photo Viewer associations, ProductName rename
# At the end a guard checks the services and programs that Task Scheduler, Microsoft apps and NVIDIA need.
param([switch]$Quiet, [switch]$DryRun)   # -DryRun prints every change instead of making it
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $DryRun -and -not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
if (-not $Quiet -and -not $DryRun) { Start-Transcript (Join-Path $root 'logs\JDO-x-QHT.log') -Append | Out-Null }
$name = 'JDO x QHT'
# Open-Shell (classic Start menu with its own search box, fewer idle processes): quiet install the first time.
# The installer is Open-Shell 4.4.198 from github.com/Open-Shell/Open-Shell-Menu (SHA-256 a4d2d445...48c3f, checked against GitHub).
$osSetup = Join-Path $root 'Apps\OpenShellSetup.exe'
if (-not $DryRun -and (Test-Path $osSetup) -and -not (Test-Path "$env:ProgramFiles\Open-Shell\StartMenu.exe")) {
  Write-Host 'Open-Shell: installing'
  Start-Process $osSetup -ArgumentList '/qn', 'ADDLOCAL=StartMenu' -Wait
}
# the old Start menu (StartMenuExperienceHost) is switched off once Open-Shell is there: renamed with a marker file, so
# JDO-Tools option 22 / 20 can put it back. SearchApp and everything else Microsoft stays untouched.
$smOff = Join-Path $root 'startmenu.off'
$smExe = "$env:WINDIR\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe"
if (-not $DryRun -and (Test-Path "$env:ProgramFiles\Open-Shell\StartMenu.exe") -and (Test-Path $smExe) -and -not (Test-Path $smOff)) {
  & takeown.exe /f $smExe 2>$null | Out-Null
  & icacls.exe $smExe /grant '*S-1-5-32-544:F' 2>$null | Out-Null
  Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
  Rename-Item $smExe 'StartMenuExperienceHost.exe.qht-off' -ErrorAction SilentlyContinue
  if (Test-Path "$smExe.qht-off") { New-Item -ItemType File $smOff -Force | Out-Null; Write-Host 'Old Start menu: off (Open-Shell is the Start menu)' }
}
# first run only: black cover with purple text so nothing can be touched, then restart. Later runs are silent (no loop).
$firstMark = Join-Path $root 'qht.done'
$first = (-not $Quiet) -and (-not $DryRun) -and (-not (Test-Path $firstMark))
$stopFile = Join-Path $root 'screen.stop'
if (-not $DryRun) { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue }
if ($first) { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$(Join-Path $root 'JDO-Screen.ps1')`"" }

# Backup: every value this script changes is recorded with what it was before (or "did not exist"), so JDO-Tools can undo it.
$bk = Join-Path $root ('Backup\QHT-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$undo = New-Object System.Collections.Generic.List[object]
$seen = @{}
if (-not $DryRun) {
  New-Item -ItemType Directory -Force $bk | Out-Null
  & bcdedit.exe /export (Join-Path $bk 'bcd.bak') 2>$null | Out-Null
}
function Native([string]$Exe) { $a = @($args); if ($DryRun) { Write-Host "DRY $Exe $($a -join ' ')" } else { & $Exe @a 2>$null | Out-Null } }
function Reg-Set([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
  if ($DryRun) { Write-Host "DRY reg $Path\$Name = $Value"; return }
  $key = "$Path|$Name"
  if (-not $seen.ContainsKey($key)) {
    $seen[$key] = $true
    $old = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    $had = ($null -ne $old) -and ($null -ne $old.$Name)
    $kind = if ($had) { (Get-Item $Path).GetValueKind($Name).ToString() } else { $Type }
    $undo.Add([pscustomobject]@{ Path = $Path; Name = $Name; Existed = $had; Kind = $kind; Value = $(if ($had) { $old.$Name } else { $null }) })
  }
  try {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
  } catch { Write-Host "  skipped $Path\$Name" }
}

# ---- name: boot menu, disk label, system page ----
Write-Host "Name: $name"
Native bcdedit.exe /set '{current}' description $name
Native bcdedit.exe /set '{bootmgr}' description $name
Native cmd.exe /c "label $($env:SystemDrive) $name"
$oem = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
Reg-Set $oem 'Manufacturer' $name String
Reg-Set $oem 'Model' $name String
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'RegisteredOwner' $name String

# ---- boot / timer latency (SharawyOS + SapphireOS; Fox has none) ----
Native bcdedit.exe /set disabledynamictick yes      # no tick coalescing: steadier frame pacing
Native bcdedit.exe /deletevalue useplatformtick   # Sharawy "No" and Sapphire default disagree: Windows default wins
Native bcdedit.exe /set hypervisorlaunchtype off    # Fox + Sharawy
Native bcdedit.exe /set bootmenupolicy legacy       # Sapphire + Sharawy
Native bcdedit.exe /set quietboot on
Native bcdedit.exe /set bootux disabled                   # no boot animation (BlitzOS)
Native bcdedit.exe /timeout 3                            # boot menu waits 3 s (BlitzOS)
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
Reg-Set $k 'SerializeTimerExpiration' 2                  # Sapphire
$mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
Reg-Set $mm 'DisablePagingExecutive' 1                    # kernel + drivers stay in RAM (Sharawy)
Reg-Set $mm 'DisablePagingCombining' 1                    # Sharawy
Reg-Set "$mm\PrefetchParameters" 'EnablePrefetcher' 0
Reg-Set "$mm\PrefetchParameters" 'EnableSuperfetch' 0
# scheduler: Fox uses 0x18, the image 0x26 (short quantum, fixed, 3:1 foreground boost) - 0x26 stays (best for one game)
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 0x26
# VBS / HVCI off (Fox + image)
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags' 0

# ---- GPU ----
# NVIDIA: stay in P0 (no clock ramp-up stutter), driver logging off. Only the display adapters' own class keys.
foreach ($g in Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' }) {
  $drv = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.PNPDeviceID)" -ErrorAction SilentlyContinue).Driver
  if ($drv) { Reg-Set "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drv" 'DisableDynamicPstate' 1; Write-Host "  NVIDIA P0 state: $($g.Name)" }
}
foreach ($n in 'LogWarningEntries', 'LogPagingEntries', 'LogEventEntries', 'LogErrorEntries') { Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm' $n 0 }
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5          # MPO off: no overlay flicker / frame-time spikes (Sapphire)
$smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
if (Test-Path $smi) { Native $smi '-acp' '0' }                    # unrestricted clock policy (Fox + Sapphire + Sharawy)

# NVIDIA telemetry off (FoxOS + SapphireOS): driver and control-panel opt-out, the three telemetry feature flags, and the NvTm scheduled tasks.
# Files and services are not deleted. If the NVIDIA App ever misbehaves: JDO-Tools option 22 puts everything back.
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup' 'SendTelemetryData' 0
Reg-Set 'HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' 0
Reg-Set 'HKCU:\Software\NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' 0
foreach ($rid in 'EnableRID44231', 'EnableRID64640', 'EnableRID66610') { Reg-Set 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS' $rid 0 }
if (-not $DryRun) {
  $nvTasks = @(Get-ScheduledTask -TaskName 'NvTm*' -ErrorAction SilentlyContinue)
  if ($nvTasks) { $nvTasks | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null; $nvTasks.TaskName | Set-Content (Join-Path $bk 'nvidia-tasks.txt'); Write-Host "  NVIDIA telemetry tasks off: $($nvTasks.Count)" }
} else { Write-Host 'DRY disable scheduled tasks NvTm*' }
# ---- USB / HID power saving off (Fox's list, USB only - network adapters are never touched) ----
$net = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | ForEach-Object { $_.InstanceId.ToUpper() })
$vals = 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'EnableSelectiveSuspend', 'SelectiveSuspendOn', 'SelectiveSuspendEnabled',
        'DeviceSelectiveSuspended', 'WaitWakeEnabled', 'D3ColdSupported', 'EnableIdlePowerManagement'
foreach ($dev in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB', 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue | Get-ChildItem -ErrorAction SilentlyContinue) {
  if ($net -contains ($dev.Name -replace '^.*\\Enum\\', '').ToUpper()) { continue }
  $p = Join-Path $dev.PSPath 'Device Parameters'
  if (Test-Path $p) {
    foreach ($v in $vals) { if ($null -ne (Get-ItemProperty $p -Name $v -ErrorAction SilentlyContinue).$v -or $v -in 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'SelectiveSuspendEnabled') { Reg-Set $p $v 0 } }
  }
}

# ---- privacy / background (Fox + Sharawy + CTT, what the image did not have yet; microphone + camera stay on) ----
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
Reg-Set "$pol\LocationAndSensors" 'DisableWindowsLocationProvider' 1
Reg-Set "$pol\LocationAndSensors" 'DisableLocationScripting' 1
Reg-Set "$pol\System" 'EnableMmx' 0                                           # phone linking
Reg-Set "$pol\Windows Search" 'AllowCloudSearch' 0
Reg-Set "$pol\Windows Search" 'DoNotUseWebResults' 1
Reg-Set "$pol\Windows Search" 'AllowCortanaAboveLock' 0
$cu = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
Reg-Set "$cu\Mobility" 'CrossDeviceEnabled' 0
Reg-Set "$cu\Mobility" 'PhoneLinkEnabled' 0
Reg-Set "$cu\ContentDeliveryManager" 'SubscribedContentEnabled' 0
Reg-Set "$cu\Notifications\Settings" 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0
if (-not $DryRun) { Remove-Item "$cu\IrisService" -Recurse -Force -ErrorAction SilentlyContinue }   # Spotlight leftovers (Sharawy)
Reg-Set "$cu\Themes\Personalize" 'EnableTransparency' 0
# classic Alt-Tab (Sapphire default)
Reg-Set "$cu\Explorer" 'AltTabSettings' 1
Reg-Set "$cu\Explorer" 'HoverSelectDesktops' 0

# ---- "Run as administrator" / downloaded files: no Run / Cancel security warning ----
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1
Reg-Set 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1
$low = '.exe;.bat;.cmd;.com;.msi;.ps1;.vbs;.reg;.lnk;.jar'
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' $low String
Reg-Set 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' $low String
foreach ($z in 0, 1, 2, 3) { Reg-Set "$cu\Internet Settings\Zones\$z" '1806' 0 }   # launching programs and unsafe files: no prompt

# ---- Fortnite FPS (why it sat at ~850 instead of 1200+: mitigations, game priority, background capture / overlay, FSO) ----
# 1. CPU security mitigations (Spectre / Meltdown) cost 3-10 % in CPU-bound games; Defender is already off on this build
Reg-Set $mm 'FeatureSettingsOverride' 3
Reg-Set $mm 'FeatureSettingsOverrideMask' 3
# 2. the game itself: high CPU + I/O priority every time it starts (Windows applies this, no tool running), no fullscreen optimisations
$ifeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in 'FortniteClient-Win64-Shipping.exe', 'FortniteClient-Win64-Shipping_EAC.exe', 'FortniteClient-Win64-Shipping_EAC_EOS.exe', 'FortniteClient-Win64-Shipping_BE.exe') {
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'CpuPriorityClass' 3
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'IoPriority' 3
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'PagePriority' 5
}
# 3. what steals CPU / GPU while playing gets the lowest priority (they only run when installed; names are unique to them)
foreach ($exe in 'EpicWebHelper.exe', 'EpicGamesLauncher.exe', 'NVIDIA App.exe', 'NVIDIA Overlay.exe', 'nvsphelper64.exe', 'ExitLag.exe') {
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'CpuPriorityClass' 1
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'IoPriority' 0
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'PagePriority' 1
}
foreach ($exe in 'Discord.exe', 'chrome.exe', 'brave.exe') {   # voice / browsers: below normal, never idle (they would crackle)
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'CpuPriorityClass' 5
  Reg-Set "$ifeoRoot\$exe\PerfOptions" 'IoPriority' 1
}
# 4. data-collection trace sessions that keep writing while you play
foreach ($t in 'AutoLogger-Diagtrack-Listener', 'DiagLog', 'SQMLogger', 'WiFiSession', 'Diagtrack-Listener') {
  $p = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$t"
  if (Test-Path $p) { Reg-Set $p 'Start' 0 }
}
# 5. Fortnite settings file: frame cap off, V-Sync off (only if the game has been started once)
$gus = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini'
if (Test-Path $gus) {
  $t = Get-Content $gus -Raw
  $t = $t -replace '(?m)^FrameRateLimit=.*$', 'FrameRateLimit=0.000000' -replace '(?m)^bUseVSync=.*$', 'bUseVSync=False'
  # graphics quality to the lowest level (only keys the file already has): shadows, effects, post-processing, foliage, view distance, textures
  foreach ($q in 'ViewDistance', 'Shadow', 'PostProcess', 'Texture', 'Effects', 'Foliage', 'Shading', 'AntiAliasing') {
    $t = $t -replace "(?m)^sg\.${q}Quality=.*$", "sg.${q}Quality=0"
  }
  if ($DryRun) { Write-Host "DRY write $gus" } else { Copy-Item $gus (Join-Path $bk 'GameUserSettings.ini') -Force; Set-Content $gus $t -NoNewline }
  Write-Host '  Fortnite: frame cap and V-Sync off, graphics quality lowest'
}
# 6. any Fortnite exe found in the Epic install list: fullscreen optimisations off, high-performance GPU
$dat = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
if (Test-Path $dat) {
  $fn = ((Get-Content $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object AppName -eq 'Fortnite').InstallLocation
  if ($fn) {
    foreach ($e in Get-ChildItem (Join-Path $fn 'FortniteGame\Binaries\Win64') -Filter 'FortniteClient-Win64-Shipping*.exe' -ErrorAction SilentlyContinue) {
      Reg-Set 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $e.FullName '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE' String
      Reg-Set 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $e.FullName 'GpuPreference=2;' String
    }
    Write-Host '  Fortnite: GPU + compatibility flags set'
  }
}

# ---- merged from ten more builds (BlitzOS, KernelOS 10 / 11, SkiiOS, FSOS, Kirby, X-Lite, Lumin, Win11Pro, Xdzl): one value per setting ----
# Rule used: a value that several builds agree on wins; when they differ, the safer of the strong ones. Network / identity / anti-cheat
# protections / DEP / process mitigations / activation were left out of every list on purpose.
$ctl = 'HKLM:\SYSTEM\CurrentControlSet\Control'
# power: no timer coalescing, no energy estimation, no sleep study, no connected standby, no power throttling of games
$pw = "$ctl\Power"
foreach ($n in 'CoalescingTimerInterval', 'CoalescingFlushInterval', 'DeepIoCoalescingEnabled', 'EnergyEstimationEnabled', 'PerfCalculateActualUtilization',
               'EventProcessorEnabled', 'ExitLatencyCheckEnabled', 'CsEnabled', 'SleepReliabilityDetailedDiagnostics') { Reg-Set $pw $n 0 }
Reg-Set $pw 'DisableVsyncLatencyUpdate' 1
Reg-Set $pw 'DisableSensorWatchdog' 1
Reg-Set "$pw\PowerThrottling" 'PowerThrottlingOff' 1
Reg-Set "$ctl\Session Manager\Power" 'SleepStudyDisabled' 1
Reg-Set "$pw\EnergyEstimation\TaggedEnergy" 'DisableTaggedEnergyLogging' 1
Reg-Set "$pw\EnergyEstimation\TaggedEnergy" 'TelemetryMaxApplication' 0
Reg-Set "$pw\EnergyEstimation\TaggedEnergy" 'TelemetryMaxTagPerApplication' 0
# kernel / scheduler
$kn = "$ctl\Session Manager\kernel"
Reg-Set $kn 'GlobalTimerResolutionRequests' 1            # a game's 0.5 ms timer request applies system-wide (FSOS)
Reg-Set $kn 'EnableWerUserReporting' 0
Reg-Set $kn 'PowerOffFrozenProcessors' 0
Reg-Set 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0       # Fault Tolerant Heap off: no hidden slowdowns for "crashed" games
# GPU: a driver reset waits 10 s instead of 2 (heavy load no longer kills the game), no VSync idle timeout
Reg-Set "$ctl\GraphicsDrivers" 'TdrDelay' 10
Reg-Set "$ctl\GraphicsDrivers\Scheduler" 'VsyncIdleTimeout' 0
# MMCSS "Games" task: the full set of keys (SkiiOS / FSOS), values already agreed with the image
$gm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
Reg-Set $gm 'Affinity' 0
Reg-Set $gm 'Background Only' 'False' String
Reg-Set $gm 'Clock Rate' 10000
Reg-Set $gm 'Latency Sensitive' 'True' String
# input: mouse and keyboard driver threads at the highest priority (SkiiOS)
foreach ($s in 'mouclass', 'kbdclass') { Reg-Set "HKLM:\SYSTEM\CurrentControlSet\Services\$s\Parameters" 'ThreadPriority' 31 }
# NVMe: no idle power states, no thermal throttling hints (FSOS + BlitzOS)
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device' 'IdlePowerMode' 0
Reg-Set 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device' 'DisableDstThrottle' 1
# shutdown / hung programs end fast
Reg-Set $ctl 'WaitToKillServiceTimeout' '2000' String
$dk = 'HKCU:\Control Panel\Desktop'
Reg-Set $dk 'AutoEndTasks' '1' String
Reg-Set $dk 'WaitToKillAppTimeout' '2000' String
Reg-Set $dk 'HungAppTimeout' '2000' String
Reg-Set 'HKCU:\Control Panel\Sound' 'Beep' 'no' String
# Game Bar programs never start (their names are unique to Game Bar)
foreach ($e in 'gamebar.exe', 'gamebarft.exe', 'GameBarFTServer.exe') { Reg-Set "$ifeoRoot\$e" 'Debugger' '%SystemRoot%\System32\taskkill.exe' String }
# DWM: no window animations / thumbnails work; web evaluation of apps off; maintenance window and malicious-software-tool offers off
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Dwm' 'DisallowAnimations' 1
Reg-Set 'HKCU:\Software\Microsoft\Windows\DWM' 'AlwaysHibernateThumbnails' 0
Reg-Set "$cu\AppHost" 'EnableWebContentEvaluation' 0
Reg-Set "$cu\AppHost" 'PreventOverride' 0
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 1
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1
foreach ($t in 'Diagtrack-Listener', 'CloudExperienceHostOobe') { $p = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$t"; if (Test-Path $p) { Reg-Set $p 'Start' 0 } }
# NTFS: no last-access writes, no 8.3 names, no encrypted paging file, MFT zone bigger (BlitzOS + KernelOS + SkiiOS)
Native fsutil.exe behavior set disablelastaccess 1
Native fsutil.exe behavior set disable8dot3 1
Native fsutil.exe behavior set encryptpagingfile 0
Native fsutil.exe behavior set memoryusage 2
Native fsutil.exe behavior set mftzone 2
# power / sleep diagnostics channels that keep logging
foreach ($ch in 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic') { Native wevtutil.exe sl $ch '/e:false' }
# ---- guard: nothing above (or an earlier tweak pack) may break Task Scheduler, Microsoft apps, NVIDIA or the network ----
Write-Host 'Guard: critical services and programs'
$stock = [ordered]@{ Schedule=2; TimeBrokerSvc=3; SystemEventsBroker=2; BrokerInfrastructure=2; EventLog=2; EventSystem=2; RpcSs=2; RpcEptMapper=2; DcomLaunch=2
  Winmgmt=2; CryptSvc=2; gpsvc=2; ProfSvc=2; UserManager=2; Appinfo=3; AppXSvc=3; ClipSVC=3; StateRepository=3; TokenBroker=3; LicenseManager=3
  InstallService=3; wlidsvc=3; StorSvc=3; Themes=2; FontCache=2; DeviceInstall=3; DsmSvc=3; DevQueryBroker=3; FrameServer=3; CoreMessagingRegistrar=2; LSM=2; SENS=2
  NlaSvc=2; netprofm=3; Netman=3; NcbService=3; Dhcp=2; Dnscache=2; nsi=2; iphlpsvc=2; mpssvc=2; BFE=2; BITS=3; Audiosrv=2; AudioEndpointBuilder=2 }
foreach ($s in $stock.Keys) {
  $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
  $cur = (Get-ItemProperty $p -ErrorAction SilentlyContinue).Start
  if ($null -ne $cur -and $cur -eq 4) {
    Reg-Set $p 'Start' $stock[$s]
    Write-Host "  $s was disabled -> $($stock[$s])"
  }
}
# programs another tweak pack renamed to .old / .exee
$w = $env:WINDIR
foreach ($f in "$w\System32\RuntimeBroker", "$w\System32\backgroundTaskHost", "$w\System32\ctfmon", "$w\System32\CompPkgSrv", "$w\System32\upfc",
               "$w\SystemApps\ShellExperienceHost_cw5n1h2txyewy\ShellExperienceHost", "$w\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost",
               "$w\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy\SearchApp", "$w\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\TextInputHost") {
  foreach ($ext in '.old', '.exee') {
    if (-not (Test-Path "$f.exe") -and (Test-Path "$f$ext") -and -not ((Test-Path $smOff) -and ($f -like '*StartMenuExperienceHost'))) { if (-not $DryRun) { Rename-Item "$f$ext" "$(Split-Path "$f.exe" -Leaf)" -ErrorAction SilentlyContinue }; Write-Host "  restored $(Split-Path "$f.exe" -Leaf)" }
  }
  if ((-not (Test-Path "$f.exe")) -and -not ((Test-Path $smOff) -and ($f -like '*StartMenuExperienceHost'))) { Write-Host "  MISSING $(Split-Path "$f.exe" -Leaf) - run JDO-Tools option 4 (or sfc /scannow)" }
}
if (-not $DryRun) { $undo | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $bk 'before.json') -Encoding UTF8; Write-Host "Backup of every changed value: $bk" }
if ($first) {
  # let the first-boot job (power plan, devices, tasks) finish before restarting: up to 4 minutes
  $fin = Join-Path $env:WINDIR 'Setup\Scripts\firstboot.finished'
  $t0 = Get-Date
  while (-not (Test-Path $fin) -and ((Get-Date) - $t0).TotalSeconds -lt 240 -and (Test-Path (Join-Path $env:WINDIR 'Setup\Scripts\firstboot.ps1'))) { Start-Sleep -Seconds 3 }
  New-Item -ItemType File $firstMark -Force | Out-Null
  # one time only: take it out of the sign-in list (the Toolbox / desktop shortcut can still run it by hand)
  Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'JDO x QHT' -ErrorAction SilentlyContinue
  New-Item -ItemType File $stopFile -Force | Out-Null
  Write-Host 'Restarting'
  Stop-Transcript | Out-Null
  & shutdown.exe /r /t 3 /c 'JDO x QHT: tweaks applied, restarting'
} elseif (-not $Quiet -and -not $DryRun) { Stop-Transcript | Out-Null }
