# JDO Lite - live view of the test VM: every 25 s a screenshot (QEMU monitor) + status into vmtest\live\index.html
param([string]$Work = 'E:\win 10 JDO', [int]$Every = 25, [string]$Live = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'live'))
$vm = Join-Path $Work 'vm'
New-Item -ItemType Directory -Force $Live | Out-Null
Add-Type -AssemblyName System.Drawing
function Mon([string]$c) {
  $t = New-Object Net.Sockets.TcpClient('127.0.0.1', 4445); $s = $t.GetStream(); $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true
  Start-Sleep -Milliseconds 300; $w.WriteLine($c); Start-Sleep -Milliseconds 700; $t.Close()
}
function To-Png([string]$ppm, [string]$png) {
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
while ($true) {
  $state = 'VM off'
  if (Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue) {
    try { Mon ('screendump "{0}/live.ppm"' -f $vm.Replace('\', '/')); Start-Sleep 1; To-Png "$vm\live.ppm" "$Live\live.png"; $state = 'VM running' } catch { $state = 'VM running (no screen yet)' }
  }
  $last = try { ([IO.File]::ReadAllLines("$vm\progress.txt") | Select-Object -Last 6) -join '<br>' } catch { '' }
  $stamp = Get-Date -Format 'HH:mm:ss'
  @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="$Every">
<title>JDO Lite VM live</title>
<style>body{margin:0;background:#0b0b0b;color:#ddd;font:15px Segoe UI,Tahoma,sans-serif;padding:12px}
h1{font-size:18px;margin:0 0 6px}.s{color:#7fd17f}.l{direction:ltr;text-align:left;font:12px Consolas,monospace;color:#9a9a9a;margin:8px 0}
img{max-width:100%;border:1px solid #333;display:block}</style></head><body>
<h1>JDO Lite - VM test <span class="s">($state)</span></h1>
<div>Updated $stamp - refreshes every $Every s</div>
<div class="l">$last</div>
<img src="live.png?t=$stamp" alt="VM screen">
</body></html>
"@ | Set-Content "$Live\index.html" -Encoding UTF8
  Start-Sleep -Seconds $Every
}

