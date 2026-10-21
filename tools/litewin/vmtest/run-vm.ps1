# JDO Lite - install the built ISO into a throw-away QEMU virtual machine and read back the report.
# Nothing touches real disks or hardware: QEMU runs as plain files (no install, no Hyper-V), the VM disk is a file.
# Usage (as admin, outside the Claude app sandbox): powershell -ExecutionPolicy Bypass -File run-vm.ps1
param(
  [string]$Work = 'E:\win 10 JDO',
  [int]$Cpus = 4,
  [int]$MemMB = 4096,
  [int]$DiskGB = 24,
  [int]$TimeoutMin = 240,
  [switch]$Resume,           # boot the existing VM disk again (QEMU stopped midway) instead of a fresh install
  [string]$Display = 'none'  # 'sdl' = a window on the desktop you can use with mouse and keyboard (Ctrl+Alt+G frees the mouse)
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$q = Join-Path $Work 'qemu'
$vm = Join-Path $Work 'vm'
$src = Join-Path $Work 'iso'
$testSrc = Join-Path $vm 'iso-src'
$testIso = Join-Path $vm 'JDO_Lite_VMTEST.iso'
$disk = Join-Path $vm 'disk.qcow2'
$log = Join-Path $vm 'progress.txt'
New-Item -ItemType Directory -Force $vm | Out-Null
# the live view reads progress.txt too: a write that meets its read is retried, never fatal
function Say([string]$t) {
  $l = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $t; Write-Host $l
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content $log $l -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 300 } }
}
if (-not $Resume) { for ($i = 0; $i -lt 10; $i++) { try { Set-Content $log '' -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500 } } }
if (-not $Resume) {

# ---- 1. test ISO = the real ISO folder with the VM-only answer file and checks added ----
Say 'Building the test ISO (real image + VM-only answer file)'
if (Test-Path $testSrc) { cmd /c rd /s /q "`"$testSrc`"" }
& robocopy $src $testSrc /E /NFL /NDL /NJH /NJS /NP | Out-Null
# The VM's answer file IS the real one (files\autounattend.xml), plus only: wipe the VM's own disk 0 and run
# vm-check.ps1 after the first-boot script. So the VM tests exactly what a real USB install does.
[xml]$ua = Get-Content (Join-Path (Split-Path $here) 'files\autounattend.xml') -Raw
$nsu = 'urn:schemas-microsoft-com:unattend'
$setup = $ua.unattend.settings | Where-Object pass -eq 'windowsPE' | ForEach-Object { $_.component } | Where-Object name -eq 'Microsoft-Windows-Setup'
$frag = [xml](@"
<x xmlns="$nsu" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
    <CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions>
    <ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter><Active>true</Active></ModifyPartition></ModifyPartitions>
  </Disk></DiskConfiguration>
  <ImageInstall><OSImage><InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo>
    <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom></OSImage></ImageInstall>
  <SynchronousCommand wcm:action="add"><Order>2</Order>
    <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-PSDrive -PSProvider FileSystem | ForEach-Object { `$p = Join-Path `$_.Root 'vm-check.ps1'; if (Test-Path `$p) { &amp; `$p; break } }"</CommandLine>
    <Description>JDO VM test checks</Description></SynchronousCommand>
</x>
"@)
foreach ($n in 'DiskConfiguration', 'ImageInstall') { [void]$setup.PrependChild($ua.ImportNode($frag.x[$n], $true)) }
$shell = $ua.unattend.settings | Where-Object pass -eq 'oobeSystem' | ForEach-Object { $_.component } | Where-Object name -eq 'Microsoft-Windows-Shell-Setup'
[void]$shell.FirstLogonCommands.AppendChild($ua.ImportNode($frag.x.SynchronousCommand, $true))
$ua.Save("$testSrc\autounattend.xml")
Copy-Item "$here\vm-check.ps1" "$testSrc\vm-check.ps1" -Force
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
public static class VmIso {
  public static void SetBoot(object fsi, object bios, object uefi) {
    fsi.GetType().InvokeMember("BootImageOptionsArray", System.Reflection.BindingFlags.SetProperty, null, fsi, new object[] { new object[] { bios, uefi } });
  }
  public static void Write(string path, object stream, int blockSize, int totalBlocks) {
    IStream s = (IStream)stream; byte[] buf = new byte[blockSize]; IntPtr read = Marshal.AllocHGlobal(4);
    try { using (FileStream f = File.Create(path)) for (int i = 0; i < totalBlocks; i++) { s.Read(buf, blockSize, read); f.Write(buf, 0, Marshal.ReadInt32(read)); } }
    finally { Marshal.FreeHGlobal(read); }
  }
}
'@
function Boot-Image([string]$File, [int]$Platform) {
  $st = New-Object -ComObject ADODB.Stream; $st.Open(); $st.Type = 1; $st.LoadFromFile($File)
  $b = New-Object -ComObject IMAPI2FS.BootOptions; $b.AssignBootImage($st.psobject.BaseObject); $b.PlatformId = $Platform; $b.Emulation = 0; $b
}
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.ChooseImageDefaultsForMediaType(18); $fsi.FileSystemsToCreate = 4; $fsi.UDFRevision = 0x102; $fsi.VolumeName = 'JDO_VMTEST'
[VmIso]::SetBoot($fsi, (Boot-Image "$testSrc\boot\etfsboot.com" 0), (Boot-Image "$testSrc\efi\microsoft\boot\efisys.bin" 0xEF))
$fsi.Root.AddTree($testSrc, $false)
$res = $fsi.CreateResultImage()
if (Test-Path $testIso) { Remove-Item $testIso -Force }
[VmIso]::Write($testIso, $res.ImageStream, $res.BlockSize, $res.TotalBlocks)
Say ('Test ISO: {0:N2} GB' -f ((Get-Item $testIso).Length / 1GB))

# ---- 2. virtual disk and VM ----
if (Test-Path $disk) { Remove-Item $disk -Force }
& "$q\qemu-img.exe" create -f qcow2 $disk "${DiskGB}G" | Out-Null
} else { Say 'Resuming: booting the existing VM disk' }
$mon = 4445
# BIOS boot (SeaBIOS): disk first, so the blank disk falls through to the ISO once and the installed disk wins afterwards.
# AHCI disk + e1000 network: both have inbox Windows drivers, so no extra drivers are needed.
$qargs = @(
  '-machine', 'q35', '-cpu', 'max', '-smp', $Cpus, '-m', $MemMB,
  '-drive', "file=$disk,if=none,id=d0,format=qcow2", '-device', 'ich9-ahci,id=ahci', '-device', 'ide-hd,drive=d0,bus=ahci.0,bootindex=1',
  '-drive', "file=$testIso,if=none,id=c0,media=cdrom,format=raw", '-device', 'ide-cd,drive=c0,bus=ahci.1,bootindex=2',
  '-netdev', 'user,id=n0', '-device', 'e1000,netdev=n0',
  '-device', 'qemu-xhci', '-device', 'usb-tablet',
  '-display', $Display, '-vga', 'std', '-name', 'JDO Lite - VM test',
  '-monitor', "tcp:127.0.0.1:${mon},server,nowait",
  '-rtc', 'base=localtime', '-no-reboot-on-shutdown'
)
# -no-reboot would stop the VM at the first reboot of setup; instead it runs until Windows shuts itself down
$qargs = $qargs | Where-Object { $_ -ne '-no-reboot-on-shutdown' }
$cmdline = '"' + "$q\qemu-system-x86_64.exe" + '" ' + (($qargs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' ')
Say "Starting the VM ($Cpus cores, $MemMB MB, $DiskGB GB disk)"
$p = Start-Process -FilePath "$q\qemu-system-x86_64.exe" -ArgumentList ($qargs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -PassThru -WindowStyle $(if ($Display -eq 'none') { 'Hidden' } else { 'Normal' })

function Mon([string]$c) {
  try { $t = New-Object Net.Sockets.TcpClient('127.0.0.1', $mon); $s = $t.GetStream(); $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true; Start-Sleep -Milliseconds 300; $w.WriteLine($c); Start-Sleep -Milliseconds 500; $t.Close() } catch { }
}
# the install media asks "press any key to boot from CD" once: tap keys for the first half-minute
Start-Sleep -Seconds 6
if (-not $Resume) { 1..12 | ForEach-Object { Mon 'sendkey ret'; Start-Sleep -Seconds 2 } }

# Reads C:\JDO-TEST from the running VM's disk (qemu-img -U = shared read while QEMU has it open)
function Read-Report {
  $raw = Join-Path $vm 'peek.raw'
  if (Test-Path $raw) { Remove-Item $raw -Force }
  & "$q\qemu-img.exe" convert -U -f qcow2 -O raw $disk $raw
  $rep = Join-Path $vm 'report'
  if (Test-Path $rep) { cmd /c rd /s /q "`"$rep`"" }
  & "C:\Program Files\7-Zip\7z.exe" x $raw "-o$rep" '*JDO-TEST*' '*\Windows\Setup\Scripts\firstboot.log' -y -bso0 -bsp0 -r 2>$null
  Remove-Item $raw -Force -ErrorAction SilentlyContinue
  Get-ChildItem $rep -Recurse -Filter done.txt -ErrorAction SilentlyContinue | Select-Object -First 1
}

$start = Get-Date; $done = $null
while (-not $p.HasExited -and ((Get-Date) - $start).TotalMinutes -lt $TimeoutMin) {
  Start-Sleep -Seconds 120
  Mon ('screendump "{0}/screen.ppm"' -f $vm.Replace('\', '/'))   # quoted: the path has spaces
  $min = ((Get-Date) - $start).TotalMinutes
  Say ('VM running {0:N0} min, qcow2 {1:N1} GB' -f $min, ((Get-Item $disk).Length / 1GB))
  # after setup has had time to finish, look for the checks' done marker every few minutes
  if ($min -gt 20 -and [int]$min % 6 -lt 2) { $done = Read-Report; if ($done) { break } }
}
if ($p.HasExited) { Say 'VM stopped by itself (it should stay on)'; $done = Read-Report }
if ($done) {
  $found = Get-ChildItem (Split-Path $done.FullName) -Filter report.txt | Select-Object -First 1
  Copy-Item $found.FullName (Join-Path $Work 'vm-report.txt') -Force
  Say "Report: $Work\vm-report.txt  (the VM keeps running for more checks)"
  Get-Content $found.FullName
} else { Say 'No finished report yet - see vm\screen.ppm'; exit 1 }
