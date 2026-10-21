# Draws the JDO x QHT icons (dark: black / graphite, light-gray "JDO", one symbol each) into files\JDO\Icons\*.ico.
# Run once when the design changes: powershell -File make-icons.ps1
Add-Type -AssemblyName System.Drawing
$out = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'files\JDO\Icons'
New-Item -ItemType Directory -Force $out | Out-Null
# Segoe MDL2 Assets glyphs (in every Windows 10): wrench, lightning, app grid, folder
$icons = [ordered]@{ tools = [char]0xE90F; tweaks = [char]0xE945; apps = [char]0xE71D; folder = [char]0xE8B7 }

function Draw([int]$size, [char]$glyph) {
  $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([Drawing.Color]::Transparent)
  $r = [Math]::Max(2, [int]($size * 0.18)); $m = [Math]::Max(0, [int]($size * 0.03)); $w = $size - 2 * $m
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $path.AddArc($m, $m, $r, $r, 180, 90); $path.AddArc($m + $w - $r, $m, $r, $r, 270, 90)
  $path.AddArc($m + $w - $r, $m + $w - $r, $r, $r, 0, 90); $path.AddArc($m, $m + $w - $r, $r, $r, 90, 90); $path.CloseFigure()
  $bg = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Point 0, 0), (New-Object Drawing.Point 0, $size),
        [Drawing.Color]::FromArgb(255, 40, 40, 45), [Drawing.Color]::FromArgb(255, 10, 10, 12))
  $g.FillPath($bg, $path)
  $g.DrawPath((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 90, 90, 98)), ([Math]::Max(1, $size / 64))), $path)
  $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  if ($size -ge 32) {
    # symbol in the upper part, "JDO" underneath
    $gf = New-Object Drawing.Font('Segoe MDL2 Assets', [float]($size * 0.34), [Drawing.GraphicsUnit]::Pixel)
    $g.DrawString([string]$glyph, $gf, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 150, 150, 158))), (New-Object Drawing.RectangleF 0, ($size * 0.08), $size, ($size * 0.52)), $fmt)
    $tf = New-Object Drawing.Font('Segoe UI', [float]($size * 0.25), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $g.DrawString('JDO', $tf, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 225, 225, 230))), (New-Object Drawing.RectangleF 0, ($size * 0.56), $size, ($size * 0.36)), $fmt)
  } else {
    # 16 px: only the symbol reads
    $gf = New-Object Drawing.Font('Segoe MDL2 Assets', [float]($size * 0.62), [Drawing.GraphicsUnit]::Pixel)
    $g.DrawString([string]$glyph, $gf, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 215, 215, 220))), (New-Object Drawing.RectangleF 0, 0, $size, $size), $fmt)
  }
  $g.Dispose(); $bmp
}

foreach ($k in $icons.Keys) {
  $pngs = foreach ($s in 256, 64, 48, 32, 16) {
    $b = Draw $s $icons[$k]; $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
    , @($s, $ms.ToArray())
  }
  # ICO file: header, one directory entry per size, then the PNG images
  $fs = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $fs
  $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
  $offset = 6 + 16 * $pngs.Count
  foreach ($p in $pngs) {
    $s = $p[0]; $d = $p[1]
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$d.Length); $bw.Write([uint32]$offset)
    $offset += $d.Length
  }
  foreach ($p in $pngs) { $bw.Write([byte[]]$p[1]) }
  [IO.File]::WriteAllBytes((Join-Path $out "$k.ico"), $fs.ToArray())
  # a preview PNG next to the script, to look at the design
  [IO.File]::WriteAllBytes((Join-Path $out "$k-256.png"), $pngs[0][1])
}
Get-ChildItem $out | Select-Object Name, Length
