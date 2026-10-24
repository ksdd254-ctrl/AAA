# JDO Tweak - controls the plan-box test VM.
# The VM runs on a throw-away overlay on top of the Lite test VM's disk: the original disk is never written.
#   vmctl.ps1 start            create a fresh overlay and boot it (QEMU, launched outside the app's sandbox)
#   vmctl.ps1 running          is this test VM running? (yes / no)
#   vmctl.ps1 shot             screenshot -> shot.png
#   vmctl.ps1 run              open the Run box and start D:\b.cmd
#   vmctl.ps1 report           copy C:\JDO-BOXTEST out of the VM disk -> report.txt
#   vmctl.ps1 stop             power the VM off
#   -Instance b -Mode reg      a second, separate test VM (own overlay, share and monitor port); -Mode all | reg | cmd picks
#                              what "Apply all" applies inside it (written to the share for boxtest.ps1)
param([Parameter(Mandatory = $true)][string]$Action, [string]$Instance = "", [string]$Mode = "all")
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = 'E:\win 10 JDO\vm-boxtest' + $(if ($Instance) { '-' + $Instance } else { '' })
$base = 'E:\win 10 JDO\vm\disk.qcow2'
$q = 'E:\win 10 JDO\qemu'
$share = 'E:\JDO_BOXSHARE' + $(if ($Instance) { '_' + $Instance.ToUpper() } else { '' })   # no spaces: QEMU's virtual FAT drive reads this folder
$overlay = Join-Path $work 'overlay.qcow2'
$mon = if ($Instance) { 4448 } else { 4446 }   # other sessions use 4445 and 4447
New-Item -ItemType Directory -Force $work, $share | Out-Null

# Other sessions run their own QEMU VMs on this PC: only ever look at / stop the one using this test's overlay.
function Mine { @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" | Where-Object { $_.CommandLine -like ('*' + $overlay + ',*') }) }

function Mon([string]$c) {
  $t = New-Object Net.Sockets.TcpClient('127.0.0.1', $mon); $s = $t.GetStream(); $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true
  Start-Sleep -Milliseconds 300; $w.WriteLine($c); Start-Sleep -Milliseconds 400; $t.Close()
}

function To-Png([string]$ppm, [string]$png) {
  Add-Type -AssemblyName System.Drawing
  $b = [IO.File]::ReadAllBytes($ppm)
  $h = [Text.Encoding]::ASCII.GetString($b, 0, 40); $hdr = $h -split '\s+'
  $wd = [int]$hdr[1]; $ht = [int]$hdr[2]; $off = $h.IndexOf($hdr[3], $h.IndexOf($hdr[2]) + $hdr[2].Length) + $hdr[3].Length + 1
  $bmp = New-Object System.Drawing.Bitmap $wd, $ht
  $data = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $wd, $ht), 'WriteOnly', 'Format24bppRgb')
  $row = New-Object byte[] ($data.Stride)
  for ($y = 0; $y -lt $ht; $y++) {
    for ($x = 0; $x -lt $wd; $x++) { $i = $off + ($y * $wd + $x) * 3; $row[$x * 3] = $b[$i + 2]; $row[$x * 3 + 1] = $b[$i + 1]; $row[$x * 3 + 2] = $b[$i] }
    [Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $data.Stride)
  }
  $bmp.UnlockBits($data); $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

switch ($Action) {
  'start' {
    if (Mine) { throw 'The box-test VM is already running - stop it first.' }
    # test files for the VM's USB drive
    Copy-Item 'E:\JDO\JdoTweak\dist\JdoTweak.exe', "$here\vm\boxtest.ps1", "$here\vm\b.cmd" $share -Force
    Set-Content (Join-Path $share 'mode.txt') $Mode -Encoding ASCII
    $pp = 'E:\JDO\Release\Gaming Performance Power Plan.cmd'
    if (Test-Path $pp) { Copy-Item $pp (Join-Path $share 'power.cmd') -Force }
    if (Test-Path $overlay) { Remove-Item $overlay -Force }
    & "$q\qemu-img.exe" create -f qcow2 -b $base -F qcow2 $overlay | Out-Null
    $args = @(
      '-machine', 'q35', '-cpu', 'max', '-smp', '4', '-m', '3072',
      '-drive', "file=$overlay,if=none,id=d0,format=qcow2", '-device', 'ich9-ahci,id=ahci', '-device', 'ide-hd,drive=d0,bus=ahci.0,bootindex=1',
      '-drive', ('file=fat:' + $share.Replace('\', '/') + ',if=none,id=u0,format=raw,read-only=on'), '-device', 'qemu-xhci', '-device', 'usb-storage,drive=u0',
      '-device', 'usb-tablet',
      '-netdev', 'user,id=n0', '-device', 'e1000,netdev=n0',
      '-audiodev', 'none,id=snd0', '-device', 'intel-hda', '-device', 'hda-duplex,audiodev=snd0',
      '-display', 'none', '-vga', 'std', '-name', ('JDO box test ' + $Instance),
      '-monitor', "tcp:127.0.0.1:${mon},server,nowait", '-rtc', 'base=localtime'
    )
    $cmd = '"' + "$q\qemu-system-x86_64.exe" + '" ' + (($args | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' ')
    Set-Content (Join-Path $work 'qemu-cmd.txt') $cmd
    # WMI start: runs outside the desktop app's sandbox, like the Lite builder needs
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $q }
    "started: return $($r.ReturnValue), pid $($r.ProcessId)"
  }
  'shot' {
    $ppm = (Join-Path $work 'shot.ppm')
    Mon ('screendump "{0}"' -f $ppm.Replace('\', '/'))
    Start-Sleep -Seconds 2
    To-Png $ppm (Join-Path $work 'shot.png')
    "saved $work\shot.png"
  }
  'run' {
    Mon 'sendkey meta_l-r'; Start-Sleep -Seconds 3
    foreach ($k in 'd', 'shift-semicolon', 'backslash', 'b', 'dot', 'c', 'm', 'd') { Mon "sendkey $k"; Start-Sleep -Milliseconds 250 }
    Start-Sleep -Seconds 1; Mon 'sendkey ret'
    'typed D:\b.cmd into the Run box'
  }
  'report' {
    $raw = Join-Path $work 'peek.raw'; $out = Join-Path $work 'out'
    if (Test-Path $raw) { Remove-Item $raw -Force }
    & "$q\qemu-img.exe" convert -U -f qcow2 -O raw $overlay $raw
    if (Test-Path $out) { cmd /c rd /s /q "`"$out`"" }
    & 'C:\Program Files\7-Zip\7z.exe' x $raw "-o$out" '*JDO-BOXTEST*' -r -y -bso0 -bsp0 2>$null
    Remove-Item $raw -Force -ErrorAction SilentlyContinue
    $r = Get-ChildItem $out -Recurse -Filter report.txt -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($r) { Copy-Item $r.FullName (Join-Path $work 'report.txt') -Force; Get-Content $r.FullName } else { 'no report yet' }
  }
  'stop' {
    try { Mon 'quit' } catch { }
    Start-Sleep 2
    Mine | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }   # only this VM, never other sessions' QEMU
    'stopped'
  }
  'running' { if (Mine) { 'yes' } else { 'no' } }
}
