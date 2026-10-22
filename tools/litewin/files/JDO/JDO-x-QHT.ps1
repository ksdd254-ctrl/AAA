# JDO x QHT - the merged tweaks of 13 gaming builds (FoxOS, SharawyOS, SapphireOS, BlitzOS, KernelOS 10 / 11, SkiiOS, FSOS,
# Kirby, X-Lite, Lumin, Win11Pro, Xdzl), de-duplicated, one best value per setting.
# Runs once by itself 5 s after the first desktop (black cover screen, then a restart). Any time again: desktop folder
# "JDO x QHT" > 2 - Tweaks, or JDO-Tools option 21. Every line it prints says what it did and whether it worked;
# every value it changes is saved first (C:\JDO\Backup) and JDO-Tools option 22 puts all of it back.
#
# Left out ON PURPOSE (they were in those builds and break things):
#   * every network setting, hostname / computer name, serials, MAC, DMA remapping (writes to network driver keys too)
#   * renaming Windows programs (RuntimeBroker, SearchApp, ShellExperienceHost, TextInputHost, ctfmon...) and disabling
#     TokenBroker, DevQueryBroker, FontCache, Themes, FrameServer, Task Scheduler... (Store, NVIDIA App and sign-in need them)
#   * DEP / process-mitigation changes and the vulnerable-driver blocklist (anti-cheats need them), activation scripts
#   * NVIDIA telemetry switches and low priority for NVIDIA programs: with them the NVIDIA App stops with "There was a
#     problem with NVIDIA App" (its plugins time out asking the telemetry service for the user id - seen in its logs)
param([switch]$Auto, [switch]$Quiet, [switch]$DryRun, [switch]$Force)   # -Auto: started at sign-in   -DryRun: print only, change nothing
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Only the JDO x QHT Windows is tweaked. On any other Windows (the one you use now, for example) this file stops here and
# changes nothing - unless you start it with -Force on purpose. (The image marks itself with C:\Windows\Setup\Scripts\firstboot.ps1.)
if (-not $DryRun -and -not $Force -and -not (Test-Path (Join-Path $env:WINDIR 'Setup\Scripts\firstboot.ps1'))) {
  Write-Host ''
  Write-Host '  This is NOT the JDO x QHT Windows - nothing was changed.' -ForegroundColor Yellow
  Write-Host '  These tweaks are made for the new Windows only. Install it from the ISO, they run there by themselves.' -ForegroundColor Gray
  Write-Host '  (To force it on this Windows anyway: run the file with -Force. Every change would be backed up first.)' -ForegroundColor DarkGray
  if (-not $Auto) { Read-Host '  Press Enter to close' | Out-Null }
  return
}
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $DryRun -and -not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  if ($Auto) { $a += ' -Auto' }
  # the first automatic run is shown on the black cover screen; a run by hand keeps its window open with every line
  Start-Process powershell.exe -Verb RunAs -WindowStyle $(if ($Auto) { 'Hidden' } else { 'Normal' }) -ArgumentList $a
  return
}
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$live = Join-Path $logs 'qht-live.txt'                 # what the cover screen shows
if (-not $DryRun) { Set-Content $live '' -Encoding UTF8; Start-Transcript (Join-Path $logs 'JDO-x-QHT.log') -Append | Out-Null }
try { $Host.UI.RawUI.WindowTitle = 'JDO x QHT - tweaks'; $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
$name = 'JDO x QHT'
$script:ok = 0; $script:same = 0; $script:bad = New-Object System.Collections.Generic.List[string]

function Say([string]$Text, [string]$Color = 'Gray') {
  Write-Host $Text -ForegroundColor $Color
  if (-not $DryRun) { Add-Content $live $Text -Encoding UTF8 -ErrorAction SilentlyContinue }
}
function Section([string]$Title, [string]$Why) { Say ''; Say "== $Title" 'Magenta'; if ($Why) { Say "   $Why" 'DarkGray' } }
function Done-Line([string]$What) { $script:ok++; Say "  [OK]   $What" 'Green' }
function Same-Line([string]$What) { $script:same++; Say "  [=]    $What (already set)" 'DarkGray' }
function Fail-Line([string]$What, [string]$Fix) { $script:bad.Add("$What -> $Fix"); Say "  [FAIL] $What" 'Red'; Say "         fix: $Fix" 'Yellow' }

# ---- backup of every value before it changes (JDO-Tools option 22 undoes from here) ----
$bk = Join-Path $root ('Backup\QHT-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$undo = New-Object System.Collections.Generic.List[object]
$seen = @{}
if (-not $DryRun) { New-Item -ItemType Directory -Force $bk | Out-Null; & bcdedit.exe /export (Join-Path $bk 'bcd.bak') 2>$null | Out-Null }

# a command line tool (bcdedit, fsutil, powercfg, wevtutil): prints the result and its error text if it fails
function Native([string]$What, [string]$Exe) {
  $a = @($args)
  if ($DryRun) { Say "  DRY    $What  ($Exe $($a -join ' '))"; return }
  $out = & $Exe @a 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) { Done-Line $What } else { Fail-Line "$What  ($(($out -split "`n")[0].Trim()))" 'restart and run it again; if it keeps failing, JDO-Tools option 20' }
}
# a registry value: prints [OK] new value (old value), [=] if it already was that, [FAIL] with the fix
function Reg-Set([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$What) {
  $label = if ($What) { $What } else { "$(Split-Path $Path -Leaf)\$Name = $Value" }
  if ($DryRun) { Say "  DRY    $label"; return }
  $old = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  $had = ($null -ne $old) -and ($null -ne $old.$Name)
  if ($had -and "$($old.$Name)" -eq "$Value") { Same-Line $label; return }
  $key = "$Path|$Name"
  if (-not $seen.ContainsKey($key)) {
    $seen[$key] = $true
    $kind = if ($had) { (Get-Item $Path).GetValueKind($Name).ToString() } else { $Type }
    $undo.Add([pscustomobject]@{ Path = $Path; Name = $Name; Existed = $had; Kind = $kind; Value = $(if ($had) { $old.$Name } else { $null }) })
  }
  try {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    Done-Line ($label + $(if ($had) { "   (was $($old.$Name))" } else { '' }))
  } catch {
    $m = $_.Exception.Message
    $fix = if ($m -match 'volatile') { 'Windows recreates this key at every sign-in - nothing to do' }
           elseif ($m -match 'denied|unauthorized') { 'protected key: JDO-Tools option 20 sets it with the restore privilege' }
           else { 'run 2 - Tweaks again after a restart' }
    Fail-Line "$label  ($m)" $fix
  }
}
# a service value only when the service (driver) is really installed - never creates a half service key
function Svc-Set([string]$Svc, [string]$Sub, [string]$Name, $Value, [string]$What) {
  $base = "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc"
  if (-not (Get-ItemProperty $base -Name ImagePath -ErrorAction SilentlyContinue)) { Say "  [-]    $What (not installed yet - runs again once it is)" 'DarkGray'; return }
  Reg-Set ($(if ($Sub) { "$base\$Sub" } else { $base })) $Name $Value 'DWord' $What
}

$script:watch = [Diagnostics.Stopwatch]::StartNew()
Say "JDO x QHT - applying the tweaks   $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 'Magenta'
Say "Backup of every value it changes: $bk" 'DarkGray'

# ---- first automatic run: black cover screen with this log on it, restart at the end ----
$firstMark = Join-Path $root 'qht.done'
$first = $Auto -and (-not $DryRun) -and (-not (Test-Path $firstMark))
$stopFile = Join-Path $root 'screen.stop'
if (-not $DryRun) { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue }
if ($first) { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$(Join-Path $root 'JDO-Screen.ps1')`"" }
if ($Auto -and -not $first) { Say 'Already applied once - this sign-in only checks the guard below.' 'DarkGray' }

# ---- Start menu: Open-Shell (one small process) instead of the Microsoft one ----
Section 'Start menu' 'Open-Shell: classic Start menu with its own search box, one small process. The old menu is switched off (option 22 brings it back).'
$osSetup = Join-Path $root 'Apps\OpenShellSetup.exe'
$osExe = "$env:ProgramFiles\Open-Shell\StartMenu.exe"
if (Test-Path $osExe) { Same-Line 'Open-Shell installed' }
elseif ($DryRun) { Say '  DRY    install Open-Shell' }
elseif (Test-Path $osSetup) {
  $p = Start-Process $osSetup -ArgumentList '/qn', 'ADDLOCAL=StartMenu' -PassThru
  if ($p.WaitForExit(180000) -and (Test-Path $osExe)) { Done-Line 'Open-Shell installed' } else { Fail-Line 'Open-Shell install' 'run C:\JDO\Apps\OpenShellSetup.exe by hand' }
} else { Fail-Line 'Open-Shell installer missing (C:\JDO\Apps\OpenShellSetup.exe)' 'copy it from the ISO folder JDO\Apps' }
if (Test-Path $osExe) {
  # light settings: no animation / fading, Windows key opens Open-Shell, no "recent" lists to track
  $osk = 'HKCU:\Software\OpenShell\StartMenu\Settings'
  Reg-Set $osk 'MenuStyle' 'Win7' String 'Open-Shell style: Windows 7 (lightest)'
  Reg-Set $osk 'MainMenuAnimation' 'None' String 'Open-Shell: no open animation'
  Reg-Set $osk 'SubMenuAnimation' 'None' String 'Open-Shell: no sub-menu animation'
  Reg-Set $osk 'WinKey' 'ClassicMenu' String 'Windows key opens Open-Shell'
  Reg-Set $osk 'RecentPrograms' 'None' String 'Open-Shell: no recent-programs list'
  Reg-Set $osk 'SkinW7' 'Midnight' String 'Open-Shell skin: Midnight (black / dark gray, no red accent)'
  Reg-Set $osk 'SkinC1' 'Midnight' String 'Open-Shell skin (classic style): Midnight'
  Reg-Set $osk 'SkinC2' 'Midnight' String 'Open-Shell skin (two-column style): Midnight'
  }
$smOff = Join-Path $root 'startmenu.off'
$smExe = "$env:WINDIR\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe"
if (Test-Path $smOff) { Same-Line 'old Microsoft Start menu off' }
elseif ($DryRun) { Say '  DRY    switch off the old Start menu' }
elseif ((Test-Path $osExe) -and (Test-Path $smExe)) {
  & takeown.exe /f $smExe 2>$null | Out-Null
  & icacls.exe $smExe /grant '*S-1-5-32-544:F' 2>$null | Out-Null
  Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
  Rename-Item $smExe 'StartMenuExperienceHost.exe.qht-off' -ErrorAction SilentlyContinue
  if (Test-Path "$smExe.qht-off") { New-Item -ItemType File $smOff -Force | Out-Null; Done-Line 'old Microsoft Start menu off (one process less)' }
  else { Fail-Line 'old Start menu could not be switched off' 'sign out and in, then run 2 - Tweaks again' }
}

# ---- name ----
Section 'Name' 'JDO x QHT in the boot menu, on the C: drive and in System > About.'
Native 'boot menu name' bcdedit.exe /set '{current}' description $name
Native 'C: drive name' cmd.exe /c "label $($env:SystemDrive) $name"
$oem = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
Reg-Set $oem 'Manufacturer' $name String 'System > About: maker'
Reg-Set $oem 'Model' $name String 'System > About: model'
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'RegisteredOwner' $name String 'registered owner'

# ---- dark everywhere ----
Section 'Dark mode' 'Windows and apps dark, no transparency.'
$cu = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
Reg-Set "$cu\Themes\Personalize" 'AppsUseLightTheme' 0 DWord 'apps: dark'
Reg-Set "$cu\Themes\Personalize" 'SystemUsesLightTheme' 0 DWord 'taskbar / Start / system: dark'
Reg-Set "$cu\Themes\Personalize" 'EnableTransparency' 0 DWord 'transparency off'
Reg-Set "$cu\Themes\Personalize" 'ColorPrevalence' 0 DWord 'no accent colour on the taskbar (stays black)'

# ---- mouse, keyboard (Control Panel) ----
Section 'Mouse and keyboard' 'Your own settings: pointer speed 7 of 11 (value 12), no acceleration, fast double-click, fastest key repeat, shortest repeat delay.'
Reg-Set 'HKCU:\Control Panel\Mouse' 'MouseSensitivity' '12' String 'pointer speed: 7 of 11 (as on your PC)'
Reg-Set 'HKCU:\Control Panel\Mouse' 'DoubleClickSpeed' '200' String 'double-click speed: fast (200 ms)'
Reg-Set 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' String 'enhance pointer precision: off'
Reg-Set 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' String 'acceleration threshold 1: off'
Reg-Set 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' String 'acceleration threshold 2: off'
Reg-Set 'HKCU:\Control Panel\Mouse' 'MouseHoverTime' '10' String 'hover delay: 10 ms'
Reg-Set 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' String 'key repeat rate: fastest'
Reg-Set 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' String 'key repeat delay: shortest'
Reg-Set 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' String 'menus open at once'

# ---- power plan: only JDO Ultimate stays ----
Section 'Power plan' 'JDO Ultimate (full speed, real CPU usage) is the only plan - every other plan is deleted.'
$jdo = '4a444f00-0000-4000-8000-00000000c0de'
if ($DryRun) { Say '  DRY    JDO Ultimate active, other plans deleted' }
else {
  if (-not (powercfg /list | Select-String $jdo)) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'JDO-Tools.ps1') -Power | Out-Null }
  & powercfg /setactive $jdo 2>$null | Out-Null
  if ((powercfg /getactivescheme) -match $jdo) { Done-Line 'JDO Ultimate is the active plan' } else { Fail-Line 'JDO Ultimate not active' 'JDO-Tools option 17' }
  foreach ($l in powercfg /list) {
    if ($l -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s+\((.+?)\)') {
      $g = $Matches[1]; $n = $Matches[2]
      if ($g -eq $jdo) { continue }
      & powercfg /delete $g 2>$null | Out-Null
      if (-not (powercfg /list | Select-String $g)) { Done-Line "power plan deleted: $n" } else { Fail-Line "power plan kept: $n" 'Control Panel > Power Options, delete it there' }
    }
  }
}

# ---- boot / timers ----
Section 'Boot and timers' 'Agreed by most of the 13 builds: no tick coalescing, no hypervisor, classic boot menu (3 s), no boot animation.'
Native 'no tick coalescing (steadier frame pacing)' bcdedit.exe /set disabledynamictick yes
& bcdedit.exe /deletevalue useplatformtick 2>$null | Out-Null   # builds disagree (yes / no): Windows default
Native 'hypervisor off' bcdedit.exe /set hypervisorlaunchtype off
Native 'classic boot menu' bcdedit.exe /set bootmenupolicy legacy
Native 'boot menu waits 3 s' bcdedit.exe /timeout 3
Native 'no boot animation' bcdedit.exe /set bootux disabled
Native 'quiet boot' bcdedit.exe /set quietboot on
$ctl = 'HKLM:\SYSTEM\CurrentControlSet\Control'
$kn = "$ctl\Session Manager\kernel"
Reg-Set $kn 'SerializeTimerExpiration' 2 DWord 'timers expire on each core (no serialisation)'
Reg-Set $kn 'GlobalTimerResolutionRequests' 1 DWord "the game's 0.5 ms timer applies system-wide"
Reg-Set $kn 'EnableWerUserReporting' 0 DWord 'kernel error reports off'
Reg-Set $kn 'PowerOffFrozenProcessors' 0 DWord 'frozen-processor power-off off'
Reg-Set "$ctl\PriorityControl" 'Win32PrioritySeparation' 0x26 DWord 'foreground program gets 3x the CPU time (0x26)'

# ---- memory ----
Section 'Memory' 'Kernel and drivers stay in RAM, no page combining, no prefetch / superfetch, CPU mitigations off (3-10 % in CPU-bound games).'
$mm = "$ctl\Session Manager\Memory Management"
Reg-Set $mm 'DisablePagingExecutive' 1 DWord 'kernel / drivers never paged out'
Reg-Set $mm 'DisablePagingCombining' 1 DWord 'no page combining'
Reg-Set "$mm\PrefetchParameters" 'EnablePrefetcher' 0 DWord 'prefetch off'
Reg-Set "$mm\PrefetchParameters" 'EnableSuperfetch' 0 DWord 'superfetch off'
Reg-Set $mm 'FeatureSettingsOverride' 3 DWord 'Spectre / Meltdown mitigations off'
Reg-Set $mm 'FeatureSettingsOverrideMask' 3 DWord 'Spectre / Meltdown mask'
Reg-Set 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0 DWord 'Fault Tolerant Heap off (no hidden slow mode for games)'
Reg-Set "$ctl\DeviceGuard" 'EnableVirtualizationBasedSecurity' 0 DWord 'VBS off'
Reg-Set "$ctl\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" 'Enabled' 0 DWord 'memory integrity (HVCI) off'
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0 DWord 'VBS policy off'
Reg-Set "$ctl\Lsa" 'LsaCfgFlags' 0 DWord 'Credential Guard off'

# ---- power settings that add latency ----
Section 'Power latency' 'No timer / IO coalescing, no energy estimation, no sleep study, no connected standby, no power throttling of games.'
$pw = "$ctl\Power"
foreach ($n in 'CoalescingTimerInterval', 'CoalescingFlushInterval', 'DeepIoCoalescingEnabled', 'EnergyEstimationEnabled', 'PerfCalculateActualUtilization',
               'EventProcessorEnabled', 'ExitLatencyCheckEnabled', 'CsEnabled', 'SleepReliabilityDetailedDiagnostics') { Reg-Set $pw $n 0 DWord "power: $n off" }
Reg-Set $pw 'DisableVsyncLatencyUpdate' 1 DWord 'power: no VSync latency updates'
Reg-Set $pw 'DisableSensorWatchdog' 1 DWord 'power: no sensor watchdog'
Reg-Set "$pw\PowerThrottling" 'PowerThrottlingOff' 1 DWord 'power throttling off'
Reg-Set "$ctl\Session Manager\Power" 'SleepStudyDisabled' 1 DWord 'sleep study off'
Reg-Set "$ctl\Session Manager\Power" 'HiberbootEnabled' 0 DWord 'fast startup off (clean boot every time)'
Native 'hibernation off (no hiberfil.sys)' powercfg.exe /hibernate off

# ---- GPU ----
Section 'Graphics' 'Driver reset waits 10 s (heavy load no longer kills the game), MPO off, no VSync idle timeout. NVIDIA: always full clock (P0).'
Reg-Set "$ctl\GraphicsDrivers" 'TdrDelay' 10 DWord 'GPU reset timeout 10 s'
Reg-Set "$ctl\GraphicsDrivers\Scheduler" 'VsyncIdleTimeout' 0 DWord 'no VSync idle timeout'
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5 DWord 'MPO off (no overlay flicker / frame spikes)'
$nv = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' -and $_.Name -match 'NVIDIA' })
if ($nv) {
  foreach ($g in $nv) {
    $drv = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.PNPDeviceID)" -ErrorAction SilentlyContinue).Driver
    if ($drv) { Reg-Set "$ctl\Class\$drv" 'DisableDynamicPstate' 1 DWord "$($g.Name): always P0 (full clock)" }
  }
  $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
  if (Test-Path $smi) { Native 'NVIDIA unrestricted clock policy' $smi '-acp' '0' }
} else { Say '  [-]    NVIDIA driver not installed yet - these run again by themselves after it is (or 2 - Tweaks)' 'DarkGray' }
# undo of the earlier NVIDIA telemetry switches (they broke the NVIDIA App)
foreach ($x in @(@('HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup', 'SendTelemetryData'), @('HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client', 'OptInOrOutPreference'),
                 @('HKCU:\Software\NVIDIA Corporation\NvControlPanel2\Client', 'OptInOrOutPreference'), @('HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS', 'EnableRID44231'),
                 @('HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS', 'EnableRID64640'), @('HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS', 'EnableRID66610'))) {
  if ((Get-ItemProperty $x[0] -Name $x[1] -ErrorAction SilentlyContinue).($x[1]) -eq 0 -and -not $DryRun) { Remove-ItemProperty $x[0] -Name $x[1] -ErrorAction SilentlyContinue; Done-Line "NVIDIA App fix: $($x[1]) back to default" }
}

# ---- game and app priorities ----
Section 'Priorities' 'Fortnite: high CPU / disk priority every time it starts. Launchers, browsers, Discord: below normal (never idle - they would stutter).'
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in 'FortniteClient-Win64-Shipping.exe', 'FortniteClient-Win64-Shipping_EAC.exe', 'FortniteClient-Win64-Shipping_EAC_EOS.exe', 'FortniteClient-Win64-Shipping_BE.exe') {
  Reg-Set "$ifeo\$exe\PerfOptions" 'CpuPriorityClass' 3 DWord "$exe CPU: high"
  Reg-Set "$ifeo\$exe\PerfOptions" 'IoPriority' 3 DWord "$exe disk: high"
}
foreach ($exe in 'EpicGamesLauncher.exe', 'EpicWebHelper.exe', 'ExitLag.exe', 'Discord.exe', 'chrome.exe', 'brave.exe') {
  Reg-Set "$ifeo\$exe\PerfOptions" 'CpuPriorityClass' 5 DWord "$exe CPU: below normal"
  Reg-Set "$ifeo\$exe\PerfOptions" 'IoPriority' 1 DWord "$exe disk: low"
}
# NVIDIA programs keep normal priority (the NVIDIA App fails to start at idle priority)
foreach ($exe in 'NVIDIA App.exe', 'NVIDIA Overlay.exe', 'nvsphelper64.exe') {
  if ((Test-Path "$ifeo\$exe\PerfOptions") -and -not $DryRun) { Remove-Item "$ifeo\$exe\PerfOptions" -Recurse -Force; Done-Line "NVIDIA App fix: $exe back to normal priority" }
}
foreach ($e in 'gamebar.exe', 'gamebarft.exe', 'GameBarFTServer.exe') { Reg-Set "$ifeo\$e" 'Debugger' '%SystemRoot%\System32\taskkill.exe' String "Game Bar never starts ($e)" }
$gm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
Reg-Set $gm 'GPU Priority' 8 DWord 'MMCSS games: GPU priority 8'
Reg-Set $gm 'Priority' 6 DWord 'MMCSS games: priority 6'
Reg-Set $gm 'Scheduling Category' 'High' String 'MMCSS games: scheduling high'
Reg-Set $gm 'SFIO Priority' 'High' String 'MMCSS games: disk high'
Reg-Set $gm 'Latency Sensitive' 'True' String 'MMCSS games: latency sensitive'
Reg-Set $gm 'Clock Rate' 10000 DWord 'MMCSS games: 1 ms clock'
Reg-Set $gm 'Affinity' 0 DWord 'MMCSS games: all cores'
Reg-Set $gm 'Background Only' 'False' String 'MMCSS games: foreground'
# Fortnite's own settings file (after the game ran once): no frame cap, no V-Sync, lowest graphics
$gus = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini'
if (Test-Path $gus) {
  $t = Get-Content $gus -Raw
  $t = $t -replace '(?m)^FrameRateLimit=.*$', 'FrameRateLimit=0.000000' -replace '(?m)^bUseVSync=.*$', 'bUseVSync=False'
  foreach ($q in 'ViewDistance', 'Shadow', 'PostProcess', 'Texture', 'Effects', 'Foliage', 'Shading', 'AntiAliasing') { $t = $t -replace "(?m)^sg\.${q}Quality=.*$", "sg.${q}Quality=0" }
  if ($DryRun) { Say '  DRY    Fortnite settings file' } else { Copy-Item $gus (Join-Path $bk 'GameUserSettings.ini') -Force; Set-Content $gus $t -NoNewline; Done-Line 'Fortnite: no frame cap, no V-Sync, lowest graphics (copy of the old file in the backup)' }
} else { Say '  [-]    Fortnite settings file not there yet (start the game once, then 2 - Tweaks)' 'DarkGray' }
$dat = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
if (Test-Path $dat) {
  $fn = ((Get-Content $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object AppName -eq 'Fortnite').InstallLocation
  if ($fn) { foreach ($e in Get-ChildItem (Join-Path $fn 'FortniteGame\Binaries\Win64') -Filter 'FortniteClient-Win64-Shipping*.exe' -ErrorAction SilentlyContinue) {
    Reg-Set 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' $e.FullName '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE' String "$($e.Name): fullscreen optimisations off"
    Reg-Set 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $e.FullName 'GpuPreference=2;' String "$($e.Name): high-performance GPU"
  } }
}

# ---- input, disk ----
Section 'Input and disk' 'Mouse / keyboard driver threads at top priority, USB power saving off, NVMe never idles, NTFS without last-access / 8.3 writes.'
Svc-Set 'mouclass' 'Parameters' 'ThreadPriority' 31 'mouse driver thread: top priority'
Svc-Set 'kbdclass' 'Parameters' 'ThreadPriority' 31 'keyboard driver thread: top priority'
Svc-Set 'stornvme' 'Parameters\Device' 'IdlePowerMode' 0 'NVMe: no idle power states'
Svc-Set 'stornvme' 'Parameters\Device' 'DisableDstThrottle' 1 'NVMe: no thermal throttling hints'
$net = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | ForEach-Object { $_.InstanceId.ToUpper() })
$usbN = 0
foreach ($dev in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB', 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue | Get-ChildItem -ErrorAction SilentlyContinue) {
  if ($net -contains ($dev.Name -replace '^.*\\Enum\\', '').ToUpper()) { continue }   # network adapters: never
  $p = Join-Path $dev.PSPath 'Device Parameters'
  if (-not (Test-Path $p) -or $DryRun) { continue }
  foreach ($v in 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'SelectiveSuspendEnabled', 'DeviceSelectiveSuspended') {
    if ((Get-ItemProperty $p -Name $v -ErrorAction SilentlyContinue).$v -ne 0) { Set-ItemProperty -Path $p -Name $v -Value 0 -Type DWord -ErrorAction SilentlyContinue; $usbN++ }
  }
}
if ($usbN) { Done-Line "USB / HID power saving off ($usbN values)" } else { Same-Line 'USB / HID power saving off' }
Native 'NTFS: no last-access writes' fsutil.exe behavior set disablelastaccess 1
Native 'NTFS: no 8.3 short names' fsutil.exe behavior set disable8dot3 1
Native 'paging file not encrypted' fsutil.exe behavior set encryptpagingfile 0
Native 'NTFS: more memory for file caching' fsutil.exe behavior set memoryusage 2
Native 'NTFS: bigger MFT zone' fsutil.exe behavior set mftzone 2

# ---- background, privacy ----
Section 'Background and privacy' 'Trace sessions, maintenance, phone link, web search, toasts, animations off. Microphone and camera stay allowed.'
foreach ($t in 'AutoLogger-Diagtrack-Listener', 'Diagtrack-Listener', 'DiagLog', 'SQMLogger', 'WiFiSession', 'CloudExperienceHostOobe') {
  $p = "$ctl\WMI\Autologger\$t"; if (Test-Path $p) { Reg-Set $p 'Start' 0 DWord "trace session off: $t" }
}
foreach ($ch in 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic') { Native "log off: $ch" wevtutil.exe sl $ch '/e:false' }
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1 DWord 'automatic maintenance off'
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 1 DWord 'no malicious-software-tool downloads'
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
Reg-Set "$pol\LocationAndSensors" 'DisableWindowsLocationProvider' 1 DWord 'location provider off'
Reg-Set "$pol\System" 'EnableMmx' 0 DWord 'phone link off'
Reg-Set "$pol\Windows Search" 'AllowCloudSearch' 0 DWord 'cloud search off'
Reg-Set "$pol\Windows Search" 'DoNotUseWebResults' 1 DWord 'no web results in search'
Reg-Set "$pol\Dwm" 'DisallowAnimations' 1 DWord 'window animations off'
Reg-Set "$cu\Mobility" 'CrossDeviceEnabled' 0 DWord 'cross-device off'
Reg-Set "$cu\ContentDeliveryManager" 'SubscribedContentEnabled' 0 DWord 'suggested content off'
Reg-Set "$cu\AppHost" 'EnableWebContentEvaluation' 0 DWord 'app web check off'
Reg-Set "$cu\Explorer" 'AltTabSettings' 1 DWord 'classic Alt-Tab'
Reg-Set 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' '1' String 'hung programs close by themselves'
Reg-Set 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' '2000' String 'programs get 2 s to close at shutdown'
Reg-Set 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' '2000' String 'a program is "not responding" after 2 s'
Reg-Set $ctl 'WaitToKillServiceTimeout' '2000' String 'services get 2 s to stop at shutdown'
Reg-Set 'HKCU:\Control Panel\Sound' 'Beep' 'no' String 'no system beep'
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1 DWord 'no "Run / Cancel" warning for downloaded files'
Reg-Set "$cu\Policies\Attachments" 'SaveZoneInformation' 1 DWord 'no "Run / Cancel" warning (this account)'
Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' '.exe;.bat;.cmd;.com;.msi;.ps1;.vbs;.reg;.lnk;.jar' String 'programs and scripts open without a warning'

# ---- updates and Delivery Optimization off ----
Section 'Windows Update' 'Update orchestrator, update medic and Delivery Optimization off. The Microsoft Store still installs and updates apps.'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class QhtSvc {
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string s, string n, out long l);
  [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TP { public int C; public long L; public int A; }
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TP s, int l, IntPtr p, IntPtr r);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyEx(UIntPtr k, string s, int r, string c, int o, int sam, IntPtr sec, out UIntPtr h, out int d);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegSetValueEx(UIntPtr k, string n, int r, int t, byte[] d, int s);
  [DllImport("advapi32.dll")] static extern int RegCloseKey(UIntPtr k);
  public static int SetStart(string svc, uint v) {
    IntPtr t; OpenProcessToken(GetCurrentProcess(), 0x28, out t);
    TP tp = new TP(); tp.C = 1; tp.A = 2; LookupPrivilegeValue(null, "SeRestorePrivilege", out tp.L); AdjustTokenPrivileges(t, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    UIntPtr h; int d; string sub = @"SYSTEM\CurrentControlSet\Services\" + svc;
    int rc = RegCreateKeyEx(new UIntPtr(0x80000002u), sub, 0, null, 0, 0x20006, IntPtr.Zero, out h, out d);
    if (rc == 5) rc = RegCreateKeyEx(new UIntPtr(0x80000002u), sub, 0, null, 4, 0, IntPtr.Zero, out h, out d);
    if (rc != 0) return rc;
    rc = RegSetValueEx(h, "Start", 0, 4, BitConverter.GetBytes(v), 4); RegCloseKey(h); return rc;
  }
}
'@ -ErrorAction SilentlyContinue
foreach ($s in @(@('UsoSvc', 4, 'Update Orchestrator (MoUSO worker) off'), @('WaaSMedicSvc', 4, 'Windows Update Medic off'), @('DoSvc', 4, 'Delivery Optimization off'),
                 @('TrustedInstaller', 3, 'Windows Modules Installer only on demand (no TiWorker at idle)'), @('wuauserv', 3, 'Windows Update service on demand (the Store needs it)'),
                 @('uhssvc', 4, 'Microsoft Update Health Service off'),
                 @('NgcSvc', 4, 'PIN / Windows Hello service off'), @('NgcCtnrSvc', 4, 'PIN / Windows Hello container off'),
                 @('sppsvc', 3, 'activation service on demand (one process less)'),
                 @('GameInputSvc', 4, 'GameInput service off (Epic installs it; Fortnite and controllers do not need it - 2 processes less)'))) {
  $cur = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($s[0])" -ErrorAction SilentlyContinue).Start
  if ($null -eq $cur) { continue }
  if ($cur -eq $s[1]) { Same-Line $s[2]; continue }
  if ($DryRun) { Say "  DRY    $($s[2])"; continue }
  $undo.Add([pscustomobject]@{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s[0])"; Name = 'Start'; Existed = $true; Kind = 'DWord'; Value = $cur })
  $rc = [QhtSvc]::SetStart($s[0], [uint32]$s[1])
  if ($rc -eq 0) { Done-Line "$($s[2])   (was $cur)" } else { Fail-Line "$($s[2]) (error $rc)" 'JDO-Tools option 20, then 2 - Tweaks' }
}
# "Microsoft Update Health Tools" (KB4023057 / KB5001716): Windows Update installs it by itself and it brings update processes back
foreach ($u in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue) {
  $dn = (Get-ItemProperty $u.PSPath -ErrorAction SilentlyContinue).DisplayName
  if ($dn -match 'Update Health Tools|Windows Setup Remediations') {
    if ($DryRun) { Say "  DRY    uninstall $dn"; continue }
    $p = Start-Process msiexec.exe -ArgumentList "/x $($u.PSChildName) /qn /norestart" -PassThru
    if ($p.WaitForExit(120000) -and $p.ExitCode -in 0, 1605, 3010) { Done-Line "uninstalled: $dn" } else { Fail-Line "uninstall $dn" 'Settings > Apps, uninstall it there' }
  }
}
foreach ($f in '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\WaaSMedic\', '\Microsoft\Windows\Servicing\', '\Microsoft\Windows\LanguageComponentsInstaller\', '\Microsoft\Windows\rempl\') {
  $tasks = @(Get-ScheduledTask -TaskPath $f -ErrorAction SilentlyContinue | Where-Object State -ne 'Disabled')
  if ($DryRun) { Say "  DRY    tasks off: $f"; continue }
  if (-not $tasks) { Same-Line "tasks off: $f"; continue }
  $n = @($tasks | Disable-ScheduledTask -ErrorAction SilentlyContinue).Count
  if ($n -eq $tasks.Count) { Done-Line "tasks off: $f ($n)" } else { Say "  [~]    tasks off: $f ($n of $($tasks.Count) - the rest are protected by Windows, they stay idle)" 'DarkYellow' }
}

# ---- PIN: no PIN sign-in, no "set up a PIN" nag, any saved PIN deleted ----
Section 'PIN' 'The account has no password and signs in by itself: PIN / Windows Hello is switched off and its saved data deleted.'
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowDomainPINLogon' 0 DWord 'PIN sign-in off'
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork' 'Enabled' 0 DWord 'Windows Hello for Business off'
Reg-Set 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork' 'DisablePostLogonProvisioning' 1 DWord 'no PIN setup after sign-in'
$ngc = "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
if (Test-Path $ngc) {
  if ($DryRun) { Say '  DRY    delete saved PIN data' }
  else { & takeown.exe /f $ngc /r /d y 2>$null | Out-Null; & icacls.exe $ngc /grant '*S-1-5-32-544:F' /t /c /q 2>$null | Out-Null
         Remove-Item $ngc -Recurse -Force -ErrorAction SilentlyContinue
         if (-not (Get-ChildItem $ngc -Force -ErrorAction SilentlyContinue)) { Done-Line 'saved PIN data deleted' } else { Fail-Line 'PIN data (Ngc folder) not fully deleted' 'Settings > Accounts > Sign-in options > PIN > Remove' } }
} else { Same-Line 'no saved PIN' }

# ---- guard: nothing (this file, another tweak pack, EXM...) may break Task Scheduler, Microsoft apps, NVIDIA or the network ----
Section 'Guard' 'Services that Task Scheduler, the Store, the NVIDIA App, sign-in and the network need - put back if something disabled them.'
$stock = [ordered]@{ Schedule=2; TimeBrokerSvc=3; SystemEventsBroker=2; BrokerInfrastructure=2; EventLog=2; EventSystem=2; RpcSs=2; RpcEptMapper=2; DcomLaunch=2
  Winmgmt=2; CryptSvc=2; gpsvc=2; ProfSvc=2; UserManager=2; Appinfo=3; AppXSvc=3; ClipSVC=3; StateRepository=3; TokenBroker=3; LicenseManager=3
  InstallService=3; wlidsvc=3; StorSvc=3; Themes=2; FontCache=2; DeviceInstall=3; DsmSvc=3; DevQueryBroker=3; FrameServer=3; CoreMessagingRegistrar=2; LSM=2; SENS=2
  NlaSvc=2; netprofm=3; Netman=3; NcbService=3; Dhcp=2; Dnscache=2; nsi=2; iphlpsvc=2; mpssvc=2; BFE=2; BITS=3; Audiosrv=2; AudioEndpointBuilder=2 }
$fixed = 0
foreach ($s in $stock.Keys) {
  $cur = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -ErrorAction SilentlyContinue).Start
  if ($cur -eq 4) { $fixed++; if (-not $DryRun) { [void][QhtSvc]::SetStart($s, [uint32]$stock[$s]) }; Done-Line "$s was disabled -> back on" }
}
if (-not $fixed) { Same-Line "all $($stock.Count) critical services are on" }
$w = $env:WINDIR
foreach ($f in "$w\System32\RuntimeBroker", "$w\System32\backgroundTaskHost", "$w\System32\ctfmon", "$w\System32\CompPkgSrv", "$w\System32\upfc",
               "$w\SystemApps\ShellExperienceHost_cw5n1h2txyewy\ShellExperienceHost", "$w\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy\SearchApp",
               "$w\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\TextInputHost") {
  foreach ($ext in '.old', '.exee') {
    if (-not (Test-Path "$f.exe") -and (Test-Path "$f$ext") -and -not $DryRun) { Rename-Item "$f$ext" "$(Split-Path "$f.exe" -Leaf)" -ErrorAction SilentlyContinue; Done-Line "restored $(Split-Path "$f.exe" -Leaf)" }
  }
  if (-not (Test-Path "$f.exe")) { Fail-Line "missing $(Split-Path "$f.exe" -Leaf)" 'JDO-Tools option 4, or sfc /scannow' }
}

# ---- after the first restart: apps (Brave, AnyDesk), taskbar pins, Store update ----
if ($first) { Reg-Set 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'JDO x QHT apps' 'cmd.exe /c start "" C:\JDO\JDO-PostSetup.cmd' String 'after the restart: Brave, AnyDesk, taskbar pins, Store update' }

# ---- result ----
if (-not $DryRun) { $undo | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $bk 'before.json') -Encoding UTF8 }
Say ''
Say ("== Result: {0} changed, {1} already right, {2} failed" -f $script:ok, $script:same, $script:bad.Count) $(if ($script:bad.Count) { 'Yellow' } else { 'Green' })
foreach ($b in $script:bad) { Say "   $b" 'Yellow' }
Say "   Full log: $logs\JDO-x-QHT.log    Undo everything: JDO-Tools option 22" 'DarkGray'
if ($first) {
  # the first-boot job (power plan, devices, tasks) must finish before the restart: up to 100 seconds
  $fin = Join-Path $env:WINDIR 'Setup\Scripts\firstboot.finished'
  $t0 = Get-Date
  while (-not (Test-Path $fin) -and ((Get-Date) - $t0).TotalSeconds -lt 100 -and (Test-Path (Join-Path $env:WINDIR 'Setup\Scripts\firstboot.ps1'))) { Start-Sleep -Seconds 3 }
  New-Item -ItemType File $firstMark -Force | Out-Null
  Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'JDO x QHT' -ErrorAction SilentlyContinue   # one time only
  Say ''; Say 'Restarting in 10 seconds...' 'Magenta'
  Start-Sleep -Seconds 10
  New-Item -ItemType File $stopFile -Force | Out-Null
  Stop-Transcript | Out-Null
  & shutdown.exe /r /t 2 /c 'JDO x QHT: tweaks applied, restarting'
  return
}
if (-not $DryRun) {
  Stop-Transcript | Out-Null
  # dark theme / mouse speed take effect now, without signing out
  Add-Type -Namespace Qht -Name Ui -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, int m, IntPtr w, string l, int f, int t, out IntPtr r);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(int a, int p, IntPtr v, int f);' -ErrorAction SilentlyContinue
  $r = [IntPtr]::Zero
  [void][Qht.Ui]::SystemParametersInfo(0x71, 0, [IntPtr]12, 3)      # SPI_SETMOUSESPEED 12
  [void][Qht.Ui]::SystemParametersInfo(0x0B, 31, [IntPtr]::Zero, 3) # SPI_SETKEYBOARDSPEED
  [void][Qht.Ui]::SystemParametersInfo(0x17, 0, [IntPtr]::Zero, 3)  # SPI_SETKEYBOARDDELAY
  [void][Qht.Ui]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 3000, [ref]$r)
}
if (-not $Auto -and -not $Quiet -and -not $DryRun) { Write-Host ''; Read-Host '  Press Enter to close' | Out-Null }
