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
param([switch]$Quiet)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
if (-not $Quiet) { Start-Transcript (Join-Path $root 'logs\JDO-x-QHT.log') -Append | Out-Null }
$name = 'JDO x QHT'

function Reg-Set([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
  try {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
  } catch { Write-Host "  skipped $Path\$Name" }
}

# ---- name: boot menu, disk label, system page ----
Write-Host "Name: $name"
& bcdedit.exe /set '{current}' description $name | Out-Null
& bcdedit.exe /set '{bootmgr}' description $name 2>$null | Out-Null
& cmd.exe /c "label $($env:SystemDrive) $name" | Out-Null
$oem = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
Reg-Set $oem 'Manufacturer' $name String
Reg-Set $oem 'Model' $name String
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'RegisteredOwner' $name String

# ---- boot / timer latency (SharawyOS + SapphireOS; Fox has none) ----
& bcdedit.exe /set disabledynamictick yes | Out-Null      # no tick coalescing: steadier frame pacing
& bcdedit.exe /deletevalue useplatformtick 2>$null | Out-Null   # Sharawy "No" and Sapphire default disagree: Windows default wins
& bcdedit.exe /set hypervisorlaunchtype off | Out-Null    # Fox + Sharawy
& bcdedit.exe /set bootmenupolicy legacy | Out-Null       # Sapphire + Sharawy
& bcdedit.exe /set quietboot on | Out-Null
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
if (Test-Path $smi) { & $smi -acp 0 2>$null | Out-Null }                    # unrestricted clock policy (Fox + Sapphire + Sharawy)

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
Remove-Item "$cu\IrisService" -Recurse -Force -ErrorAction SilentlyContinue   # Spotlight leftovers (Sharawy)
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
  Set-Content $gus $t -NoNewline
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
    if (-not (Test-Path "$f.exe") -and (Test-Path "$f$ext")) { Rename-Item "$f$ext" "$(Split-Path "$f.exe" -Leaf)" -ErrorAction SilentlyContinue; Write-Host "  restored $(Split-Path "$f.exe" -Leaf)" }
  }
  if (-not (Test-Path "$f.exe")) { Write-Host "  MISSING $(Split-Path "$f.exe" -Leaf) - run JDO-Tools option 4 (or sfc /scannow)" }
}
if (-not $Quiet) { Stop-Transcript | Out-Null }
