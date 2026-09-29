# Renders assets\icon.ico (two usage rings) at the sizes Windows asks for.
#   powershell -NoProfile -STA -File tools\Build-Icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase

function New-Arc([double]$c, [double]$r, [double]$f) {
  $a = 2 * [Math]::PI * [Math]::Min($f, 0.9999)
  $fig = New-Object Windows.Media.PathFigure
  $fig.StartPoint = New-Object Windows.Point($c, ($c - $r))
  $end = New-Object Windows.Point(($c + $r * [Math]::Sin($a)), ($c - $r * [Math]::Cos($a)))
  $fig.Segments.Add((New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0, ($f -gt 0.5), ([Windows.Media.SweepDirection]::Clockwise), $true)))
  $g = New-Object Windows.Media.PathGeometry
  $g.Figures.Add($fig)
  return $g
}

function Get-Png([int]$s) {
  $brush = { param($hex) New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
  $pen = { param($hex, $w) $p = New-Object Windows.Media.Pen((& $brush $hex), $w); $p.StartLineCap = 'Round'; $p.EndLineCap = 'Round'; $p }
  $c = $s / 2; $t = [Math]::Max(1.6, $s * 0.13)
  $v = New-Object Windows.Media.DrawingVisual
  $dc = $v.RenderOpen()
  $dc.DrawEllipse((& $brush '#1E1E1E'), $null, (New-Object Windows.Point($c, $c)), ($c - 0.5), ($c - 0.5))
  $rOuter = $c - $t / 2 - $s * 0.08
  $rInner = $rOuter - $t * 1.55
  $dc.DrawEllipse($null, (& $pen '#40FFFFFF' $t), (New-Object Windows.Point($c, $c)), $rOuter, $rOuter)
  $dc.DrawEllipse($null, (& $pen '#40FFFFFF' $t), (New-Object Windows.Point($c, $c)), $rInner, $rInner)
  $dc.DrawGeometry($null, (& $pen '#D97757' $t), (New-Arc $c $rOuter 0.72))
  $dc.DrawGeometry($null, (& $pen '#4CC38A' $t), (New-Arc $c $rInner 0.42))
  $dc.Close()
  $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($s, $s, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32))
  $bmp.Render($v)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
  $ms = New-Object IO.MemoryStream
  $enc.Save($ms)
  return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 256
$pngs = @($sizes | ForEach-Object { , (Get-Png $_) })
$out = Join-Path $PSScriptRoot '..\assets\icon.ico'
$fs = [IO.File]::Create($out)
$w = New-Object IO.BinaryWriter($fs)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
  $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Close()
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot '..\assets\icon.png'), (Get-Png 256))
"wrote $((Resolve-Path $out).Path)"
