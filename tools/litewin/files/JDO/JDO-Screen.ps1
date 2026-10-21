# JDO x QHT - black full-screen cover shown while the tweaks are applied the first time. Purple title, and below it every
# line the tweak file writes (C:\JDO\logs\qht-live.txt), so you see what is done, what was already right and what failed.
# Closes when C:\JDO\screen.stop appears (just before the restart), or after 8 minutes at the latest.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stop = Join-Path $root 'screen.stop'
$live = Join-Path $root 'logs\qht-live.txt'
$purple = [Drawing.Color]::FromArgb(168, 85, 247)
$clock = [Diagnostics.Stopwatch]::StartNew()
$boxes = New-Object System.Collections.Generic.List[object]
$forms = foreach ($s in [Windows.Forms.Screen]::AllScreens) {
  $f = New-Object Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.Bounds = $s.Bounds
  $f.BackColor = [Drawing.Color]::Black; $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.ControlBox = $false
  $f.Add_FormClosing({ if (-not (Test-Path $stop) -and $clock.Elapsed.TotalMinutes -lt 8) { $_.Cancel = $true } })
  $title = New-Object Windows.Forms.Label
  $title.Dock = 'Top'; $title.Height = 150; $title.TextAlign = 'MiddleCenter'; $title.ForeColor = $purple; $title.BackColor = [Drawing.Color]::Black
  $title.Font = New-Object Drawing.Font('Segoe UI', 30, [Drawing.FontStyle]::Bold)
  $title.Text = "JDO x QHT`r`nApplying the tweaks - the PC restarts by itself"
  $log = New-Object Windows.Forms.Label
  $log.Dock = 'Fill'; $log.ForeColor = [Drawing.Color]::FromArgb(200, 200, 205); $log.BackColor = [Drawing.Color]::Black
  $log.Font = New-Object Drawing.Font('Consolas', 13); $log.Padding = New-Object Windows.Forms.Padding(60, 10, 60, 10)
  $f.Controls.Add($log); $f.Controls.Add($title)
  $boxes.Add($log); $f
}
[Windows.Forms.Cursor]::Hide()
$t = New-Object Windows.Forms.Timer
$t.Interval = 400
$t.Add_Tick({
  if ((Test-Path $stop) -or $clock.Elapsed.TotalMinutes -ge 8) { $t.Stop(); [Windows.Forms.Cursor]::Show(); foreach ($f in $forms) { $f.Close() }; [Windows.Forms.Application]::ExitThread(); return }
  try {
    $lines = @(Get-Content $live -Encoding UTF8 -ErrorAction Stop)
    $rows = [Math]::Max(10, [int](($boxes[0].Height - 20) / 22))
    $text = ($lines | Select-Object -Last $rows) -join "`r`n"
    foreach ($b in $boxes) { if ($b.Text -ne $text) { $b.Text = $text } }
  } catch { }
})
$t.Start()
foreach ($f in $forms) { $f.Show() }
[Windows.Forms.Application]::Run()
