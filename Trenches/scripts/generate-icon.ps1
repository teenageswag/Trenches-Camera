$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$iconDir = Join-Path $PSScriptRoot '../Resources'
[System.IO.Directory]::CreateDirectory($iconDir) | Out-Null
$bitmap = [System.Drawing.Bitmap]::new(1024, 1024)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::FromArgb(10, 12, 10))
$accent = [System.Drawing.Color]::FromArgb(214, 247, 94)
$pen = [System.Drawing.Pen]::new($accent, 14)
$paper = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(232, 230, 217))
$lime = [System.Drawing.SolidBrush]::new($accent)
$font = [System.Drawing.Font]::new('Consolas', 260, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$graphics.DrawLines($pen, [System.Drawing.Point[]]@([System.Drawing.Point]::new(270, 180), [System.Drawing.Point]::new(180, 180), [System.Drawing.Point]::new(180, 844), [System.Drawing.Point]::new(270, 844)))
$graphics.DrawLines($pen, [System.Drawing.Point[]]@([System.Drawing.Point]::new(754, 180), [System.Drawing.Point]::new(844, 180), [System.Drawing.Point]::new(844, 844), [System.Drawing.Point]::new(754, 844)))
$graphics.DrawString('t', $font, $paper, 280, 315)
$graphics.FillRectangle($lime, 553, 592, 138, 25)
$bitmap.Save((Join-Path $iconDir 'AppIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$font.Dispose(); $paper.Dispose(); $lime.Dispose(); $pen.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
