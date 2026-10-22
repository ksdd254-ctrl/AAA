# JDO x QHT - full-screen progress screen shown while the tweaks are applied the first time (deep purple, never black, so you
# can tell it from a frozen PC). Shows a title, an animated "working" line with a running clock, and the last lines the tweak
# file wrote (C:\JDO\logs\qht-live.txt). If that file stops changing for 90 s the line turns amber: still waiting.
# It always lets you out: it closes by itself when C:\JDO\screen.stop appears (just before the restart), after 4 minutes at
# the latest, or when you press Esc three times.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stop = Join-Path $root 'screen.stop'
$live = Join-Path $root 'logs\qht-live.txt'
$bg     = [Drawing.Color]::FromArgb(30, 12, 52)       # deep purple
$purple = [Drawing.Color]::FromArgb(196, 140, 255)
$white  = [Drawing.Color]::FromArgb(240, 235, 250)
$dim    = [Drawing.Color]::FromArgb(170, 160, 190)
$clock = [Diagnostics.Stopwatch]::StartNew()
$script:esc = 0
$script:lastChange = [Diagnostics.Stopwatch]::StartNew(); $script:lastText = ''
$status = New-Object System.Collections.Generic.List[object]; $boxes = New-Object System.Collections.Generic.List[object]
$forms = foreach ($s in [Windows.Forms.Screen]::AllScreens) {
  $f = New-Object Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.Bounds = $s.Bounds; $f.KeyPreview = $true
  $f.BackColor = $bg; $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.ControlBox = $false
  $f.Add_FormClosing({ if (-not (Test-Path $stop) -and $clock.Elapsed.TotalMinutes -lt 4 -and $script:esc -lt 3) { $_.Cancel = $true } })
  $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $script:esc++ } })
  $title = New-Object Windows.Forms.Label
  $title.Dock = 'Top'; $title.Height = 130; $title.TextAlign = 'BottomCenter'; $title.ForeColor = $white; $title.BackColor = $bg
  $title.Font = New-Object Drawing.Font('Segoe UI', 32, [Drawing.FontStyle]::Bold); $title.Text = 'JDO x QHT'
  $st = New-Object Windows.Forms.Label
  $st.Dock = 'Top'; $st.Height = 90; $st.TextAlign = 'MiddleCenter'; $st.ForeColor = $purple; $st.BackColor = $bg
  $st.Font = New-Object Drawing.Font('Segoe UI', 20); $st.Text = 'Applying the tweaks'
  $log = New-Object Windows.Forms.Label
  $log.Dock = 'Fill'; $log.ForeColor = $dim; $log.BackColor = $bg
  $log.Font = New-Object Drawing.Font('Consolas', 13); $log.Padding = New-Object Windows.Forms.Padding(70, 6, 70, 10)
  $f.Controls.Add($log); $f.Controls.Add($st); $f.Controls.Add($title)
  $boxes.Add($log); $status.Add($st); $f
}
[Windows.Forms.Cursor]::Hide()
$t = New-Object Windows.Forms.Timer
$t.Interval = 300
$tick = 0
$t.Add_Tick({
  if ((Test-Path $stop) -or $clock.Elapsed.TotalMinutes -ge 4 -or $script:esc -ge 3) { $t.Stop(); [Windows.Forms.Cursor]::Show(); foreach ($f in $forms) { $f.Close() }; [Windows.Forms.Application]::ExitThread(); return }
  $script:tick++
  $dots = '.' * (($script:tick % 4)); $spin = '|/-\'[$script:tick % 4]
  $el = '{0:00}:{1:00}' -f [int]$clock.Elapsed.TotalMinutes, $clock.Elapsed.Seconds
  try {
    $lines = @(Get-Content $live -Encoding UTF8 -ErrorAction Stop)
    $rows = [Math]::Max(8, [int](($boxes[0].Height - 20) / 22))
    $text = ($lines | Select-Object -Last $rows) -join "`r`n"
    if ($text -ne $script:lastText) { $script:lastText = $text; $script:lastChange.Restart() }
    foreach ($b in $boxes) { if ($b.Text -ne $text) { $b.Text = $text } }
  } catch { }
  $stale = $script:lastChange.Elapsed.TotalSeconds -gt 90
  $msg = if ($stale) { "$spin  still working$dots  (no new line for $([int]$script:lastChange.Elapsed.TotalSeconds) s)   $el" } else { "$spin  working$dots   $el" }
  foreach ($s in $status) { $s.Text = $msg; $s.ForeColor = $(if ($stale) { [Drawing.Color]::FromArgb(255, 190, 80) } else { $purple }) }
})
$t.Start()
foreach ($f in $forms) { $f.Show() }
[Windows.Forms.Application]::Run()
