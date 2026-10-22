# JDO x QHT - image builder
# Takes an official Windows 10 22H2 ISO and builds a Fortnite-only ISO from one edition:
#   * no Microsoft Store (Fortnite comes from the Epic Games Launcher); keeps wired / Xbox-adapter controllers and what
#     Easy Anti-Cheat / BattlEye need
#   * removes every inbox app, Xbox apps, Edge, OneDrive, IE, WMP, Hello, telemetry, Search indexing, notifications,
#     Defender (unless -KeepDefender); Bluetooth, Windows Update and every privacy permission but mic + camera are off
#   * slimming (unless -NoSlim): WinRE, payloads of disabled features, speech, CJK fonts, unused system apps,
#     printer/modem drivers
#   * offline registry: service start types, svchost grouping, MMCSS/GPU priority, Game Mode, no background apps
#   * component store cleanup (/ResetBase), recovery-compressed install.esd, BIOS + UEFI bootable ISO
# Hard rule: nothing changes hardware serials / IDs, the MAC, or any network setting. Network services, Wi-Fi,
# the firewall, network drivers and TCP/IP all stay exactly as Windows ships them.
# Usage (as admin): powershell -ExecutionPolicy Bypass -File build.ps1 -Iso C:\Users\1\Desktop\Windows.iso
#   Windows 11 23H2 (official or a near-stock base such as XdzlOS 11 23H2): add -Win11
param(
  [Parameter(Mandatory=$true)][string]$Iso,
  [string]$Work = 'E:\win 10 JDO',
  [string]$Out,
  [string]$Edition = 'Windows 10 Pro',
  [switch]$KeepDefender,
  [switch]$NoMitigations,   # Spectre/Meltdown mitigations off: a few % on older CPUs, less secure
  [switch]$NoSlim,          # skip the size slimming step
  [switch]$MergeSvchost,    # UNSAFE, not default: moves two services to other svchost groups (a black screen at sign-in was seen after it)
  [string]$UpdateMsu,        # a Windows cumulative update (.msu) installed into the image BEFORE the slimming: updated Windows, same size
  [switch]$NoOwnerServices,  # test only: leave the services disabled on the owner's PC (network ones included) as Windows ships them
  [switch]$KeepNgc,          # test only: leave PIN / Windows Hello services as Windows ships them
  [switch]$KeepServicing,   # keep WinSxS (Windows Update / adding features keep working, ISO ~1 GB bigger)
  [switch]$SkipIso,         # stop after the image (no ISO)
  [switch]$IsoOnly,         # only rebuild the ISO from the folder a previous run left in -Work\iso
  [switch]$Win11            # Windows 11 23H2 image: own work folder, edition, ISO name and the Windows 11 shell settings
)
#Requires -RunAsAdministrator
if ($Win11) {
  if (-not $PSBoundParameters.ContainsKey('Work')) { $Work = 'E:\win 11 JDO' }
  if (-not $PSBoundParameters.ContainsKey('Edition')) { $Edition = 'Windows 11 Pro' }
}
$tag = if ($Win11) { 'W11_23H2' } else { 'W10_22H2' }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = Join-Path $here 'files'
$src   = Join-Path $Work 'iso'
$mount = Join-Path $Work 'mount'
$wim   = Join-Path $Work 'install.wim'
$scr   = Join-Path $Work 'scratch'
if (-not $Out) { $Out = Join-Path $Work "JDO_x_QHT_$tag.iso" }
$drv   = Join-Path $Work 'drivers'         # exported from this PC (network)
$extra = Join-Path $Work 'drivers-extra'   # drop any other .inf drivers here (Intel LAN, chipset...) - added to the image too
New-Item -ItemType Directory -Force $Work, $mount, $scr, $drv, $extra | Out-Null
Start-Transcript (Join-Path $Work 'build.log') -Append | Out-Null
# keep a copy of the builder next to the output, so the folder has everything
$copy = Join-Path $Work 'builder'
if ($here -ne $copy) { New-Item -ItemType Directory -Force $copy | Out-Null; Copy-Item "$here\*" $copy -Recurse -Force }
$clock = [Diagnostics.Stopwatch]::StartNew()
function Step([string]$t) { Write-Host ('[{0:hh\:mm\:ss}] {1}' -f $clock.Elapsed, $t) -ForegroundColor Cyan }

# ---------------- what stays / goes ----------------
# Provisioned apps kept: none. The Microsoft Store, its purchase app, App Installer (winget) and the frameworks only
# they used all go - Fortnite comes from the Epic Games Launcher (epicgames.com).
# Windows 11: the Windows App SDK runtime and Store engagement frameworks stay too (frameworks, no process).
$keepApps = '^Microsoft\.(WindowsStore|StorePurchaseApp|DesktopAppInstaller|XboxIdentityProvider|VCLibs|NET\.Native|UI\.Xaml|WindowsAppRuntime|Services\.Store\.Engagement)'

$dropCaps = '^(App\.StepsRecorder|App\.Support\.QuickAssist|Browser\.InternetExplorer|Hello\.Face|MathRecognizer|Microsoft\.Wallpapers\.Extended|' +
            'Microsoft\.Windows\.MSPaint|Microsoft\.Windows\.WordPad|Microsoft\.Windows\.PowerShell\.ISE|OneCoreUAP\.OneSync|OpenSSH\.Client|' +
            'Print\.Fax\.Scan|Print\.Management\.Console|Language\.(Handwriting|OCR|Speech|TextToSpeech))~'

# Windows Media Player and SMB Direct stay: removing them also removes their (inactive) firewall rules and a network
# handler, and the network must stay byte-for-byte stock (test.ps1 checks this).
$dropFeatures = 'Internet-Explorer-Optional-amd64','WorkFolders-Client','MSRDC-Infrastructure',
                'MicrosoftWindowsPowerShellV2Root','MicrosoftWindowsPowerShellV2','Printing-XPSServices-Features'

# Service start types: 2 auto, 3 manual, 4 disabled. Anything not listed keeps the Windows default.
# Kept on purpose: AppXSvc StateRepository ClipSVC LicenseManager (Start menu / system apps and the NVIDIA Control
#   Panel app the driver installs), CryptSvc Winmgmt Schedule TimeBrokerSvc EventLog (anti-cheats, Task Scheduler),
#   audio, XboxGipSvc (controllers), and every network service (Wi-Fi, firewall, IP Helper, sharing, discovery,
#   Delivery Optimization...) at its default.
$services = [ordered]@{
  # Windows Update, its orchestrator / self-repair and the Store / Microsoft account services. Safe in the image
  # because autounattend skips the setup screens (OOBE) - they were what needed these services (OOBEZDP error).
  TrustedInstaller=3   # Windows ships it on demand; it only needs to run for servicing (one process less at idle)
  WaaSMedicSvc=4; UsoSvc=4   # update orchestrator (MoUSO worker) off; wuauserv / wlidsvc / InstallService stay stock: the Store needs them
  # services with no use on a gaming desktop (asked: everything without a reason off). Network, audio, Store, NVIDIA,
  # controllers, typing, phone (MTP) and time sync stay.
  sppsvc=3   # activation: on demand (its triggers start it when Windows checks the licence) - one process less
  vmickvpexchange=4; vmicguestinterface=4; vmicshutdown=4; vmicheartbeat=4; vmicvmsession=4; vmicrdv=4; vmictimesync=4; vmicvss=4; HvHost=4   # Hyper-V guest: only inside a VM
  SensorService=4; SensrSvc=4; SensorDataService=4   # sensors (a desktop has none)
  WebClient=4; fhsvc=4; spectrum=4   # WebDAV, File History, mixed reality
  # the owner's own Windows has these disabled and runs fine (read from its registry + screenshots): same here, asked for explicitly
  # (several are network-related: this is the one place the build touches network services, on the owner's instruction)
  DispBrokerDesktopSvc=4; DsSvc=4; 'FontCache3.0.0.0'=4; hidserv=4; IKEEXT=4; LanmanServer=4; LanmanWorkstation=4; lmhosts=4; NetTcpPortSharing=4; PolicyAgent=4; RasAuto=4; RasMan=4; RmSvc=4; SessionEnv=4; SstpSvc=4; TermService=4; tzautoupdate=4; UmRdpService=4; Wcmsvc=4; Wecsvc=4; WlanSvc=4; workfolderssvc=4; XboxGipSvc=4
  NgcSvc=4; NgcCtnrSvc=4   # PIN / Windows Hello (the account has no password; asked to remove the PIN)
  # (PIN / Hello, BitLocker, smart cards, kiosk, MDM... are on-demand and cost no process: left as Windows ships them, nothing sign-in related is touched)
  DoSvc=4   # Delivery Optimization (peer-to-peer update downloads): off - asked for by the owner
  # Bluetooth (BTHUSB is the radio driver itself)
  bthserv=4; BTAGService=4; BthAvctpSvc=4; BluetoothUserService=4; BTHUSB=4
  # Xbox Live / Game Pass sign-in (not used); the controller service stays on demand
  XblAuthManager=4; XblGameSave=4
  # notifications and the touch keyboard: each is a process on the desktop
  # (the touch keyboard service stays on demand: typing in the Start menu search box needs it)
  WpnService=4; WpnUserService=4; TabletInputService=3
  # storage service only when something asks for it (CTT)
  StorSvc=3
  # telemetry and diagnostics
  DiagTrack=4; dmwappushservice=4; 'diagnosticshub.standardcollector.service'=4; WerSvc=4; wercplsupport=4; PcaSvc=4
  DPS=4; WdiServiceHost=4; WdiSystemHost=4; diagsvc=4; TroubleshootingSvc=4
  # background work nobody needs for games
  SysMain=4; WSearch=4; MapsBroker=4; lfsvc=4; RetailDemo=4; TrkWks=4; CscService=4; WalletService=4; MixedRealityOpenXRSvc=4
  SmsRouter=4; PhoneSvc=4; wisvc=4; WbioSrvc=4; SEMgrSvc=4; SCardSvr=4; ScDeviceEnum=4; SCPolicySvc=4; stisvc=4
  FrameServer=3; DisplayEnhancementService=4; ShellHWDetection=4; WpcMonSvc=4
  # printing, remote registry
  Spooler=4; PrintNotify=4; Fax=4; RemoteRegistry=4
  # sync / phone / clipboard / capture (per-user service templates)
  CDPSvc=4; CDPUserSvc=4; OneSyncSvc=4; PimIndexMaintenanceSvc=4; UnistoreSvc=4; UserDataSvc=4; MessagingService=4
  cbdhsvc=4; BcastDVRUserService=4; CaptureService=4; PrintWorkflowUserSvc=4
  # Edge is removed from the image
  edgeupdate=4; edgeupdatem=4; MicrosoftEdgeElevationService=4
}
if ($Win11) {
  # Windows 11 only: app inventory, "health and optimized experiences", voice-assistant runtime, WSL file share, pen.
  # (TextInputManagementService stays: typing in Windows 11 needs it.)
  foreach ($k in 'InventorySvc', 'whesvc', 'AarSvc', 'P9RdrService', 'PenService') { $services[$k] = 4 }
  # XdzlOS sets the Network Setup Service to start automatically; Windows ships it on demand (trigger start): back to stock
  $services['NetSetupSvc'] = 3
  # XdzlOS starts the app state store at boot (its own svchost "appmodel"); on demand it only runs when an app needs it
  $services['StateRepository'] = 3
}
if ($NoOwnerServices) { foreach ($k in 'DispBrokerDesktopSvc','DsSvc','FontCache3.0.0.0','hidserv','IKEEXT','LanmanServer','LanmanWorkstation','lmhosts','NetTcpPortSharing','PolicyAgent','RasAuto','RasMan','RmSvc','SessionEnv','SstpSvc','TermService','tzautoupdate','UmRdpService','Wcmsvc','Wecsvc','WlanSvc','workfolderssvc','XboxGipSvc') { $services.Remove($k) } }
if ($KeepNgc) { $services.Remove('NgcSvc'); $services.Remove('NgcCtnrSvc') }
$defender = [ordered]@{ WinDefend=4; WdNisSvc=4; WdNisDrv=4; WdFilter=4; WdBoot=4; Sense=4; SecurityHealthService=4; wscsvc=4; SgrmBroker=4; SgrmAgent=4
                        webthreatdefsvc=4; webthreatdefusersvc=4 }   # Windows 11: SmartScreen web threat protection

# ---------------- offline registry helper ----------------
# Writes with SeRestorePrivilege + REG_OPTION_BACKUP_RESTORE, so protected keys (WinDefend, WaaSMedicSvc...) can be set offline.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class OffReg
{
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TokenPrivileges { public int Count; public long Luid; public int Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegCreateKeyEx(UIntPtr key, string subKey, int reserved, string cls, int options, int sam, IntPtr security, out UIntPtr result, out int disposition);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegSetValueEx(UIntPtr key, string name, int reserved, int type, byte[] data, int size);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegDeleteValue(UIntPtr key, string name);
    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(UIntPtr key);

    static readonly UIntPtr HKLM = new UIntPtr(0x80000002u);

    public static void EnablePrivileges()
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception();
        // Restore only: with SeBackupPrivilege also on, REG_OPTION_BACKUP_RESTORE opens keys read-only
        foreach (string p in new[] { "SeRestorePrivilege", "SeTakeOwnershipPrivilege" })
        {
            TokenPrivileges tp = new TokenPrivileges();
            tp.Count = 1; tp.Attributes = 2;
            if (!LookupPrivilegeValue(null, p, out tp.Luid)) throw new Win32Exception();
            AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
    }

    // Normal create/open first (a backup/restore handle on a key it has just created cannot set values);
    // REG_OPTION_BACKUP_RESTORE only when the key's ACL denies us.
    static UIntPtr Open(string subKey)
    {
        UIntPtr h; int disp;
        int rc = RegCreateKeyEx(HKLM, subKey, 0, null, 0, 0xF003F /* KEY_ALL_ACCESS */, IntPtr.Zero, out h, out disp);
        if (rc == 5)
        {
            rc = RegCreateKeyEx(HKLM, subKey, 0, null, 4 /* REG_OPTION_BACKUP_RESTORE */, 0, IntPtr.Zero, out h, out disp);
            // a key it has just created comes back without write access: reopen it now that it exists
            if (rc == 0 && disp == 1 /* REG_CREATED_NEW_KEY */)
            {
                RegCloseKey(h);
                rc = RegCreateKeyEx(HKLM, subKey, 0, null, 4, 0, IntPtr.Zero, out h, out disp);
            }
        }
        if (rc != 0) throw new Win32Exception(rc, subKey + " (error " + rc + ")");
        return h;
    }

    static void Set(string subKey, string name, int type, byte[] data)
    {
        UIntPtr h = Open(subKey);
        try { int rc = RegSetValueEx(h, name, 0, type, data, data.Length); if (rc != 0) throw new Win32Exception(rc, subKey + "\\" + name + " (error " + rc + ")"); }
        finally { RegCloseKey(h); }
    }

    public static void SetDword(string subKey, string name, uint value) { Set(subKey, name, 4, BitConverter.GetBytes(value)); }
    public static void SetBinary(string subKey, string name, byte[] value) { Set(subKey, name, 3, value); }
    public static void SetString(string subKey, string name, string value) { Set(subKey, name, 1, Encoding.Unicode.GetBytes(value + "\0")); }
    public static void SetExpandString(string subKey, string name, string value) { Set(subKey, name, 2, Encoding.Unicode.GetBytes(value + "\0")); }
    public static void SetMultiString(string subKey, string name, string[] values) { Set(subKey, name, 7, Encoding.Unicode.GetBytes(string.Join("\0", values) + "\0\0")); }

    public static void DeleteValue(string subKey, string name)
    {
        UIntPtr h = Open(subKey);
        try { RegDeleteValue(h, name); } finally { RegCloseKey(h); }
    }
}
'@
[OffReg]::EnablePrivileges()

$hives = [ordered]@{
  JDO_SOFTWARE = 'Windows\System32\config\SOFTWARE'
  JDO_SYSTEM   = 'Windows\System32\config\SYSTEM'
  JDO_NTUSER   = 'Users\Default\NTUSER.DAT'
  JDO_DEFAULT  = 'Windows\System32\config\DEFAULT'   # the sign-in screen's own profile
}
function HiveKey([string]$k) { $k -replace '^(SOFTWARE|SYSTEM|NTUSER|DEFAULT)\\', 'JDO_$1\' }
# A value Windows itself protects (e.g. Feeds\ShellFeedsTaskbarViewMode) is reported and skipped, not fatal.
function Set-Reg([string]$Key, [string]$Name, $Value) {
  try {
    if ($Value -is [string]) { [OffReg]::SetString((HiveKey $Key), $Name, $Value) }
    elseif ($Value -is [byte[]]) { [OffReg]::SetBinary((HiveKey $Key), $Name, $Value) }
    else { [OffReg]::SetDword((HiveKey $Key), $Name, [uint32]$Value) }
  } catch { Write-Host "  skipped $Key\$Name ($($_.Exception.InnerException.Message))" -ForegroundColor Yellow }
}
function Remove-RegValue([string]$Key, [string]$Name) {
  if (Test-Path ('Registry::HKEY_LOCAL_MACHINE\' + (HiveKey $Key))) { [OffReg]::DeleteValue((HiveKey $Key), $Name) }
}
function Set-Svc([string]$Name, [int]$Start) {
  $k = "SYSTEM\ControlSet001\Services\$Name"
  if (Test-Path ('Registry::HKEY_LOCAL_MACHINE\' + (HiveKey $k))) { Set-Reg $k 'Start' $Start } else { Write-Host "  (no service $Name)" }
}
function Unload-Hives {
  foreach ($h in $hives.Keys) {
    if (-not (Test-Path "Registry::HKEY_LOCAL_MACHINE\$h")) { continue }
    for ($i = 0; $i -lt 15; $i++) {
      [gc]::Collect(); [gc]::WaitForPendingFinalizers()
      & reg.exe unload "HKLM\$h" | Out-Null
      if ($LASTEXITCODE -eq 0) { break }
      Start-Sleep -Seconds 2
    }
    if ($LASTEXITCODE -ne 0) { throw "Could not unload HKLM\$h" }
  }
}
function Remove-Owned([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  # /r only for folders (takeown fails on a single file with /r); native stderr must not stop the build
  $r = if (Test-Path $Path -PathType Container) { @('/r', '/d', 'y') } else { @() }
  & cmd.exe /c "takeown.exe /f `"$Path`" /a $($r -join ' ') >nul 2>&1"
  & cmd.exe /c "icacls.exe `"$Path`" /grant *S-1-5-32-544:F /t /c /q >nul 2>&1"
  Remove-Item -LiteralPath $Path -Recurse -Force
  Write-Host "  removed $Path"
}

# Setup's boot.wim carries its own WinSxS, speech and CJK boot fonts - none of it is used to install from USB.
# Same rule as the main image: the run-time side-by-side assemblies stay. Safe to run again (finds nothing new).
$keepSxs = '^((amd64|x86|wow64|msil)_(microsoft\.windows\.|microsoft\.vc\d|policy\.)|Catalogs$|Manifests$|FileMaps$|Fusion$|InstallTemp$|Temp$)'
function Slim-BootWim {
  $bw = "$src\sources\boot.wim"
  $bm = Join-Path $Work 'bootmount'
  $tmp = Join-Path $Work 'boot-slim.wim'
  Step 'Slimming boot.wim (its WinSxS, speech, CJK boot fonts, printer / modem drivers)'
  if (Test-Path $bm) { Get-WindowsImage -Mounted | Where-Object Path -eq $bm | ForEach-Object { Dismount-WindowsImage -Path $bm -Discard | Out-Null } }
  New-Item -ItemType Directory -Force $bm | Out-Null
  $before = (Get-Item $bw).Length
  Mount-WindowsImage -ImagePath $bw -Index 1 -Path $bm -ScratchDirectory $scr | Out-Null
  try {
    $sxs = "$bm\Windows\WinSxS"
    & takeown.exe /f $sxs /r /a /d y | Out-Null
    & icacls.exe $sxs /grant '*S-1-5-32-544:F' /t /c /q | Out-Null
    Get-ChildItem -LiteralPath $sxs -Force | Where-Object { $_.Name -notmatch $keepSxs } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath "$sxs\Manifests" -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $keepSxs } | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($p in "$bm\Windows\Speech", "$bm\Windows\System32\Speech", "$bm\Windows\System32\Speech_OneCore") { Remove-Owned $p }
    Get-ChildItem "$bm\Windows\Boot\Fonts" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(chs|cht|jpn|kor|malgun|meiryo|msjh|msyh)' } | ForEach-Object { Remove-Owned $_.FullName }
    Get-ChildItem "$bm\Windows\System32\DriverStore\FileRepository" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(prn|ntprint|mdm)' } | ForEach-Object { Remove-Owned $_.FullName }
    Dismount-WindowsImage -Path $bm -Save -ScratchDirectory $scr | Out-Null
  } catch { Dismount-WindowsImage -Path $bm -Discard | Out-Null; throw }
  # re-export so the deleted files really leave the file
  if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
  & dism.exe /Export-Image "/SourceImageFile:$bw" /SourceIndex:1 "/DestinationImageFile:$tmp" /Compress:max /Bootable
  if ($LASTEXITCODE -ne 0) { throw "boot.wim re-export failed ($LASTEXITCODE)" }
  Move-Item -LiteralPath $tmp $bw -Force
  Write-Host ('  boot.wim: {0:N0} MB -> {1:N0} MB' -f ($before / 1MB), ((Get-Item $bw).Length / 1MB))
}

if ($IsoOnly) {
  if (-not (Test-Path "$src\sources\install.esd")) { throw "No finished image in $src - run without -IsoOnly first" }
  if (-not $NoSlim) { Slim-BootWim }
} else {
try {
  # ---------------- 0. leftovers from an interrupted run ----------------
  Unload-Hives
  # a killed DISM leaves the image's hives loaded as HKLM\{guid}E:/.../mount/..., which blocks the unmount
  $mfwd = $mount -replace '\\', '/'
  foreach ($h in (& reg.exe query HKLM) | Where-Object { $_.Contains($mfwd) }) {
    [gc]::Collect(); & reg.exe unload $h | Out-Null
    Write-Host "  unloaded leftover hive $h"
  }
  Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mount } | ForEach-Object {
    Step 'Discarding a mount left over from an earlier run'
    Dismount-WindowsImage -Path $mount -Discard | Out-Null
  }

  # ---------------- 1. ISO -> folder ----------------
  Step "Extracting $Iso"
  if (Test-Path $src) { Remove-Item -LiteralPath $src -Recurse -Force }
  $7z = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $7z) { throw '7-Zip is needed to extract the ISO (https://www.7-zip.org).' }
  & $7z x $Iso "-o$src" -y -bso0 -bsp0
  if ($LASTEXITCODE -ne 0) { throw "7-Zip failed ($LASTEXITCODE)" }
  $esd = Get-ChildItem "$src\sources\install.*" | Where-Object { $_.Extension -in '.esd', '.wim' } | Select-Object -First 1
  $img = Get-WindowsImage -ImagePath $esd.FullName | Where-Object { $_.ImageName -eq $Edition }
  if (-not $img) { throw "No '$Edition' in $($esd.Name)" }
  $info = Get-WindowsImage -ImagePath $esd.FullName -Index $img.ImageIndex
  Write-Host "  $($info.ImageName) $($info.Version) $($info.Languages -join ',')"
  if ($Win11) { if ($info.Version -notmatch '^10\.0\.226[23]1\.') { throw "Expected Windows 11 23H2 (10.0.22631.x), got $($info.Version)" } }
  elseif ($info.Version -notlike '10.0.19041.*') { throw "Expected Windows 10 22H2 (10.0.19041.x), got $($info.Version) - for Windows 11 add -Win11" }

  # ---------------- 2. one edition -> mountable WIM ----------------
  Step "Exporting '$Edition' to a WIM"
  if (Test-Path $wim) { Remove-Item -LiteralPath $wim -Force }
  Export-WindowsImage -SourceImagePath $esd.FullName -SourceIndex $img.ImageIndex -DestinationImagePath $wim -CompressionType max -ScratchDirectory $scr | Out-Null
  Remove-Item -LiteralPath $esd.FullName -Force
  Step 'Mounting'
  Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount -ScratchDirectory $scr | Out-Null
  if ($UpdateMsu) {
    # the update goes in first: everything after (apps removal, slimming, WinSxS pruning) works on the updated files
    Step "Installing the cumulative update $([IO.Path]::GetFileName($UpdateMsu)) - this takes a while"
    $sig = Get-AuthenticodeSignature $UpdateMsu
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw "the update's signature is not valid ($($sig.Status))" }
    & dism.exe "/Image:$mount" /Add-Package "/PackagePath:$UpdateMsu" "/ScratchDir:$scr"
    if ($LASTEXITCODE -notin 0, 3010) { throw "installing the update failed ($LASTEXITCODE)" }
    Write-Host '  update installed'
  }

  # ---------------- 3. apps, capabilities, features ----------------
  # An unregistered copy of the Store / Xbox sign-in packages and their frameworks goes to C:\JDO\Store, so
  # JDO-Tools can put the Store back offline (and take it away again) - e.g. to get the NVIDIA Control Panel.
  Step 'Keeping a copy of the Microsoft Store / Xbox packages for JDO-Tools'
  $storeCopy = Join-Path $Work 'store-copy'
  if (Test-Path $storeCopy) { Remove-Item -LiteralPath $storeCopy -Recurse -Force }
  New-Item -ItemType Directory -Force $storeCopy | Out-Null
  Get-ChildItem "$mount\Program Files\WindowsApps" -Directory -Force |
    Where-Object { $_.Name -match '^Microsoft\.(WindowsStore|StorePurchaseApp|DesktopAppInstaller|XboxIdentityProvider|Xbox\.TCUI)_|^Microsoft\.(VCLibs|NET\.Native|UI\.Xaml)[^_]*_' } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $storeCopy -Recurse -Force; Write-Host "  copied $($_.Name)" }

  Step 'Removing inbox apps'
  foreach ($a in Get-AppxProvisionedPackage -Path $mount) {
    if ($a.DisplayName -match $keepApps) { Write-Host "  keep   $($a.DisplayName)"; continue }
    Write-Host "  remove $($a.DisplayName)"
    Remove-AppxProvisionedPackage -Path $mount -PackageName $a.PackageName -ScratchDirectory $scr | Out-Null
  }
  Step 'Removing capabilities'
  foreach ($c in Get-WindowsCapability -Path $mount | Where-Object { $_.State -eq 'Installed' -and $_.Name -match $dropCaps }) {
    Write-Host "  remove $($c.Name)"
    Remove-WindowsCapability -Path $mount -Name $c.Name -ScratchDirectory $scr | Out-Null
  }
  Step 'Disabling optional features'
  $enabled = Get-WindowsOptionalFeature -Path $mount | Where-Object { $_.State -eq 'Enabled' } | ForEach-Object { $_.FeatureName }
  foreach ($f in $dropFeatures | Where-Object { $enabled -contains $_ }) {
    Write-Host "  disable $f"
    Disable-WindowsOptionalFeature -Path $mount -FeatureName $f -Remove -ScratchDirectory $scr | Out-Null
  }

  # ---------------- 4. files ----------------
  Step 'Removing Edge and OneDrive'
  foreach ($p in 'Edge', 'EdgeUpdate', 'EdgeCore') { Remove-Owned "$mount\Program Files (x86)\Microsoft\$p" }   # EdgeWebView (WebView2) stays
  # Windows 11 carries WebView2 twice: its own copy in System32 (search, Settings) stays; the 2022 copy in Program Files
  # never updates (Edge Update is off) - an app that needs WebView2 installs the current one itself
  if ($Win11) { Remove-Owned "$mount\Program Files (x86)\Microsoft\EdgeWebView" }
  foreach ($p in "$mount\Windows\SysWOW64\OneDriveSetup.exe", "$mount\Windows\System32\OneDriveSetup.exe",
                 "$mount\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
                 "$mount\Users\Public\Desktop\Microsoft Edge.lnk") { Remove-Owned $p }

  Step "Exporting this PC's network drivers"
  Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -eq 'NET' -and $_.InfName -like 'oem*.inf' } |
    Select-Object -ExpandProperty InfName -Unique | ForEach-Object {
      $to = Join-Path $drv ([IO.Path]::GetFileNameWithoutExtension($_))
      New-Item -ItemType Directory -Force $to | Out-Null   # pnputil needs the folder to exist
      & pnputil.exe /export-driver $_ $to | Out-Null
      if (-not (Get-ChildItem $to -Filter *.inf)) { throw "Could not export network driver $_ - the image would have no network" }
      Write-Host "  exported $_"
    }
  Step 'Adding drivers to the image'
  foreach ($d in $drv, $extra) {
    if (Get-ChildItem $d -Filter *.inf -Recurse) {
      Add-WindowsDriver -Path $mount -Driver $d -Recurse -ScratchDirectory $scr | ForEach-Object { Write-Host "  added $($_.OriginalFileName | Split-Path -Leaf)" }
    }
  }

  Step 'Adding setup scripts, Start/taskbar layout and the JDO folder'
  New-Item -ItemType Directory -Force "$mount\Windows\Setup\Scripts", "$mount\Users\Default\AppData\Local\Microsoft\Windows\Shell" | Out-Null
  # first boot runs from autounattend's FirstLogonCommands once the desktop is up. No SetupComplete.cmd: it runs in the
  # middle of setup, and changing devices / services there made setup loop on "Just a moment..." on a real PC.
  Copy-Item "$files\firstboot.ps1" "$mount\Windows\Setup\Scripts\" -Force
  # tiny SetupComplete (no devices, no services): an account made without a password is flagged "must change password" and the
  # first autologon is refused - setting its password to empty again clears the flag, password never expires
  $sc = '@echo off', 'net user "JDO x QHT" "" /expires:never', 'wmic useraccount where "name=''JDO x QHT''" set PasswordExpires=false', 'sc config TrustedInstaller start= disabled', 'exit /b 0'
  Set-Content "$mount\Windows\Setup\Scripts\SetupComplete.cmd" $sc -Encoding Ascii
  if ($Win11) {
    # Windows 11 reads the taskbar pins from the same file (22H2 and later) and the Start pins from a JSON file
    Copy-Item "$files\LayoutModification-11.xml" "$mount\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml" -Force
    Copy-Item "$files\LayoutModification.json" "$mount\Users\Default\AppData\Local\Microsoft\Windows\Shell\" -Force
  } else { Copy-Item "$files\LayoutModification.xml" "$mount\Users\Default\AppData\Local\Microsoft\Windows\Shell\" -Force }
  Copy-Item "$files\JDO" "$mount\" -Recurse -Force
  if ($Win11) {
    $rm = "$mount\JDO\README.txt"
    $t = Get-Content $rm -Encoding UTF8; $t[0] = 'JDO x QHT - Windows 11 23H2 (Pro)'; Set-Content $rm $t -Encoding UTF8
  }
  New-Item -ItemType Directory -Force "$mount\JDO\Drivers", "$mount\JDO\Store" | Out-Null
  Get-ChildItem -LiteralPath $storeCopy -Directory | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination "$mount\JDO\Store\" -Force }
  foreach ($d in $drv, $extra) { Get-ChildItem $d | Copy-Item -Destination "$mount\JDO\Drivers\" -Recurse -Force }
  # plain black image for the sign-in screen
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 1920, 1080
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::Black)
  $bmp.Save("$mount\JDO\black.jpg", [System.Drawing.Imaging.ImageFormat]::Jpeg); $g.Dispose(); $bmp.Dispose()
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$mount\Users\Public\Desktop\JDO Tools.lnk")
  $lnk.TargetPath = 'C:\JDO\JDO-Tools.cmd'; $lnk.WorkingDirectory = 'C:\JDO'; $lnk.IconLocation = 'C:\JDO\Icons\tools.ico,0'
  $lnk.Save()
  New-Item -ItemType Directory -Force "$mount\ProgramData\Microsoft\Windows\Start Menu\Programs" | Out-Null   # and in the Start menu, so search finds it
  $lnk2 = (New-Object -ComObject WScript.Shell).CreateShortcut("$mount\ProgramData\Microsoft\Windows\Start Menu\Programs\JDO Tools.lnk")
  $lnk2.TargetPath = 'C:\JDO\JDO-Tools.cmd'; $lnk2.WorkingDirectory = 'C:\JDO'; $lnk2.IconLocation = 'C:\JDO\Icons\tools.ico,0'; $lnk2.Save()

  # ---------------- 5. offline registry ----------------
  Step 'Editing the registry'
  foreach ($h in $hives.Keys) {
    & reg.exe load "HKLM\$h" (Join-Path $mount $hives[$h]) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load $h failed" }
  }

  foreach ($s in $services.Keys) { Set-Svc $s $services[$s] }
  if ((Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\JDO_SYSTEM\ControlSet001\Services\TrustedInstaller").Start -ne 3) { [OffReg]::SetDword('JDO_SYSTEM\ControlSet001\Services\TrustedInstaller', 'Start', 3) }
  if (-not $KeepDefender) {
    foreach ($s in $defender.Keys) { Set-Svc $s $defender[$s] }
    Set-Reg 'SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
    Set-Reg 'SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 1
    Set-Reg 'SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 2
    Set-Reg 'SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
    Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off'
    Remove-RegValue 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'SecurityHealth'
  }

  # Windows Firewall is network: left exactly as Windows ships it.
  # UAC never asks. EnableLUA stays 1: with UAC fully off, the Start menu search, Settings and the NVIDIA Control
  # Panel (all packaged apps) refuse to start.
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 0
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 0
  # Security Center / notifications about Defender and the firewall
  Set-Reg 'SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableNotifications' 1

  # privacy: every app permission off except the microphone and camera (streaming); radios / cellular data (network)
  # and HID devices (controllers) keep their defaults
  $consent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
  foreach ($c in 'location','userNotificationListener','userAccountInformation','contacts','appointments','phoneCall',
                 'phoneCallHistory','email','userDataTasks','chat','bluetoothSync','appDiagnostics','documentsLibrary',
                 'picturesLibrary','videosLibrary','broadFileSystemAccess','gazeInput','activity') {
    Set-Reg "$consent\$c" 'Value' 'Deny'
  }
  foreach ($c in 'microphone', 'webcam') {
    Set-Reg "$consent\$c" 'Value' 'Allow'
    Set-Reg "NTUSER\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$c" 'Value' 'Allow'
    Set-Reg "NTUSER\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$c\NonPackaged" 'Value' 'Allow'
  }
  # (no LetAppsRunInBackground policy and no global background-app switch: they stopped Start menu search from working)

  # svchost merge - OFF unless build.ps1 -MergeSvchost (a black screen at sign-in was seen right after it was added): two services that sit alone in their own svchost move into a group of the
  # same account - audio endpoints (LocalSystem) into netsvcs, the UI message registrar (LocalService) into LocalService.
  # 9 -> 7 svchost processes at idle. Network services are not moved. JDO-Tools switch "svchost merge" puts it back.
  $svchost = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost'
  if ($MergeSvchost) {
  foreach ($m in @(@('AudioEndpointBuilder', 'LocalSystemNetworkRestricted', 'netsvcs'), @('CoreMessagingRegistrar', 'LocalServiceNoNetwork', 'LocalService'))) {
    $sk = "SYSTEM\ControlSet001\Services\$($m[0])"
    $img = (Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\$(HiveKey $sk)" -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if ($img -notmatch "-k\s+$($m[1])\b") { Write-Host "  svchost merge: $($m[0]) not in $($m[1]) ($img) - left alone" -ForegroundColor Yellow; continue }
    $list = @((Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\$(HiveKey $svchost)" -Name $m[2]).($m[2]))
    if ($list -notcontains $m[0]) { [OffReg]::SetMultiString((HiveKey $svchost), $m[2], [string[]]($list + $m[0])) }
    [OffReg]::SetExpandString((HiveKey $sk), 'ImagePath', ($img -replace "-k\s+$($m[1])\b", "-k $($m[2])"))
    Write-Host "  svchost merge: $($m[0]) -> $($m[2])"
  }
  }

  # fewer processes: group services into shared svchost hosts instead of one per service
  Set-Reg 'SYSTEM\ControlSet001\Control' 'SvcHostSplitThresholdInKB' 4294967295
  # scheduler, GPU, VBS, power
  Set-Reg 'SYSTEM\ControlSet001\Control\PriorityControl' 'Win32PrioritySeparation' 0x26
  Set-Reg 'SYSTEM\ControlSet001\Control\GraphicsDrivers' 'HwSchMode' 2
  Set-Reg 'SYSTEM\ControlSet001\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
  Set-Reg 'SYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
  Set-Reg 'SYSTEM\ControlSet001\Control\Power' 'HibernateEnabled' 0
  Set-Reg 'SYSTEM\ControlSet001\Control\Session Manager\Power' 'HiberbootEnabled' 0
  Set-Reg 'SYSTEM\ControlSet001\Control\Remote Assistance' 'fAllowToGetHelp' 0
  if ($NoMitigations) {
    Set-Reg 'SYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'FeatureSettingsOverride' 3
    Set-Reg 'SYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'FeatureSettingsOverrideMask' 3
  }

  # MMCSS: games get the CPU/GPU first. No network settings are touched anywhere in the build (rule: no serial / MAC /
  # IP / adapter / TCP changes), so NetworkThrottlingIndex stays at the Windows default.
  $mm = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
  Set-Reg $mm 'SystemResponsiveness' 10
  Set-Reg "$mm\Tasks\Games" 'GPU Priority' 8
  Set-Reg "$mm\Tasks\Games" 'Priority' 6
  Set-Reg "$mm\Tasks\Games" 'Scheduling Category' 'High'
  Set-Reg "$mm\Tasks\Games" 'SFIO Priority' 'High'

  # no 7 GB reserved storage, no consumer apps pushed in later
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 0
  $pol = 'SOFTWARE\Policies\Microsoft\Windows'
  Set-Reg "$pol\CloudContent" 'DisableWindowsConsumerFeatures' 1
  Set-Reg "$pol\CloudContent" 'DisableSoftLanding' 1
  Set-Reg "$pol\CloudContent" 'DisableCloudOptimizedContent' 1
  # telemetry, ads, activity history, error reports, compatibility inventory
  Set-Reg "$pol\DataCollection" 'AllowTelemetry' 0
  Set-Reg "$pol\DataCollection" 'DoNotShowFeedbackNotifications' 1
  Set-Reg "$pol\AdvertisingInfo" 'DisabledByGroupPolicy' 1
  Set-Reg "$pol\System" 'EnableActivityFeed' 0
  Set-Reg "$pol\System" 'PublishUserActivities' 0
  Set-Reg "$pol\System" 'UploadUserActivities' 0
  Set-Reg "$pol\System" 'AllowClipboardHistory' 0
  Set-Reg "$pol\Windows Error Reporting" 'Disabled' 1
  Set-Reg "$pol\AppCompat" 'AITEnable' 0
  Set-Reg "$pol\AppCompat" 'DisableInventory' 1
  Set-Reg "$pol\AppCompat" 'DisableUAR' 1
  Set-Reg "$pol\LocationAndSensors" 'DisableLocation' 1
  Set-Reg 'SOFTWARE\Policies\Microsoft\Windows\Maps' 'AutoDownloadAndUpdateMapData' 0
  # search box, Cortana, News and Interests (it runs WebView2 processes), Meet Now, OneDrive
  Set-Reg "$pol\Windows Search" 'AllowCortana' 0
  Set-Reg "$pol\Windows Search" 'DisableWebSearch' 1
  Set-Reg "$pol\Windows Search" 'ConnectedSearchUseWeb' 0
  Set-Reg "$pol\Windows Search" 'AllowSearchToUseLocation' 0
  Set-Reg "$pol\Windows Feeds" 'EnableFeeds' 0
  Set-Reg "$pol\OneDrive" 'DisableFileSyncNGSC' 1
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'HideSCAMeetNow' 1
  Set-Reg 'SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main' 'AllowPrelaunch' 0
  # updates only when you ask (the OOBE update check that tripped over these is skipped by autounattend);
  # Delivery Optimization is network: default. No Game DVR.
  Set-Reg "$pol\WindowsUpdate\AU" 'NoAutoUpdate' 1
  Set-Reg "$pol\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 1
  # Windows updates paused (Settings > Windows Update > Pause) until 2099 and deferred to the maximum: the VM test caught
  # Windows Update downloading KB5020683 at every shutdown and hanging on "Getting Windows ready" (this slimmed Windows
  # cannot install updates). The Store is not affected by the pause.
  $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); $end = '2099-12-31T00:00:00Z'
  $ux = 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
  foreach ($kv in @(@('PauseUpdatesStartTime', $now), @('PauseUpdatesExpiryTime', $end), @('PauseQualityUpdatesStartTime', $now),
                    @('PauseQualityUpdatesEndTime', $end), @('PauseFeatureUpdatesStartTime', $now), @('PauseFeatureUpdatesEndTime', $end))) { Set-Reg $ux $kv[0] $kv[1] }
  Set-Reg "$pol\WindowsUpdate" 'DeferQualityUpdates' 1
  Set-Reg "$pol\WindowsUpdate" 'DeferQualityUpdatesPeriodInDays' 30
  Set-Reg "$pol\WindowsUpdate" 'DeferFeatureUpdates' 1
  Set-Reg "$pol\WindowsUpdate" 'DeferFeatureUpdatesPeriodInDays' 365
  Set-Reg "$pol\WindowsUpdate" 'PauseQualityUpdatesStartTime' ((Get-Date).ToString('yyyy-MM-dd'))
  Set-Reg "$pol\WindowsUpdate" 'PauseFeatureUpdatesStartTime' ((Get-Date).ToString('yyyy-MM-dd'))
  Set-Reg "$pol\WindowsUpdate" 'PauseQualityUpdates' 1
  Set-Reg "$pol\WindowsUpdate" 'PauseFeatureUpdates' 1
  Set-Reg "$pol\WindowsUpdate\AU" 'NoAUShutdownOption' 1          # no "Update and shut down / restart"
  Set-Reg "$pol\WindowsUpdate\AU" 'NoAUAsDefaultShutdownOption' 1
  Set-Reg "$pol\GameDVR" 'AllowGameDVR' 0
  # Start menu search and the text input host stay, at the lowest priority Windows has (CPU idle, I/O very low,
  # memory lowest): they sleep until you open Start or type, and never compete with the game
  $ifeo = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
  foreach ($exe in 'SearchApp.exe', 'SearchHost.exe', 'TextInputHost.exe') {   # SearchHost: the Windows 11 name
    Set-Reg "$ifeo\$exe\PerfOptions" 'CpuPriorityClass' 1
    Set-Reg "$ifeo\$exe\PerfOptions" 'IoPriority' 0
    Set-Reg "$ifeo\$exe\PerfOptions" 'PagePriority' 1
  }
  # notifications off (WpnService is disabled above): no toasts, no Action Center
  Set-Reg 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
  Set-Reg 'NTUSER\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0

  # default user profile (every new account starts with these)
  $cdm = 'NTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
  foreach ($v in 'ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','PreInstalledAppsEverEnabled',
                 'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','RotatingLockScreenEnabled',
                 'RotatingLockScreenOverlayEnabled','SubscribedContent-310093Enabled','SubscribedContent-338388Enabled',
                 'SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled',
                 'SubscribedContent-353696Enabled','SubscribedContent-353698Enabled') { Set-Reg $cdm $v 0 }
  $cv = 'NTUSER\Software\Microsoft\Windows\CurrentVersion'
  # the "Run / Cancel" warning when opening a program from another drive or a download, and Run as administrator
  Set-Reg "$cv\Policies\Attachments" 'SaveZoneInformation' 1
  Set-Reg "$cv\Policies\Associations" 'LowRiskFileTypes' '.exe;.bat;.cmd;.com;.msi;.ps1;.vbs;.reg;.lnk;.jar'
  foreach ($z in 0,1,2,3) { Set-Reg "$cv\Internet Settings\Zones\$z" '1806' 0 }
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' '.exe;.bat;.cmd;.com;.msi;.ps1;.vbs;.reg;.lnk;.jar'
  # JDO x QHT tweaks run 5 seconds after every desktop
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'JDO x QHT' 'cmd.exe /c start "" /min C:\JDO\JDO-x-QHT.cmd /auto'
  Set-Reg "$cv\Search" 'SearchboxTaskbarMode' 0
  Set-Reg "$cv\Search" 'BingSearchEnabled' 0
  Set-Reg "$cv\Search" 'CortanaConsent' 0
  Set-Reg "$cv\Explorer\Advanced" 'ShowTaskViewButton' 0
  Set-Reg "$cv\Explorer\Advanced" 'ShowCortanaButton' 0
  Set-Reg "$cv\Explorer\Advanced" 'HideFileExt' 0
  Set-Reg "$cv\Explorer\Advanced" 'LaunchTo' 1
  Set-Reg "$cv\Explorer\Advanced" 'Start_TrackDocs' 0
  Set-Reg "$cv\Explorer\Advanced\People" 'PeopleBand' 0
  Set-Reg "$cv\AdvertisingInfo" 'Enabled' 0
  Set-Reg "$cv\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0
  Set-Reg "$cv\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
  Set-Reg "$cv\GameDVR" 'AppCaptureEnabled' 0
  Remove-RegValue "$cv\Run" 'OneDriveSetup'
  Set-Reg 'NTUSER\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
  Set-Reg 'NTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
  Set-Reg 'NTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
  Set-Reg 'NTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
  # Game Mode on, Game Bar/DVR off, fullscreen exclusive honoured
  Set-Reg 'NTUSER\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
  Set-Reg 'NTUSER\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
  Set-Reg 'NTUSER\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
  Set-Reg 'NTUSER\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
  $gcs = 'NTUSER\System\GameConfigStore'
  Set-Reg $gcs 'GameDVR_Enabled' 0
  Set-Reg $gcs 'GameDVR_FSEBehaviorMode' 2
  Set-Reg $gcs 'GameDVR_FSEBehavior' 2
  Set-Reg $gcs 'GameDVR_HonorUserFSEBehaviorMode' 1
  Set-Reg $gcs 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
  Set-Reg $gcs 'GameDVR_EFSEFeatureFlags' 0
  # raw mouse: no pointer acceleration
  Set-Reg 'NTUSER\Control Panel\Mouse' 'MouseSpeed' '0'
  Set-Reg 'NTUSER\Control Panel\Mouse' 'MouseThreshold1' '0'
  Set-Reg 'NTUSER\Control Panel\Mouse' 'MouseThreshold2' '0'
  Set-Reg 'NTUSER\Control Panel\Desktop' 'MenuShowDelay' '0'

  # black everywhere: no wallpaper (the Web folder is removed), solid black desktop, dark mode, no lock screen,
  # black sign-in screen (C:\JDO\black.jpg)
  Set-Reg 'NTUSER\Control Panel\Desktop' 'Wallpaper' ''
  Set-Reg 'NTUSER\Control Panel\Desktop' 'WallpaperStyle' '0'
  Set-Reg 'NTUSER\Control Panel\Colors' 'Background' '0 0 0'
  Set-Reg 'DEFAULT\Control Panel\Colors' 'Background' '0 0 0'
  Set-Reg "$cv\Explorer\Wallpapers" 'BackgroundType' 1
  Set-Reg "$cv\Themes\Personalize" 'AppsUseLightTheme' 0
  Set-Reg "$cv\Themes\Personalize" 'SystemUsesLightTheme' 0
  Set-Reg "$cv\Themes\Personalize" 'EnableTransparency' 0
  Set-Reg "$pol\Personalization" 'NoLockScreen' 1
  Set-Reg "$pol\Personalization" 'LockScreenImage' 'C:\JDO\black.jpg'
  Set-Reg "$pol\Personalization" 'NoChangingLockScreen' 1
  Set-Reg "$pol\System" 'DisableAcrylicBackgroundOnLogon' 1

  # visual effects for performance (CTT "best performance", font smoothing kept so text stays readable)
  Set-Reg 'NTUSER\Control Panel\Desktop' 'DragFullWindows' '0'
  Set-Reg 'NTUSER\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))
  Set-Reg 'NTUSER\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0'
  Set-Reg 'NTUSER\Control Panel\Keyboard' 'KeyboardDelay' '0'
  Set-Reg "$cv\Explorer\Advanced" 'ListviewAlphaSelect' 0
  Set-Reg "$cv\Explorer\Advanced" 'ListviewShadow' 0
  Set-Reg "$cv\Explorer\Advanced" 'TaskbarAnimations' 0
  Set-Reg "$cv\Explorer\VisualEffects" 'VisualFXSetting' 3
  Set-Reg 'NTUSER\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
  # keyboard: NumLock on (sign-in screen too), Sticky / Filter / Toggle Keys shortcuts off (no popup on 5x Shift mid-game)
  Set-Reg 'NTUSER\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2'
  Set-Reg 'DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2'
  Set-Reg 'NTUSER\Control Panel\Accessibility\StickyKeys' 'Flags' '506'
  Set-Reg 'NTUSER\Control Panel\Accessibility\Keyboard Response' 'Flags' '122'
  Set-Reg 'NTUSER\Control Panel\Accessibility\ToggleKeys' 'Flags' '58'

  # the rest of Chris Titus' WinUtil tweaks that we did not have (network ones left out on purpose)
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption' 0
  Set-Reg 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0
  Set-Reg 'SYSTEM\Maps' 'AutoUpdateEnabled' 0
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
  Set-Reg 'SYSTEM\ControlSet001\Control\Session Manager\Environment' 'POWERSHELL_TELEMETRY_OPTOUT' '1'
  Set-Reg 'SYSTEM\ControlSet001\Control\Session Manager' 'DisableWpbtExecution' 1           # no firmware-injected apps
  Set-Reg "$pol\Device Metadata" 'PreventDeviceMetadataFromNetwork' 1
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
  Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' 'DisableCoInstallers' 1  # no Razer / vendor auto-installs
  Set-Reg 'SYSTEM\ControlSet001\Control\CrashControl' 'DisplayParameters' 1
  Set-Reg 'SYSTEM\ControlSet001\Control\CrashControl' 'DisableEmoticon' 1
  Set-Reg 'SYSTEM\ControlSet001\Control\FileSystem' 'LongPathsEnabled' 1
  Set-Reg 'NTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
  Set-Reg 'NTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 0
  Set-Reg 'NTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
  Set-Reg "$cv\Explorer\Advanced" 'Start_TrackProgs' 0
  Set-Reg "$cv\StorageSense\Parameters\StoragePolicy" '01' 0

  if ($Win11) {
    # taskbar: no Widgets (a WebView2 process tree), no Chat / Teams, no Copilot, no Task View; left-aligned so the
    # Start button sits where the Open-Shell menu opens
    Set-Reg "$cv\Explorer\Advanced" 'TaskbarDa' 0
    Set-Reg "$cv\Explorer\Advanced" 'TaskbarMn' 0
    Set-Reg "$cv\Explorer\Advanced" 'ShowCopilotButton' 0
    Set-Reg "$cv\Explorer\Advanced" 'TaskbarAl' 0
    Set-Reg "$cv\Explorer\Advanced" 'Start_IrisRecommendations' 0
    Set-Reg "$cv\Explorer\Advanced" 'Start_AccountNotifications' 0
    Set-Reg 'SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg "$pol\Windows Chat" 'ChatIcon' 3
    Set-Reg "$pol\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-Reg 'NTUSER\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    # the full right-click menu straight away (no "Show more options" step)
    Set-Reg 'NTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' ''
    # Smart App Control off: on a clean install it starts in evaluation mode and can block unsigned tools and installers
    Set-Reg 'SYSTEM\ControlSet001\Control\CI\Policy' 'VerifiedAndReputablePolicyState' 0
    # XdzlOS switched the UBPM trace session off; Task Scheduler's event triggers use it - back to the Windows value
    Set-Reg 'SYSTEM\ControlSet001\Control\WMI\Autologger\UBPM' 'Start' 1
    # network values XdzlOS changed (not part of JDO x QHT): back to how Windows ships them
    Remove-RegValue 'SYSTEM\ControlSet001\Services\Tcpip\Parameters' 'EnableICMPRedirect'
    Remove-RegValue 'SOFTWARE\Policies\Microsoft\Windows\Network Connections' 'NC_PersonalFirewallConfig'
  }

  Unload-Hives

  # ---------------- 6. shrink ----------------
  if (-not $NoSlim) {
    # Disabled features still carry their files (Hyper-V, IIS, WSL, Sandbox...). Removing the payload frees the space;
    # turning one of them on later needs the Windows ISO as source. NetFx4 and anything enabled stays.
    Step 'Slimming: removing payloads of disabled features'
    $off = @(Get-WindowsOptionalFeature -Path $mount | Where-Object { $_.State -eq 'Disabled' } | ForEach-Object { $_.FeatureName })
    try { Disable-WindowsOptionalFeature -Path $mount -FeatureName $off -Remove -ScratchDirectory $scr -ErrorAction Stop | Out-Null }
    catch {
      Write-Host '  all at once failed - one by one' -ForegroundColor DarkGray
      foreach ($f in $off) {
        try { Disable-WindowsOptionalFeature -Path $mount -FeatureName $f -Remove -ScratchDirectory $scr -ErrorAction Stop | Out-Null }
        catch { Write-Host "  kept $f" -ForegroundColor DarkGray }
      }
    }
    Write-Host "  $($off.Count) feature payloads removed"

    Step 'Slimming: WinRE, speech, Hello, CJK fonts, unused system apps, printer / modem drivers'
    $w = "$mount\Windows"
    $slim = @(
      "$w\System32\Recovery\Winre.wim"                  # recovery environment (repair from the ISO instead)
      "$w\Speech", "$w\Speech_OneCore", "$w\System32\Speech_OneCore", "$w\SysWOW64\Speech_OneCore"   # voices, Narrator
      "$w\System32\WinBioPlugIns\FaceDriver", "$w\System32\WinBioPlugIns\FaceRecoSensorAdapter"       # Windows Hello face
      "$w\Web"                                           # every wallpaper: the desktop is solid black
      "$w\Media"                                         # system sounds
      "$w\Containers"                                    # Windows Sandbox / container base files (feature removed)
      "$mount\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories\Snipping Tool.lnk"   # Snipping Tool (asked to remove)
    )
    # English + Arabic only: fonts for every other script go (CJK, Indic, Thai, Lao, Khmer, Myanmar, Ethiopic,
    # Cherokee, Mongolian, Tibetan, Yi, Thaana, Georgian / Armenian, Javanese, historic scripts...).
    # Latin, Arabic (Tahoma, Arial, Segoe UI, Simplified / Traditional Arabic, Sakkal Majalla...), symbols, emoji and icons stay.
    $slim += Get-ChildItem "$w\Fonts" -File | Where-Object { $_.Name -match '^(msyh|msjh|simsun|simsunb|mingliub|malgun|YuGoth|meiryo|msgothic|msmincho|simhei|kaiu|SimSun|mingliu|gulim|batang|Gungsuh|NotoSansCJK|YuMin|BIZ-UD|UDDigiKyokasho|Dengb?l?|FangSong|KaiTi|SimKai|STXIHEI|' +
                                                                       'Nirmala|Leelawad|LeelUI|gadugi|ebrima|himalaya|javatext|KhmerUI|LaoUI|monbaiti|mmrtext|msuighur|ntailu|phagspa|taile|sylfaen|msyi|mvboli|seguihis)' } | ForEach-Object { $_.FullName }
    # Chinese / Japanese / Korean input methods (the Arabic and English keyboards are plain layouts in System32)
    foreach ($ime in 'IMEJP', 'IMEKR', 'IMESC', 'IMETC') { $slim += "$w\IME\$ime", "$w\System32\IME\$ime", "$w\SysWOW64\IME\$ime" }
    foreach ($ime in 'CHS', 'CHT', 'JPN', 'KOR') { $slim += "$w\InputMethod\$ime" }
    $slim += Get-ChildItem "$w\System32", "$w\SysWOW64" -Recurse -Depth 1 -Filter 'SnippingTool.exe*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    # upgrade migration wizard (clean installs only), the rest of Windows Hello
    $slim += "$w\System32\migwiz", "$w\System32\WinBioPlugIns"
    # .NET native images: .NET apps run from IL instead (a second slower start, nothing else); NGEN tasks are off at first boot
    $slim += Get-ChildItem "$w\assembly" -Directory -Filter 'NativeImages_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    # system apps nothing here uses (Start menu search stays - it runs at idle priority, see the registry step)
    foreach ($a in 'Microsoft.Windows.ParentalControls_cw5n1h2txyewy', 'ParentalControls_cw5n1h2txyewy',
                   'Microsoft.Windows.PeopleExperienceHost_cw5n1h2txyewy', 'Microsoft.XboxGameCallableUI_cw5n1h2txyewy', 'Microsoft.ECApp_8wekyb3d8bbwe',
                   'Microsoft.Windows.CallingShellApp_cw5n1h2txyewy', 'microsoft.windows.narratorquickstart_8wekyb3d8bbwe',
                   'Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy', 'Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe',
                   'Microsoft.BioEnrollment_cw5n1h2txyewy', 'Microsoft.Windows.AssignedAccessLockApp_cw5n1h2txyewy',
                   'Microsoft.Windows.SecureAssessmentBrowser_cw5n1h2txyewy', 'Windows.CBSPreview_cw5n1h2txyewy') {
      $slim += "$w\SystemApps\$a"
    }
    if (-not $KeepDefender) {
      $slim += "$mount\Program Files\Windows Defender", "$mount\Program Files\Windows Defender Advanced Threat Protection",
               "$mount\Program Files (x86)\Windows Defender", "$mount\ProgramData\Microsoft\Windows Defender",
               "$w\SystemApps\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy"
    }
    # printers, modems, USB printers, sensors, smart cards, infrared, Hyper-V guest (storage / integration, not its network
    # adapter) - network drivers (wired, Wi-Fi, Bluetooth PAN, virtual) and controllers / HID are never touched
    $slim += Get-ChildItem "$w\System32\DriverStore\FileRepository" -Directory |
      Where-Object { $_.Name -match '^(prn|ntprint|mdm|usbprint|sensors|hidir|irda|scmbus|wudfusbcciddriver|wvmic|wstorvsc|wvid|wvpci|wvms_|vmbus|hyperv)' } |
      ForEach-Object { $_.FullName }
    $before = (Get-ChildItem $mount -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    foreach ($p in $slim) { Remove-Owned $p }
    $after = (Get-ChildItem $mount -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host ('  freed {0:N0} MB' -f (($before - $after) / 1MB))
  }

  $pruned = $false
  if (-not $NoSlim -and -not $KeepServicing) {
    # WinSxS holds a second copy of every component (Edge, Defender, Hello, fonts... stay in it after their System32 copy
    # is gone) - most of the ISO. Everything goes except the side-by-side assemblies programs load at run time
    # (common controls, GDI+, Visual C++ runtimes, policies) and their manifests. Files projected to System32 are hard
    # links, so they stay. After this the image cannot be serviced: no Windows Update / adding features or languages.
    Step 'Slimming: WinSxS - keeping only run-time side-by-side assemblies (takes a while)'
    $sxs = "$mount\Windows\WinSxS"
    & takeown.exe /f $sxs /r /a /d y | Out-Null
    & icacls.exe $sxs /grant '*S-1-5-32-544:F' /t /c /q | Out-Null
    $before = (Get-ChildItem $mount -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    # The servicing stack stays too (newest version of each part): Windows Setup runs the offlineServicing pass with it
    # while installing, and without it setup stops with "could not apply unattend settings during pass
    # [offlineServicing]" (found by the VM install test). The Manifests folder stays whole: the stack reads it.
    $stackRx = '^(amd64|x86|wow64)_microsoft-windows-(servicingstack|s\.\.ngstack|s\.\.stack)'
    $stack = Get-ChildItem -LiteralPath $sxs -Directory -Force | Where-Object { $_.Name -match $stackRx } |
      Group-Object { ($_.Name -split '_')[0..1] -join '_' } |
      ForEach-Object { $_.Group | Sort-Object { [version](($_.Name -split '_')[3]) } -Descending | Select-Object -First 1 } |
      ForEach-Object { $_.Name }
    Write-Host "  servicing stack kept: $($stack.Count) folders"
    $gone = 0
    foreach ($d in Get-ChildItem -LiteralPath $sxs -Force) {
      if ($d.Name -match $keepSxs -or $stack -contains $d.Name) { continue }
      Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue; $gone++
    }
    $after = (Get-ChildItem $mount -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host ('  {0} WinSxS entries removed, freed {1:N0} MB (hard links counted)' -f $gone, (($before - $after) / 1MB))
    $pruned = $true
  }

  if ($pruned) { Step 'Component store cleanup: not needed (WinSxS was pruned)' } else {
  Step 'Component store cleanup (/ResetBase) - this takes a while'
  # CBS needs NTFS compression; tweak packs turn it off machine-wide (fsutil behavior set disablecompression 1).
  # Then the cleanup runs on the new PC at first boot instead (smaller install, ISO a bit bigger).
  # (The registry value can say "on" before the restart that applies it, so just try: 769 = ERROR_COMPRESSION_DISABLED.)
  & dism.exe "/Image:$mount" /Cleanup-Image /StartComponentCleanup /ResetBase "/ScratchDir:$scr"
  if ($LASTEXITCODE -eq 769) {
    Write-Host '  NTFS compression is off on this PC - cleanup moved to first boot. For the smallest ISO run' -ForegroundColor Yellow
    Write-Host '  "fsutil behavior set disablecompression 0", restart, and build again.' -ForegroundColor Yellow
    New-Item -ItemType File "$mount\Windows\Setup\Scripts\cleanup-at-first-boot" -Force | Out-Null
  } elseif ($LASTEXITCODE -ne 0) { throw "DISM component cleanup failed ($LASTEXITCODE)" }
  }
  $used =(Get-ChildItem $mount -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  Write-Host ('  files in the image: {0:N2} GB (hard links counted more than once)' -f ($used / 1GB))
  Step 'Saving the image'
  Dismount-WindowsImage -Path $mount -Save -ScratchDirectory $scr | Out-Null

  Step 'Compressing to install.esd (recovery compression) - this takes a while'
  & dism.exe /Export-Image "/SourceImageFile:$wim" /SourceIndex:1 "/DestinationImageFile:$src\sources\install.esd" /Compress:recovery /CheckIntegrity "/ScratchDir:$scr"
  if ($LASTEXITCODE -ne 0) { throw "DISM export failed ($LASTEXITCODE)" }
  Remove-Item -LiteralPath $wim -Force
  Copy-Item "$files\autounattend.xml" "$src\" -Force
  Write-Host ('  install.esd: {0:N2} GB' -f ((Get-Item "$src\sources\install.esd").Length / 1GB))

  if (-not $NoSlim) {
    # boot.wim: only the Setup image (index 2) - the WinPE image (index 1) is never used when installing from USB
    Step 'Slimming the ISO: setup-only boot.wim, setup files that only an in-place upgrade uses'
    $bw = Join-Path $Work 'boot.wim'
    if (Test-Path $bw) { Remove-Item -LiteralPath $bw -Force }
    if ((Get-WindowsImage -ImagePath "$src\sources\boot.wim").Count -gt 1) {
      & dism.exe /Export-Image "/SourceImageFile:$src\sources\boot.wim" /SourceIndex:2 "/DestinationImageFile:$bw" /Compress:max /Bootable
      if ($LASTEXITCODE -ne 0) { throw "boot.wim export failed ($LASTEXITCODE)" }
      Move-Item -LiteralPath $bw "$src\sources\boot.wim" -Force
    }
    Slim-BootWim
    # booting the USB runs Setup from inside boot.wim; the rest of \sources is for upgrading from a running Windows
    Get-ChildItem "$src\sources" -Force | Where-Object { $_.Name -notin 'boot.wim', 'install.esd', 'setup.exe' } |
      Remove-Item -Recurse -Force
    foreach ($f in 'support', 'boot\fonts\chs_boot.ttf', 'boot\fonts\cht_boot.ttf', 'boot\fonts\jpn_boot.ttf', 'boot\fonts\kor_boot.ttf',
                   'efi\microsoft\boot\fonts\chs_boot.ttf', 'efi\microsoft\boot\fonts\cht_boot.ttf', 'efi\microsoft\boot\fonts\jpn_boot.ttf',
                   'efi\microsoft\boot\fonts\kor_boot.ttf') {
      if (Test-Path "$src\$f") { Remove-Item -LiteralPath "$src\$f" -Recurse -Force }
    }
    Write-Host ('  boot.wim: {0:N0} MB' -f ((Get-Item "$src\sources\boot.wim").Length / 1MB))
  }
}
catch {
  Write-Host "Build failed: $($_.Exception.Message)" -ForegroundColor Red
  Unload-Hives
  if (Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mount }) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
  Stop-Transcript | Out-Null
  throw
}
}

if ($SkipIso) { Step "Done (no ISO). Folder: $src"; Stop-Transcript | Out-Null; return }

# ---------------- 6b. the name in the boot menus of the ISO (BIOS + UEFI) ----------------
foreach ($b in "$src\boot\bcd", "$src\efi\microsoft\boot\bcd") {
  if (-not (Test-Path $b)) { continue }
  foreach ($id in '{default}', '{bootmgr}') { & bcdedit.exe /store $b /set $id description 'JDO x QHT Setup' 2>$null | Out-Null }
  foreach ($line in (& bcdedit.exe /store $b /enum all) | Where-Object { $_ -match '^description\s' }) { }
  Write-Host "  boot menu name set in $b"
}

# ---------------- 7. ISO (IMAPI2, BIOS + UEFI) ----------------
Step "Building $Out"
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class JdoIso
{
    // PowerShell cannot pass an object[] as the SAFEARRAY this property wants; late-bound from C# it can.
    public static void SetBootImages(object fsi, object bios, object uefi)
    {
        fsi.GetType().InvokeMember("BootImageOptionsArray", System.Reflection.BindingFlags.SetProperty, null, fsi,
                                   new object[] { new object[] { bios, uefi } });
    }

    public static void Write(string path, object stream, int blockSize, int totalBlocks)
    {
        IStream s = (IStream)stream;
        byte[] buf = new byte[blockSize];
        IntPtr read = Marshal.AllocHGlobal(4);
        try
        {
            using (FileStream f = File.Create(path))
                for (int i = 0; i < totalBlocks; i++) { s.Read(buf, blockSize, read); f.Write(buf, 0, Marshal.ReadInt32(read)); }
        }
        finally { Marshal.FreeHGlobal(read); }
    }
}
'@
function Boot-Image([string]$File, [int]$Platform) {
  $st = New-Object -ComObject ADODB.Stream
  $st.Open(); $st.Type = 1; $st.LoadFromFile($File)
  $b = New-Object -ComObject IMAPI2FS.BootOptions
  $b.AssignBootImage($st.psobject.BaseObject)
  $b.PlatformId = $Platform   # 0 = BIOS, 0xEF = UEFI
  $b.Emulation = 0
  $b
}
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.ChooseImageDefaultsForMediaType(18)   # BD-R: no 4.7 GB cap
$fsi.FileSystemsToCreate = 4               # UDF, like oscdimg -u2
$fsi.UDFRevision = 0x102
$fsi.VolumeName = 'JDO_x_QHT'
$bios = Boot-Image "$src\boot\etfsboot.com" 0
$uefi = Boot-Image "$src\efi\microsoft\boot\efisys.bin" 0xEF
[JdoIso]::SetBootImages($fsi, $bios, $uefi)
$fsi.Root.AddTree($src, $false)
$res = $fsi.CreateResultImage()
if (Test-Path $Out) { Remove-Item -LiteralPath $Out -Force }
[JdoIso]::Write($Out, $res.ImageStream, $res.BlockSize, $res.TotalBlocks)
Step ('Done: {0} ({1:N2} GB)' -f $Out, ((Get-Item $Out).Length / 1GB))
Stop-Transcript | Out-Null
