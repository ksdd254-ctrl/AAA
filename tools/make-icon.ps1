# Draws the Jdo X Abu Qht logo ("JX" monogram with a speed slash on a purple-to-cyan tile)
# and writes JdoTweak\Data\icon256.png and JdoTweak\Data\app.ico (16-256 px).
#   powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$data = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'JdoTweak\Data'

function Draw([int]$s) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'
  $g.Clear([System.Drawing.Color]::Transparent)

  # rounded tile
  $r = [single]($s * 0.24); $pad = [single]([math]::Max(0.5, $s * 0.02)); $w = [single]($s - 2 * $pad)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($pad, $pad, 2 * $r, 2 * $r, 180, 90)
  $path.AddArc($pad + $w - 2 * $r, $pad, 2 * $r, 2 * $r, 270, 90)
  $path.AddArc($pad + $w - 2 * $r, $pad + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
  $path.AddArc($pad, $pad + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
  $path.CloseFigure()
  $rect = New-Object System.Drawing.RectangleF $pad, $pad, $w, $w
  $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 124, 92, 255)), ([System.Drawing.Color]::FromArgb(255, 34, 211, 238)), ([single]45)
  $g.FillPath($bg, $path)
  $g.SetClip($path)
  $gloss = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(36, 255, 255, 255))
  $g.FillEllipse($gloss, [single](-$s * 0.3), [single](-$s * 0.75), [single]($s * 1.6), [single]($s * 1.15))

  # speed slash behind the letters
  $slash = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
  $pts = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF ([single]($s * 0.40)), ([single]($s * 0.86))),
    (New-Object System.Drawing.PointF ([single]($s * 0.56)), ([single]($s * 0.14))),
    (New-Object System.Drawing.PointF ([single]($s * 0.64)), ([single]($s * 0.14))),
    (New-Object System.Drawing.PointF ([single]($s * 0.48)), ([single]($s * 0.86))))
  $g.FillPolygon($slash, $pts)

  # "JX"
  $font = New-Object System.Drawing.Font 'Segoe UI Black', ([single]($s * 0.42)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 20, 10, 60))
  $off = [single]([math]::Max(1, $s * 0.015))
  $g.DrawString('JX', $font, $shadow, (New-Object System.Drawing.RectangleF $off, ([single]($off - $s * 0.01)), ([single]$s), ([single]$s)), $fmt)
  $g.DrawString('JX', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, ([single](-$s * 0.01)), ([single]$s), ([single]$s)), $fmt)
  $g.Dispose()
  return $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($s in $sizes) {
  $b = Draw $s
  $ms = New-Object System.IO.MemoryStream
  $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  if ($s -eq 256) { $b.Save((Join-Path $data 'icon256.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
  $b.Dispose()
  $pngs += , $ms.ToArray()
}

# ICO container with PNG-compressed images
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $len = $pngs[$i].Length
  $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
  $offset += $len
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $data 'app.ico'), $out.ToArray())
Write-Host "Wrote $data\app.ico and icon256.png"
