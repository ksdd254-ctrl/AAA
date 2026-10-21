# JDO x QHT - black full-screen cover with purple text, shown only while the tweaks are applied the first time.
# Closes by itself when C:\JDO\screen.stop appears, or after 5 minutes at the latest.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$stop = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'screen.stop'
$purple = [Drawing.Color]::FromArgb(168, 85, 247)
$forms = foreach ($s in [Windows.Forms.Screen]::AllScreens) {
  $f = New-Object Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.Bounds = $s.Bounds
  $f.BackColor = [Drawing.Color]::Black; $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.ControlBox = $false
  $f.Add_FormClosing({ if (-not (Test-Path $stop) -and $clock.Elapsed.TotalSeconds -lt 300) { $_.Cancel = $true } })
  $l = New-Object Windows.Forms.Label
  $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.ForeColor = $purple; $l.BackColor = [Drawing.Color]::Black
  $l.Font = New-Object Drawing.Font('Segoe UI', 28, [Drawing.FontStyle]::Bold)
  $l.Text = "JDO x QHT`r`n`r`nApplying the tweaks`r`nThe PC restarts by itself when it is done"
  $f.Controls.Add($l); $f
}
$clock = [Diagnostics.Stopwatch]::StartNew()
[Windows.Forms.Cursor]::Hide()
$t = New-Object Windows.Forms.Timer
$t.Interval = 500
$t.Add_Tick({ if ((Test-Path $stop) -or $clock.Elapsed.TotalSeconds -ge 300) { $t.Stop(); [Windows.Forms.Cursor]::Show(); foreach ($f in $forms) { $f.Close() }; [Windows.Forms.Application]::ExitThread() } })
$t.Start()
foreach ($f in $forms) { $f.Show() }
[Windows.Forms.Application]::Run()
