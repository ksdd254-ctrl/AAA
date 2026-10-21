# JDO Lite Windows - tools menu (C:\JDO, shortcut on the desktop)
# Fixes, app slimming, and on/off switches for everything the lite build turned off.
# Works on any Windows 10 too (the repair options restore stock Windows values).
# Rule: nothing here touches hardware serials / IDs, the MAC, or anything network (settings, services, adapters,
# drivers, Wi-Fi, firewall). Network stays exactly as Windows ships it.
#   JDO-Tools.ps1            menu
#   JDO-Tools.ps1 -Devices   disable unneeded devices + USB power saving off, no questions (first boot runs this)
#   JDO-Tools.ps1 -Power     create and switch to the JDO Ultimate power plan, no questions (first boot runs this)
#   JDO-Tools.ps1 -Services  Windows Update / Store / account services off once setup is done (first boot runs this)
param([switch]$Devices, [switch]$Power, [switch]$Services)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
  if ($Devices) { $a += ' -Devices' }
  if ($Power) { $a += ' -Power' }
  if ($Services) { $a += ' -Services' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $a
  return
}

# Registry writes through SeRestorePrivilege, so protected service keys (Schedule, TimeBrokerSvc, WinDefend,
# WaaSMedicSvc...) can be put back to their Windows values too.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class JdoReg
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
    static extern int RegOpenKeyEx(UIntPtr key, string subKey, int options, int sam, out UIntPtr result);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegCreateKeyEx(UIntPtr key, string subKey, int reserved, string cls, int options, int sam, IntPtr security, out UIntPtr result, out int disposition);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegSetValueEx(UIntPtr key, string name, int reserved, int type, byte[] data, int size);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegDeleteTree(UIntPtr key, string subKey);
    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(UIntPtr key);

    static readonly UIntPtr HKLM = new UIntPtr(0x80000002u);

    static JdoReg()
    {
        IntPtr token;
        OpenProcessToken(GetCurrentProcess(), 0x28, out token);
        // Restore only: with SeBackupPrivilege also on, REG_OPTION_BACKUP_RESTORE opens keys read-only
        foreach (string p in new[] { "SeRestorePrivilege" })
        {
            TokenPrivileges tp = new TokenPrivileges();
            tp.Count = 1; tp.Attributes = 2;
            LookupPrivilegeValue(null, p, out tp.Luid);
            AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
    }

    public static bool Exists(string sub)
    {
        UIntPtr h;
        if (RegOpenKeyEx(HKLM, sub, 0, 0x20019, out h) != 0) return false;
        RegCloseKey(h);
        return true;
    }

    // Normal open first (a backup/restore handle on a key it has just created cannot set values);
    // REG_OPTION_BACKUP_RESTORE only when the key's ACL denies us.
    static UIntPtr Open(string sub)
    {
        UIntPtr h; int disp;
        int rc = RegCreateKeyEx(HKLM, sub, 0, null, 0, 0xF003F /* KEY_ALL_ACCESS */, IntPtr.Zero, out h, out disp);
        if (rc == 5)
        {
            rc = RegCreateKeyEx(HKLM, sub, 0, null, 4 /* REG_OPTION_BACKUP_RESTORE */, 0, IntPtr.Zero, out h, out disp);
            // a key it has just created comes back without write access: reopen it now that it exists
            if (rc == 0 && disp == 1 /* REG_CREATED_NEW_KEY */)
            {
                RegCloseKey(h);
                rc = RegCreateKeyEx(HKLM, sub, 0, null, 4, 0, IntPtr.Zero, out h, out disp);
            }
        }
        return rc == 0 ? h : UIntPtr.Zero;
    }

    // type: 3 binary, 4 dword, 7 multi-string (data already encoded)
    public static bool Set(string sub, string name, int type, byte[] data)
    {
        UIntPtr h = Open(sub);
        if (h == UIntPtr.Zero) return false;
        try { return RegSetValueEx(h, name, 0, type, data, data.Length) == 0; }
        finally { RegCloseKey(h); }
    }

    public static bool DeleteChild(string sub, string child)
    {
        if (!Exists(sub + "\\" + child)) return true;
        UIntPtr h = Open(sub);
        if (h == UIntPtr.Zero) return false;
        try { return RegDeleteTree(h, child) == 0; }
        finally { RegCloseKey(h); }
    }

    public static bool SetStart(string service, uint start)
    {
        string sub = @"SYSTEM\CurrentControlSet\Services\" + service;
        return Exists(sub) && Set(sub, "Start", 4, BitConverter.GetBytes(start));
    }
}
'@

function Set-Services([hashtable]$Map) {
  foreach ($s in $Map.Keys) {
    if ([JdoReg]::SetStart($s, [uint32]$Map[$s])) { Write-Host "  $s -> $($Map[$s])" } else { Write-Host "  $s (not here)" -ForegroundColor DarkGray }
  }
}
function Set-Dword([string]$Key, [string]$Name, $Value) {
  if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
  if ($null -eq $Value) { Remove-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -Path $Key -Name $Name -Value $Value -Type DWord }
}
function Set-Policy([string]$Key, [string]$Name, $Value) { Set-Dword $Key $Name $Value }
function Done([bool]$Reboot) { if ($Reboot) { Write-Host 'Restart the PC to finish.' -ForegroundColor Yellow } else { Write-Host 'Done.' -ForegroundColor Green } }

# ---------------- devices ----------------
# Same list that was already disabled on the owner's PC (minus anything network), plus Bluetooth and the unused Ryzen
# iGPU. Matched by hardware ID prefix, so on other hardware only the generic entries apply.
# Never touched: network adapters (wired, Wi-Fi, virtual), cameras, controllers, keyboards, mice, audio.
$deviceIds = @(
  'ROOT\CompositeBus', 'ROOT\RDPBUS', 'ROOT\UMBUS', 'ROOT\vdrvroot',
  'ACPI\VEN_ACPI&DEV_000C',   # ACPI Processor Aggregator
  'ACPI\VEN_PNP&DEV_0100',    # System timer
  'ACPI\VEN_PNP&DEV_0103',    # High precision event timer
  'ACPI\VEN_PNP&DEV_0200',    # Direct memory access controller
  'ACPI\VEN_PNP&DEV_0501',    # COM1
  'ACPI\VEN_PNP&DEV_0800',    # System speaker
  'ACPI\VEN_PNP&DEV_0C01',    # System board
  'ACPI\VEN_PNP&DEV_0C02',    # Motherboard resources
  'ACPI\VEN_PNP&DEV_0C14',    # WMI for ACPI
  'PCI\VEN_1022&DEV_790B',    # AMD SM Bus (no driver)
  'PCI\VEN_1002&DEV_164E',    # Ryzen 7000 iGPU (the NVIDIA card is used)
  'USB\VID_0E8D&PID_0616',    # MediaTek Bluetooth
  # keyboard / headset / mouse extra HID collections (media keys, vendor software) - not game controllers
  'HID\VID_03F0&PID_089D&REV_4100&MI_03&Col01', 'HID\VID_03F0&PID_089D&REV_4100&MI_03&Col04',
  'HID\VID_0C45&PID_80B1&REV_0111&MI_01&Col01', 'HID\VID_0C45&PID_80B1&REV_0111&MI_02', 'HID\VID_0C45&PID_80B1&REV_0111&MI_03',
  'HID\VID_373E&PID_0047&REV_0200&MI_01&Col01', 'HID\VID_373E&PID_0047&REV_0200&MI_01&Col04',
  'HID\VID_373E&PID_0047&REV_0200&MI_01&Col05', 'HID\VID_373E&PID_0047&REV_0200&MI_02'
)
function Get-JdoDevices {
  $all = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
  $hit = foreach ($d in $all) {
    if ($d.Class -eq 'Net') { continue }   # network adapters: never
    $ids = @($d.HardwareID)
    if ($ids | Where-Object { $i = $_; $deviceIds | Where-Object { $i -like "$_*" } }) { $d; continue }
    if ($d.Class -eq 'Bluetooth') { $d; continue }
  }
  # a second "Microsoft Basic Display Adapter" only once a real GPU driver is installed
  $real = $all | Where-Object { $_.Class -eq 'Display' -and $_.FriendlyName -notmatch 'Basic Display' -and $_.Status -eq 'OK' }
  if ($real) { $hit += $all | Where-Object { $_.Class -eq 'Display' -and $_.FriendlyName -match 'Basic Display' } }
  $hit | Where-Object { $_ } | Sort-Object InstanceId -Unique
}

function Disable-Devices {
  Write-Host 'Disabling unneeded devices' -ForegroundColor Cyan
  foreach ($d in Get-JdoDevices) {
    if ($d.Status -eq 'Error' -and $d.ConfigManagerErrorCode -eq 22) { continue }   # already off
    try { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; Write-Host "  off  $($d.FriendlyName)" }
    catch { Write-Host "  skip $($d.FriendlyName)" -ForegroundColor DarkGray }
  }
  Write-Host 'USB / device power saving off' -ForegroundColor Cyan
  # "Allow the computer to turn off this device to save power" - unticked for every device that has it,
  # except network adapters (their power settings are network settings and stay at the default)
  $net = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | ForEach-Object { $_.InstanceId.ToUpper() })
  # timeouts: on some hardware (and in VMs) a device never answers and the WMI call would wait forever
  Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -OperationTimeoutSec 20 -ErrorAction SilentlyContinue | Where-Object { $_.Enable } |
    Where-Object { $id = ($_.InstanceName -replace '_\d+$', '').ToUpper(); $net -notcontains $id } |
    ForEach-Object { Set-CimInstance -InputObject $_ -Property @{ Enable = $false } -OperationTimeoutSec 10 -ErrorAction SilentlyContinue }
  foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue | Get-ChildItem -ErrorAction SilentlyContinue) {
    if ($net -contains ($k.Name -replace '^.*\\Enum\\', '').ToUpper()) { continue }
    $p = Join-Path $k.PSPath 'Device Parameters'
    if (Test-Path $p) {
      foreach ($n in 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'SelectiveSuspendEnabled', 'DeviceSelectiveSuspended') {
        Set-ItemProperty -Path $p -Name $n -Value 0 -Type DWord -ErrorAction SilentlyContinue
      }
    }
  }
  # USB selective suspend and PCIe link power off in the active plan
  $plan = (powercfg /getactivescheme) -replace '^.*:\s*([0-9a-f-]{36}).*$', '$1'
  powercfg /setacvalueindex $plan 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
  powercfg /setacvalueindex $plan 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null
  powercfg /setactive $plan | Out-Null
}

function Enable-Devices {
  foreach ($d in Get-JdoDevices) {
    try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; Write-Host "  on   $($d.FriendlyName)" } catch { }
  }
}

# ---------------- power plan ----------------
# JDO Ultimate: a copy of Ultimate Performance pushed to full speed. The CPU's idle states stay ON on purpose: with them
# off (the usual "idle disable" tweak) Task Manager shows 100 % even when the game uses 30 %, the CPU runs hot and loses
# boost clocks. Here usage is the real number, and every core is awake at full clock the moment the game asks.
function Set-JdoPowerPlan {
  Write-Host 'Power plan: JDO Ultimate' -ForegroundColor Cyan
  $jdo = '4a444f00-0000-4000-8000-00000000c0de'
  if (-not (powercfg /list | Select-String $jdo)) { powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $jdo | Out-Null }
  powercfg -changename $jdo 'JDO Ultimate' 'JDO Lite Windows - full speed, real CPU usage' | Out-Null
  $sub = @{ cpu = '54533251-82be-4824-96c1-47b60b740d00'; usb = '2a737441-1930-4402-8d77-b2bebba308a3'; pci = '501a4d13-42af-4429-9fd1-a8218c268e20'
            disk = '0012ee47-9041-4b5d-9b77-535fba8b1442'; sleep = '238c9fa8-0aad-41ed-83f4-97be242c8f20' }
  $set = @(
    @($sub.cpu, '893dee8e-2bef-41e0-89c6-b55d0929964c', 100),   # minimum processor state 100 %
    @($sub.cpu, 'bc5038f7-23e0-4960-96da-33abaf5935ec', 100),   # maximum processor state 100 %
    @($sub.cpu, '0cc5b647-c1df-4637-891a-dec35c318583', 100),   # core parking: every core always available
    @($sub.cpu, 'ea062031-0e34-4ff1-9b6d-eb1059334028', 100),
    @($sub.cpu, 'be337238-0d82-4146-a960-4f3749d470c7', 2),     # boost mode: aggressive
    @($sub.cpu, '36687f9e-e3a5-4dbf-b1dc-15eb381c6863', 0),     # energy preference: maximum performance
    @($sub.cpu, '5d76a2ca-e8c0-402f-a133-2158492d58ad', 0),     # idle states ON (real usage, keeps boost headroom)
    @($sub.cpu, '94d3a615-a899-4ac5-ae2b-e4d8f634367f', 1),     # cooling: active (fans before throttling)
    @($sub.usb, '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0),     # USB selective suspend off
    @($sub.pci, 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0),     # PCIe link power management off
    @($sub.disk, '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0),    # disks never turn off
    @($sub.sleep, '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 0),   # never sleep
    @($sub.sleep, '9d7815a6-7ee4-497e-8888-515a05f02364', 0),   # never hibernate
    @($sub.sleep, 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d', 0)    # no wake timers
  )
  foreach ($s in $set) {
    powercfg -attributes $s[0] $s[1] -ATTRIB_HIDE 2>$null | Out-Null   # show it in Power Options too
    powercfg -setacvalueindex $jdo $s[0] $s[1] $s[2] 2>$null | Out-Null
    powercfg -setdcvalueindex $jdo $s[0] $s[1] $s[2] 2>$null | Out-Null
  }
  powercfg -setactive $jdo | Out-Null
  powercfg -h off | Out-Null
  Write-Host "  active: $((powercfg /getactivescheme) -replace '^.*\((.*)\).*$', '$1')" -ForegroundColor Green
}

if ($Power) { Set-JdoPowerPlan; return }
# Setup's OOBE needs these, so the image keeps them stock and first boot turns them off afterwards
$lateOff = @{ wuauserv=4; UsoSvc=4; WaaSMedicSvc=4; wlidsvc=4; InstallService=4; PushToInstall=4 }
if ($Services) {
  Write-Host 'Windows Update / Store / account services off' -ForegroundColor Cyan
  Set-Services $lateOff
  Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
  Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
  return
}
if ($Devices) { Disable-Devices; return }

# ---------------- repairs ----------------
function Repair-TaskScheduler {
  Write-Host 'Task Scheduler: full repair (Windows 10 defaults)' -ForegroundColor Cyan
  $svc = 'SYSTEM\CurrentControlSet\Services\'
  $sch = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule'
  $backup = Join-Path $root ('Backup\TaskScheduler-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force $backup | Out-Null
  reg export 'HKLM\SYSTEM\CurrentControlSet\Services\Schedule' "$backup\Schedule-service.reg" /y | Out-Null
  reg export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule' "$backup\Schedule-tasks.reg" /y | Out-Null
  Write-Host "  backup: $backup"

  # 1. service config. Tweak packs make it trigger-start (it starts, finds nothing to do and shuts down - event 402),
  #    cut its restart-on-failure, or disable Time Broker / System Events Broker that it depends on.
  Write-Host ('  start trigger removed: ' + [JdoReg]::DeleteChild($svc + 'Schedule', 'TriggerInfo'))
  [byte[]]$fa = 128,81,1,0,0,0,0,0,0,0,0,0,3,0,0,0,20,0,0,0,1,0,0,0,96,234,0,0,1,0,0,0,96,234,0,0,1,0,0,0,96,234,0,0
  Write-Host ('  restart on failure: ' + [JdoReg]::Set($svc + 'Schedule', 'FailureActions', 3, $fa))
  [void][JdoReg]::Set($svc + 'Schedule', 'ImagePath', 2, [Text.Encoding]::Unicode.GetBytes("%systemroot%\system32\svchost.exe -k netsvcs -p`0"))
  [void][JdoReg]::Set($svc + 'Schedule', 'DependOnService', 7, [Text.Encoding]::Unicode.GetBytes("RPCSS`0SystemEventsBroker`0`0"))
  [void][JdoReg]::Set($svc + 'Schedule\Parameters', 'ServiceDll', 2, [Text.Encoding]::Unicode.GetBytes("%systemroot%\system32\schedsvc.dll`0"))
  Set-Services @{ Schedule=2; TimeBrokerSvc=3; SystemEventsBroker=2; BrokerInfrastructure=2; EventLog=2; RpcSs=2; RpcEptMapper=2; DcomLaunch=2; EventSystem=2 }
  foreach ($n in 'Schedule', 'TimeBrokerSvc', 'SystemEventsBroker', 'BrokerInfrastructure', 'RpcSs') {
    [void][JdoReg]::Set($svc + $n, 'MitigationFlags', 4, [BitConverter]::GetBytes([uint32]1))
  }
  [void][JdoReg]::Set($svc + 'UserManager', 'DependOnService', 7, [Text.Encoding]::Unicode.GetBytes("RpcSs`0ProfSvc`0`0"))
  # Schedule must be listed in the netsvcs svchost group
  $host32 = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost'
  $ns = @((Get-ItemProperty $host32 -Name netsvcs).netsvcs)
  if ($ns -notcontains 'Schedule') { Set-ItemProperty $host32 -Name netsvcs -Value ($ns + 'Schedule') -Type MultiString; Write-Host '  added to netsvcs group' }

  # 2. policies that block creating, deleting or running tasks
  foreach ($p in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Task Scheduler5.0', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Task Scheduler',
                 'HKCU:\Software\Policies\Microsoft\Windows\Task Scheduler5.0') {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Host "  removed policy $p" }
  }

  # 3. task store: the Tasks folder and the registry cache must match. Tweak packs delete task files but leave the cache,
  #    which gives "The task image is corrupt or has been tampered with" (0x80041321) and stops the console listing tasks.
  $tasksDir = "$env:WINDIR\System32\Tasks"
  if (-not (Test-Path $tasksDir)) { New-Item -ItemType Directory $tasksDir | Out-Null; Write-Host '  Tasks folder re-created' }
  $removed = 0
  foreach ($t in Get-ChildItem "$sch\TaskCache\Tree" -Recurse -ErrorAction SilentlyContinue) {
    $id = (Get-ItemProperty $t.PSPath -Name Id -ErrorAction SilentlyContinue).Id
    if (-not $id) { continue }   # a folder, not a task
    $rel = $t.Name.Substring($t.Name.IndexOf('\Tree\') + 6)
    if (Test-Path (Join-Path $tasksDir $rel)) { continue }
    foreach ($k in "$sch\TaskCache\Tasks\$id", "$sch\TaskCache\Plain\$id", "$sch\TaskCache\Logon\$id", "$sch\TaskCache\Boot\$id", $t.PSPath) {
      if (Test-Path $k) { Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $removed++
  }
  Write-Host "  broken task entries removed: $removed"

  # 4. its files, logging, and start
  foreach ($f in 'schedsvc.dll', 'taskschd.dll', 'taskcomp.dll', 'schtasks.exe', 'taskeng.exe') {
    if (-not (Test-Path "$env:WINDIR\System32\$f")) { Write-Host "  missing $f - running SFC" -ForegroundColor Yellow; sfc /scanfile="$env:WINDIR\System32\$f" | Out-Host }
  }
  wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
  Start-Service RpcSs, SystemEventsBroker -ErrorAction SilentlyContinue
  Start-Service Schedule -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 4
  $st = (Get-Service Schedule).Status
  Write-Host "  Task Scheduler is $st" -ForegroundColor $(if ($st -eq 'Running') { 'Green' } else { 'Yellow' })
  if ($st -eq 'Running') {
    $n = (Get-ScheduledTask -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "  tasks readable: $n"
  } else {
    Write-Host '  It starts after the restart. If not, send C:\JDO\Backup and the TaskScheduler event log.' -ForegroundColor Yellow
  }
  Done ($st -ne 'Running')
}

function Repair-Admin {
  Write-Host 'Run as administrator / UAC' -ForegroundColor Cyan
  # "Run as administrator" needs Application Information (Appinfo) and UAC (EnableLUA). With EnableLUA 0, packaged apps
  # and the NVIDIA Control Panel stop opening too. Prompts stay off (ConsentPromptBehaviorAdmin 0).
  Set-Services @{ Appinfo=3; seclogon=3; ProfSvc=2; UserManager=2; gpsvc=2 }
  $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  Set-Dword $sys 'EnableLUA' 1
  Set-Dword $sys 'ConsentPromptBehaviorAdmin' 0
  Set-Dword $sys 'ConsentPromptBehaviorUser' 3
  Set-Dword $sys 'PromptOnSecureDesktop' 0
  Set-Dword $sys 'ValidateAdminCodeSignatures' 0
  Set-Dword $sys 'EnableInstallerDetection' 1
  Set-Dword $sys 'EnableSecureUIAPaths' 1
  Set-Dword $sys 'EnableVirtualization' 1
  # the "runas" verb for programs and scripts
  foreach ($c in 'exefile', 'batfile', 'cmdfile', 'mscfile') {
    $k = "Registry::HKEY_CLASSES_ROOT\$c\shell\runas"
    if (Test-Path $k) { Remove-ItemProperty -Path $k -Name 'ProgrammaticAccessOnly', 'LegacyDisable' -ErrorAction SilentlyContinue }
  }
  Start-Service Appinfo -ErrorAction SilentlyContinue
  $u = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  Write-Host "  $u is in Administrators: $((Get-LocalGroupMember -SID S-1-5-32-544 -ErrorAction SilentlyContinue).Name -contains $u)"
  Done $true
}

function Repair-Nvidia {
  Write-Host 'NVIDIA Control Panel / NVIDIA App' -ForegroundColor Cyan
  # The DCH Control Panel is a packaged app the driver installs (no Store needed: AppX + licensing services do it) and
  # the NVIDIA App uses scheduled tasks + its containers; all of them need UAC on, Task Scheduler and the NVIDIA services.
  Set-Services @{ AppXSvc=3; ClipSVC=3; LicenseManager=3; StateRepository=3 }
  Repair-TaskScheduler
  Set-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 1
  foreach ($s in Get-Service -Name 'NVDisplay.ContainerLocalSystem', 'NvContainerLocalSystem', 'NvContainerNetworkService' -ErrorAction SilentlyContinue) {
    Set-Service $s.Name -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service $s.Name -ErrorAction SilentlyContinue
    Write-Host "  $($s.Name): $((Get-Service $s.Name).Status)"
  }
  # Control Panel on the desktop right-click menu and in the tray
  Set-Dword 'HKCU:\Software\NVIDIA Corporation\Global\NvCplApi\Policies' 'ContextUIPolicy' 2
  Set-Dword 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvCplApi\Policies' 'ContextUIPolicy' 2
  $cpl = Get-AppxPackage -AllUsers -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue
  if ($cpl) {
    $cpl | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $_.InstallLocation 'AppXManifest.xml') -ErrorAction SilentlyContinue }
    Write-Host '  Control Panel re-registered'
  } else {
    Write-Host '  Control Panel is not installed. Run the NVIDIA driver installer again (it installs it with the driver),' -ForegroundColor Yellow
    Write-Host '  or get it from the Store: the Store comes back for a moment, you install the Control Panel, then 19 removes the Store again.' -ForegroundColor Yellow
    if ((Read-Host '  Put the Store back now and open the NVIDIA Control Panel page? 1 = yes') -eq '1') {
      Install-Store
      Start-Process 'ms-windows-store://pdp/?ProductId=9NF8H0H7WMLT'
      Write-Host '  After it installs: JDO-Tools > 19 removes the Store again (the Control Panel stays).' -ForegroundColor Green
    }
  }
  Done $true
}

function Repair-Webcam {
  Write-Host 'Webcam (streaming apps)' -ForegroundColor Cyan
  Set-Services @{ FrameServer=3; FrameServerMonitor=3; camsvc=3 }
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged') {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name Value -Value 'Allow'
  }
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name 'LetAppsAccessCamera' -ErrorAction SilentlyContinue
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Camera' -Name 'AllowCamera' -ErrorAction SilentlyContinue
  Get-PnpDevice -Class Camera, Image -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' } |
    ForEach-Object { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "  on   $($_.FriendlyName)" }
  Done $false
}

# ---------------- Microsoft Store + Xbox: put back / take away ----------------
# The build keeps an unregistered copy of the Store, its purchase app, App Installer, Xbox sign-in and their frameworks
# in C:\JDO\Store, so this works offline. Everything is put back exactly as Windows ships it (services too).
$storeApps = '^Microsoft\.(WindowsStore|StorePurchaseApp|DesktopAppInstaller|XboxIdentityProvider|Xbox\.TCUI|GamingApp|GamingServices|XboxGamingOverlay|XboxGameOverlay|XboxSpeechToTextOverlay|XboxApp)$'

function Install-Store {
  Write-Host 'Microsoft Store + Xbox: back to the Windows defaults' -ForegroundColor Cyan
  Set-Services @{ InstallService=3; PushToInstall=3; wlidsvc=3; wuauserv=3; BITS=3; ClipSVC=3; LicenseManager=3; TokenBroker=3
                  AppXSvc=3; StorSvc=3; StateRepository=3; XblAuthManager=3; XblGameSave=3; XboxGipSvc=3 }
  Set-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 1
  fsutil behavior set disableencryption 0 | Out-Null     # packaged apps fail to install when NTFS encryption is off
  $dir = Join-Path $root 'Store'
  $pk = @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'AppxManifest.xml') })
  if (-not $pk) { Write-Host '  no saved copy in C:\JDO\Store' -ForegroundColor Yellow }
  # frameworks, then the apps, then their language / scale resource parts
  $order = { if ($_.Name -match 'VCLibs|NET\.Native|UI\.Xaml') { 0 } elseif ($_.Name -match '_split\.|_neutral_split') { 2 } else { 1 } }
  foreach ($p in $pk | Sort-Object $order, Name) {
    $m = Join-Path $p.FullName 'AppxManifest.xml'
    try { Add-AppxPackage -Register $m -DisableDevelopmentMode -ForceApplicationShutdown -ErrorAction Stop; Write-Host "  installed $($p.Name)" }
    catch {
      # some builds only accept a loose folder as a provisioned package
      & dism.exe /Online /Add-ProvisionedAppxPackage "/FolderPath:$($p.FullName)" /SkipLicense /Quiet | Out-Null
      if ($LASTEXITCODE -eq 0) { Write-Host "  provisioned $($p.Name)" } else { Write-Host "  could not add $($p.Name): $($_.Exception.Message)" -ForegroundColor DarkGray }
    }
  }
  if (-not (Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue)) {
    Write-Host '  Store not registered from the copy - asking Windows to reinstall it (needs internet)' -ForegroundColor Yellow
    Start-Process wsreset.exe -ArgumentList '-i' -Wait
  }
  $ok = [bool](Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue)
  Write-Host "  Microsoft Store: $(if ($ok) { 'installed' } else { 'not installed yet - restart and run 18 again' })" -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
  Write-Host '  For Game Pass: open the Store and install "Xbox" (it adds Gaming Services).'
  Done $true
}

function Remove-Store {
  Write-Host 'Microsoft Store + Xbox: removing (other apps you installed from it stay)' -ForegroundColor Cyan
  Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $storeApps } |
    ForEach-Object { try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; Write-Host "  removed $($_.Name)" } catch { Write-Host "  kept $($_.Name): $($_.Exception.Message)" -ForegroundColor DarkGray } }
  Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $storeApps } |
    ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
  # the frameworks stay: the NVIDIA Control Panel and other apps use them
  Set-Services @{ InstallService=4; PushToInstall=4; wlidsvc=4; wuauserv=4; XblAuthManager=4; XblGameSave=4 }
  Write-Host '  The copy in C:\JDO\Store stays, so 18 can put it back any time.'
  Done $true
}

function Fix-SystemApps {
  # Start menu search, Settings, the lock / sign-in UI and the NVIDIA Control Panel are packaged apps
  Write-Host 'Start menu / search / Settings not opening: services, UAC, re-register the system apps' -ForegroundColor Cyan
  Set-Services @{ AppXSvc=3; ClipSVC=3; LicenseManager=3; StateRepository=3; TokenBroker=3; StorSvc=3; TabletInputService=3 }
  fsutil behavior set disableencryption 0 | Out-Null    # packaged apps fail to register when NTFS encryption is off
  Set-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 1
  Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation 'AppXManifest.xml')) } |
    ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $_.InstallLocation 'AppXManifest.xml') -ErrorAction SilentlyContinue }
  Done $true
}

function Install-Runtimes {
  Write-Host 'Visual C++ 2015-2022 (x64 + x86) and DirectX runtime from Microsoft' -ForegroundColor Cyan
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $d = Join-Path $env:TEMP 'jdo-runtimes'; New-Item -ItemType Directory -Force $d | Out-Null
  $items = @(
    @{ n='Visual C++ x64'; u='https://aka.ms/vs/17/release/vc_redist.x64.exe'; f='vc_x64.exe'; a='/install /quiet /norestart' },
    @{ n='Visual C++ x86'; u='https://aka.ms/vs/17/release/vc_redist.x86.exe'; f='vc_x86.exe'; a='/install /quiet /norestart' },
    @{ n='DirectX';        u='https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe'; f='dxwebsetup.exe'; a='/Q' }
  )
  foreach ($i in $items) {
    Write-Host "  $($i.n)"
    $p = Join-Path $d $i.f
    try { Invoke-WebRequest -Uri $i.u -OutFile $p -UseBasicParsing; Start-Process $p -ArgumentList $i.a -Wait }
    catch { Write-Host "  failed: $($_.Exception.Message)" -ForegroundColor Red }
  }
  Done $false
}

# ---------------- app slimming ----------------
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
function Set-ProcessPriority([string]$Exe, [int]$Cpu, [int]$Io, [int]$Page = 0) {
  # cpu: 3 high, 6 above normal, 2 normal, 5 below normal, 1 idle (lowest). io: 3 high, 2 normal, 1 low, 0 very low.
  # page (memory): 5 normal ... 1 lowest. Windows applies these every time the exe starts.
  Set-Dword "$ifeo\$Exe\PerfOptions" 'CpuPriorityClass' $Cpu
  Set-Dword "$ifeo\$Exe\PerfOptions" 'IoPriority' $Io
  if ($Page) { Set-Dword "$ifeo\$Exe\PerfOptions" 'PagePriority' $Page }
  Write-Host "  priority $Exe -> cpu $Cpu, io $Io$(if ($Page) { ", memory $Page" })"
}
function Remove-Startup([string]$Pattern) {
  foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -match $Pattern -and $_.Name -notlike 'PS*' } | ForEach-Object {
      Remove-ItemProperty $k -Name $_.Name; Write-Host "  startup removed: $($_.Name)" } }
  }
  Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Pattern } |
    ForEach-Object { Remove-Item $_.FullName; Write-Host "  startup removed: $($_.Name)" }
}
function Clear-Folders([string[]]$Paths) {
  foreach ($p in $Paths) {
    foreach ($f in Get-Item $p -ErrorAction SilentlyContinue) {
      Remove-Item $f.FullName -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "  cleaned $($f.FullName)"
    }
  }
}
function Stop-Updater([string]$TaskPattern, [string[]]$Services) {
  Get-ScheduledTask -TaskName $TaskPattern -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  task off: $($_.TaskName)" }
  foreach ($s in $Services) { if (Get-Service $s -ErrorAction SilentlyContinue) { Stop-Service $s -Force -ErrorAction SilentlyContinue; Set-Service $s -StartupType Manual; Write-Host "  service manual: $s" } }
}
function Set-BrowserPolicies([string]$Key) {
  # no running after the window closes, no startup boost, no telemetry, memory saver on
  foreach ($v in @{ BackgroundModeEnabled=0; StartupBoostEnabled=0; MetricsReportingEnabled=0; HighEfficiencyModeEnabled=1;
                    UserFeedbackAllowed=0; SpellCheckServiceEnabled=0; SearchSuggestEnabled=0; ShoppingListEnabled=0;
                    PromotionalTabsEnabled=0; DefaultBrowserSettingEnabled=0 }.GetEnumerator()) { Set-Dword $Key $v.Key $v.Value }
}

function Slim-Chrome {
  Write-Host 'Google Chrome' -ForegroundColor Cyan
  Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
  Set-BrowserPolicies 'HKLM:\SOFTWARE\Policies\Google\Chrome'
  Stop-Updater 'GoogleUpdateTask*' @('gupdate', 'gupdatem', 'GoogleChromeElevationService')
  Remove-Startup 'Google|Chrome'
  Clear-Folders @("$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache", "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache",
                  "$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache", "$env:LOCALAPPDATA\Google\Chrome\User Data\ShaderCache")
  Write-Host '  Updates: open chrome://settings/help when you want to update.'
}

function Slim-Brave {
  Write-Host 'Brave' -ForegroundColor Cyan
  Get-Process brave -ErrorAction SilentlyContinue | Stop-Process -Force
  $k = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
  Set-BrowserPolicies $k
  foreach ($v in @{ BraveRewardsDisabled=1; BraveWalletDisabled=1; BraveVPNDisabled=1; BraveAIChatEnabled=0; TorDisabled=1; BraveNewsDisabled=1; BraveTalkDisabled=1
                    BraveStatsPingEnabled=0; BraveP3AEnabled=0; UrlKeyedAnonymizedDataCollectionEnabled=0; SafeBrowsingExtendedReportingEnabled=0 }.GetEnumerator()) { Set-Dword $k $v.Key $v.Value }
  Stop-Updater 'BraveSoftwareUpdateTask*' @('brave', 'bravem', 'BraveElevationService', 'BraveVpnService', 'BraveVpnWireguardService')
  Remove-Startup 'Brave'
  Clear-Folders @("$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Cache", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Code Cache",
                  "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\GPUCache", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\ShaderCache")
  Write-Host '  Updates: open brave://settings/help when you want to update.'
}

function Slim-Discord {
  Write-Host 'Discord' -ForegroundColor Cyan
  Get-Process Discord -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 1
  $f = "$env:APPDATA\discord\settings.json"
  if (Test-Path $f) {
    $j = Get-Content $f -Raw | ConvertFrom-Json
    foreach ($v in @{ OPEN_ON_STARTUP=$false; START_MINIMIZED=$true; MINIMIZE_TO_TRAY=$true; enableHardwareAcceleration=$false }.GetEnumerator()) {
      $j | Add-Member -NotePropertyName $v.Key -NotePropertyValue $v.Value -Force
    }
    $j | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding UTF8
    Write-Host '  no startup, no hardware acceleration (stops it taking GPU time from the game)'
  } else { Write-Host '  Discord settings not found (open Discord once first)' -ForegroundColor Yellow }
  Remove-Startup 'Discord'
  Clear-Folders @("$env:APPDATA\discord\Cache", "$env:APPDATA\discord\Code Cache", "$env:APPDATA\discord\GPUCache", "$env:LOCALAPPDATA\Discord\packages")
  Set-ProcessPriority 'Discord.exe' 5 1 2
}

function Get-FortnitePath {
  $dat = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
  if (Test-Path $dat) { ((Get-Content $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object { $_.AppName -eq 'Fortnite' }).InstallLocation }
}

function Slim-Epic {
  Write-Host 'Epic Games Launcher + Fortnite' -ForegroundColor Cyan
  Get-Process EpicGamesLauncher, EpicWebHelper -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Startup 'Epic'
  Clear-Folders @("$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache*", "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Logs",
                  "$env:LOCALAPPDATA\FortniteGame\Saved\Logs", "$env:LOCALAPPDATA\FortniteGame\Saved\Crashes",
                  "$env:LOCALAPPDATA\FortniteGame\Saved\webcache*", "$env:LOCALAPPDATA\CrashReportClient")
  Set-ProcessPriority 'EpicGamesLauncher.exe' 1 0 1
  Set-ProcessPriority 'EpicWebHelper.exe' 1 0 1
  # the game itself: high CPU and I/O priority, high-performance GPU, fullscreen optimisations kept (DX12 needs them)
  Set-ProcessPriority 'FortniteClient-Win64-Shipping.exe' 3 3
  $fn = Get-FortnitePath
  if ($fn) {
    $exe = Join-Path $fn 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
    $g = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $g)) { New-Item -Path $g -Force | Out-Null }
    Set-ItemProperty -Path $g -Name $exe -Value 'GpuPreference=2;'
    Write-Host "  high-performance GPU: $exe"
  } else { Write-Host '  Fortnite not installed yet - run this again after installing it' -ForegroundColor Yellow }
}

function Slim-LiveStudio {
  Write-Host 'Streaming app (TikTok LIVE Studio / Streamlabs / OBS)' -ForegroundColor Cyan
  # Finds the app from its Start menu shortcut and gives every exe in its folder (helpers too) the lowest priority
  # Windows has: CPU idle, I/O very low, memory lowest - the game always wins. If the stream itself starts dropping
  # frames under full game load, choose 'normal' below. Most of the FPS it costs comes from its own settings - see README.
  $sh = New-Object -ComObject WScript.Shell
  $found = @()
  foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") {
    Get-ChildItem $dir -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match 'LIVE Studio|Streamlabs|OBS Studio' } | ForEach-Object {
      $t = $sh.CreateShortcut($_.FullName).TargetPath
      if ($t -and $t -like '*.exe' -and (Test-Path $t)) {
        $found += Get-ChildItem (Split-Path $t) -Filter *.exe -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'unins|update|crash' } | ForEach-Object { $_.Name }
        Remove-Startup ([IO.Path]::GetFileNameWithoutExtension($t))
      }
    }
  }
  if (-not $found) { Write-Host '  no streaming app found in the Start menu' -ForegroundColor Yellow; return }
  $lvl = Read-Host '  Priority: 1 = lowest without stream problems (default), 2 = absolute lowest (may drop frames), 3 = normal (undo)'
  foreach ($exe in $found | Sort-Object -Unique) {
    switch ($lvl) {
      '2' { Set-ProcessPriority $exe 1 0 1 }
      '3' { Remove-Item "$ifeo\$exe\PerfOptions" -Recurse -ErrorAction SilentlyContinue; Write-Host "  priority $exe -> normal" }
      default { Set-ProcessPriority $exe 5 1 2 }
    }
  }
  Write-Host '  In the app: encoder NVENC (hardware), output 1080p 60 fps, preview off / smaller, game capture (not display capture).' -ForegroundColor Yellow
}

function Set-GamePriority {
  Write-Host 'Fortnite = highest priority, every other app = lowest' -ForegroundColor Cyan
  # The game: CPU high (the highest Windows allows to stay stable - realtime freezes input and audio), I/O high,
  # memory normal (the top level), high-performance GPU. Every variant the anti-cheat launchers start is covered.
  foreach ($exe in 'FortniteClient-Win64-Shipping.exe', 'FortniteClient-Win64-Shipping_EAC.exe',
                   'FortniteClient-Win64-Shipping_EAC_EOS.exe', 'FortniteClient-Win64-Shipping_BE.exe') { Set-ProcessPriority $exe 3 3 5 }
  $fn = Get-FortnitePath
  if ($fn) {
    $g = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $g)) { New-Item -Path $g -Force | Out-Null }
    Get-ChildItem (Join-Path $fn 'FortniteGame\Binaries\Win64') -Filter 'FortniteClient-Win64-Shipping*.exe' -ErrorAction SilentlyContinue |
      ForEach-Object { Set-ItemProperty -Path $g -Name $_.FullName -Value 'GpuPreference=2;'; Write-Host "  high-performance GPU: $($_.Name)" }
  } else { Write-Host '  (Fortnite not installed yet - run this again after installing it, for the GPU setting)' -ForegroundColor Yellow }

  # Every other installed app and third-party service gets the least Windows can give without breaking it:
  #   lowest  (CPU idle, I/O very low, memory lowest): NVIDIA App / overlay / containers, Epic launcher, updaters, the rest
  #   safe-low (CPU below normal, I/O low, memory low): voice, video and streaming apps - at idle they would crackle,
  #            stutter or drop stream frames whenever the game is busy
  # Never lowered: Windows itself, the display driver service, chipset (AMD / Intel), the anti-cheat, audio / headset /
  # NVIDIA Broadcast, mouse / keyboard / controller software (lowering those adds input or sound lag).
  $skip = '(?i)^(FortniteClient|FortniteLauncher|EasyAntiCheat|EOSOverlay|BEService|BattlEye|vgc|vgtray|FACEIT|NVDisplay|NVIDIA Broadcast|nvsphelper|' +
          'audiodg|Rtk|Realtek|Nahimic|NGENUITY|HyperX|Voicemeeter|vbaudio|Sonic|Dolby|DTS|AMD|amd|Ryzen|Intel|igfx|' +
          'lghub|LGHUB|Razer|Synapse|SteelSeries|Wooting|Corsair|iCUE|Glorious|Keys2X|ViGEm|DS4|DSX|' +
          'unins|uninst|setup|install|crash)'
  $safeLow = '(?i)discord|chrome|brave|msedge|firefox|opera|spotify|obs|streamlabs|live ?studio|tiktok'
  $exes = @{}
  $sh = New-Object -ComObject WScript.Shell
  foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") {
    foreach ($l in Get-ChildItem $dir -Recurse -Filter *.lnk -ErrorAction SilentlyContinue) {
      $t = $sh.CreateShortcut($l.FullName).TargetPath
      if ($t -and $t -like '*.exe' -and $t -notlike "$env:WINDIR\*" -and (Test-Path $t)) { $exes[(Split-Path $t -Leaf)] = $t }
    }
  }
  # apps running right now (tray apps without a shortcut too)
  foreach ($p in Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -notlike "$env:WINDIR\*" }) { $exes[(Split-Path $p.Path -Leaf)] = $p.Path }
  # third-party services (updaters, NVIDIA containers, launcher services...) - Windows' own services are left alone
  foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
    $path = ($s.PathName -replace '^"([^"]+)".*$', '$1') -replace '^(\S+\.exe).*$', '$1'
    if ($path -like '*.exe' -and $path -notlike "$env:WINDIR\*" -and (Test-Path $path)) { $exes[(Split-Path $path -Leaf)] = $path }
  }
  # helper exes next to the main ones (Discord / browser / Epic / NVIDIA App / streaming app sub-processes)
  foreach ($t in @($exes.Values)) {
    $d = Split-Path $t
    if ($d -match '(?i)discord|chrome|brave|epic games\\launcher|NVIDIA App|live studio|streamlabs|obs') {
      Get-ChildItem $d -Filter *.exe -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $exes[$_.Name] = $_.FullName }
    }
  }
  $low = 0; $safe = 0
  foreach ($exe in $exes.Keys | Sort-Object) {
    if ($exe -match $skip) { continue }
    # Image File Execution Options work by file NAME: a name Windows also uses (conhost.exe, rundll32.exe...) would
    # lower that Windows program too, so such names are never touched
    if ((Test-Path "$env:WINDIR\System32\$exe") -or (Test-Path "$env:WINDIR\SysWOW64\$exe") -or (Test-Path "$env:WINDIR\$exe") -or
        $exe -match '(?i)^(powershell|pwsh|cmd|conhost|msedgewebview2|python|java|javaw|node)\.exe$') { continue }
    if ($exe -match $safeLow -or $exes[$exe] -match $safeLow) { Set-ProcessPriority $exe 5 1 2; $safe++ }
    else { Set-ProcessPriority $exe 1 0 1; $low++ }
  }
  $n = $low + $safe
  # GPU: Windows has no per-app GPU priority setting, so apps that draw with the GPU stop doing it
  foreach ($k in 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge') {
    Set-Dword $k 'HardwareAccelerationModeEnabled' 0
  }
  $f = "$env:APPDATA\discord\settings.json"
  if (Test-Path $f) {
    $j = Get-Content $f -Raw | ConvertFrom-Json
    $j | Add-Member -NotePropertyName enableHardwareAcceleration -NotePropertyValue $false -Force
    $j | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding UTF8
  }
  Write-Host "  $low apps at the lowest priority, $safe voice / video / streaming apps at safe-low; browsers and Discord no longer use the GPU" -ForegroundColor Green
  Write-Host '  Install a new app later? Run this option again.'
}

# ---------------- switches ----------------
$switches = [ordered]@{
  'Notifications' = @{
    On  = { Set-Services @{ WpnService=2; WpnUserService=2 }; Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' $null; Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 1 }
    Off = { Set-Services @{ WpnService=4; WpnUserService=4 }; Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1; Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 } }
  'Touch keyboard service (on by default - typing in Start menu search needs it)' = @{
    On  = { Set-Services @{ TabletInputService=3 } }
    Off = { Set-Services @{ TabletInputService=4 } } }
  'Bluetooth' = @{
    On  = { Set-Services @{ bthserv=3; BTAGService=3; BthAvctpSvc=3; BluetoothUserService=3; BTHUSB=3 }; Get-JdoDevices | Where-Object { $_.Class -eq 'Bluetooth' -or $_.HardwareID -like 'USB\VID_0E8D*' } | ForEach-Object { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } }
    Off = { Set-Services @{ bthserv=4; BTAGService=4; BthAvctpSvc=4; BluetoothUserService=4; BTHUSB=4 } } }
  'Windows Update' = @{
    On  = { Set-Services @{ wuauserv=3; UsoSvc=2; WaaSMedicSvc=3; BITS=3 }; Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' $null }
    Off = { Set-Services @{ wuauserv=3; UsoSvc=4; WaaSMedicSvc=4; BITS=3 }; Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1 } }
  'Windows Defender' = @{
    On  = { if (-not (Test-Path "$env:ProgramFiles\Windows Defender\MsMpEng.exe")) { Write-Host '  Defender files were removed from this build (rebuild with -KeepDefender to have it).' -ForegroundColor Yellow; return }
            Set-Services @{ WinDefend=2; WdNisSvc=3; WdNisDrv=3; WdFilter=0; WdBoot=0; SecurityHealthService=3; wscsvc=2; SgrmBroker=2; SgrmAgent=0; Sense=3 }
            Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' $null
            Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' $null
            Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' $null }
    Off = { Set-Services @{ WinDefend=4; WdNisSvc=4; WdNisDrv=4; WdFilter=4; WdBoot=4; SecurityHealthService=4; wscsvc=4; SgrmBroker=4; SgrmAgent=4; Sense=4 }
            Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
            Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 1
            Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0 } }
  'UAC prompts' = @{
    On  = { Set-Policy 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 5; Set-Policy 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 1 }
    Off = { Set-Policy 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 0; Set-Policy 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 0 } }
  'Printing' = @{
    On  = { Set-Services @{ Spooler=2; PrintNotify=3 } }
    Off = { Set-Services @{ Spooler=4; PrintNotify=4 } } }
  'Clipboard history' = @{
    On  = { Set-Services @{ cbdhsvc=3 }; Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' $null }
    Off = { Set-Services @{ cbdhsvc=4 }; Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0 } }
}

$actions = [ordered]@{
  '1'  = @{ t = 'Install game runtimes (Visual C++, DirectX)';                                  a = { Install-Runtimes } }
  '2'  = @{ t = 'Disable unneeded devices + USB power saving off (again after installing drivers)'; a = { Disable-Devices; Done $false } }
  '3'  = @{ t = 'Re-enable the devices JDO disabled';                                           a = { Enable-Devices; Done $false } }
  '4'  = @{ t = 'Fix Start menu search / Settings / packaged apps not opening';                 a = { Fix-SystemApps } }
  '5'  = @{ t = 'Open the Drivers folder (your network driver, to install by hand if needed)';  a = { Start-Process explorer.exe (Join-Path $root 'Drivers') } }
  '6'  = @{ t = 'Fix Task Scheduler (stops by itself / NVIDIA App not opening)';                 a = { Repair-TaskScheduler } }
  '7'  = @{ t = 'Fix "Run as administrator" not working';                                       a = { Repair-Admin } }
  '8'  = @{ t = 'Fix NVIDIA Control Panel / NVIDIA App (missing or not opening)';               a = { Repair-Nvidia } }
  '9'  = @{ t = 'Fix webcam for streaming';                                                     a = { Repair-Webcam } }
  '10' = @{ t = 'Slim Google Chrome';                                                           a = { Slim-Chrome; Done $false } }
  '11' = @{ t = 'Slim Brave';                                                                   a = { Slim-Brave; Done $false } }
  '12' = @{ t = 'Slim Discord';                                                                 a = { Slim-Discord; Done $false } }
  '13' = @{ t = 'Slim Epic Launcher + Fortnite (cleanup, game priority high)';                   a = { Slim-Epic; Done $false } }
  '14' = @{ t = 'Slim streaming app (LIVE Studio / Streamlabs / OBS)';                           a = { Slim-LiveStudio; Done $false } }
  '15' = @{ t = 'Slim ALL apps above + Fortnite highest / all other apps lowest priority';      a = { Slim-Chrome; Slim-Brave; Slim-Discord; Slim-Epic; Slim-LiveStudio; Set-GamePriority; Done $false } }
  '16' = @{ t = 'Priority only: Fortnite highest (CPU, RAM, disk, GPU), every other app lowest'; a = { Set-GamePriority; Done $false } }
  '17' = @{ t = 'Power plan: JDO Ultimate (full speed, real CPU usage)';                        a = { Set-JdoPowerPlan; Done $false } }
  '18' = @{ t = 'Microsoft Store + Xbox: put back (files, services, everything - offline)';      a = { Install-Store } }
  '19' = @{ t = 'Microsoft Store + Xbox: remove again (apps you got from it stay)';             a = { Remove-Store } }
}
$first = 20

while ($true) {
  Clear-Host
  Write-Host '  JDO Lite Windows - Tools' -ForegroundColor Cyan
  Write-Host '  ------------------------'
  foreach ($k in $actions.Keys) { Write-Host ('  {0,2}  {1}' -f $k, $actions[$k].t) }
  $n = $first; $keys = @($switches.Keys)
  foreach ($k in $keys) { Write-Host ('  {0,2}  {1}  on / off' -f $n, $k); $n++ }
  Write-Host '   0  Exit'
  $c = Read-Host '  Choose'
  Write-Host ''
  if ($c -eq '0') { return }
  if ($actions.Contains($c)) { & $actions[$c].a }
  else {
    $i = 0
    if ([int]::TryParse($c, [ref]$i) -and $i -ge $first -and $i -lt $first + $keys.Count) {
      $k = $keys[$i - $first]
      $s = Read-Host "  $k - type 1 for ON, 0 for OFF"
      if ($s -eq '1') { & $switches[$k].On; Done $true } elseif ($s -eq '0') { & $switches[$k].Off; Done $true }
    }
  }
  Read-Host '  Press Enter'
}
