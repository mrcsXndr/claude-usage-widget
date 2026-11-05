$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$source = Join-Path (Split-Path $PSScriptRoot) 'ClaudeUsageWidget.ps1'
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($functionName in 'Esc', 'Get-CenteredRingTextXaml') {
  $definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
  Invoke-Expression $definition.Extent.Text
}
$Theme = @{ fg = '#FFFFFF' }
$failures = 0
$checks = 0
foreach ($label in 'A', 'I', 'W', 'AB', 'Wi', 'Ab', 'gp', '&', '99') {
  foreach ($fontSize in 7.5, 9, 10.5, 12, 14) {
    foreach ($scale in 1, 1.25, 1.5, 2) {
      $markup = Get-CenteredRingTextXaml $label $fontSize
      $grid = [Windows.Markup.XamlReader]::Parse("<Grid xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" Width=`"32`" Height=`"32`">$markup</Grid>")
      [Windows.Media.VisualTreeHelper]::SetRootDpi($grid, (New-Object Windows.DpiScale($scale, $scale)))
      $grid.Measure((New-Object Windows.Size(32, 32)))
      $grid.Arrange((New-Object Windows.Rect(0, 0, 32, 32)))
      $grid.UpdateLayout()
      $pixels = [int](32 * $scale)
      $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($pixels, $pixels, (96 * $scale), (96 * $scale), [Windows.Media.PixelFormats]::Pbgra32)
      $bitmap.Render($grid)
      $buffer = New-Object byte[] ($pixels * $pixels * 4)
      $bitmap.CopyPixels($buffer, ($pixels * 4), 0)
      $minX = $pixels; $minY = $pixels; $maxX = -1; $maxY = -1
      for ($row = 0; $row -lt $pixels; $row++) {
        for ($column = 0; $column -lt $pixels; $column++) {
          if ($buffer[($row * $pixels + $column) * 4 + 3] -ge 96) {
            $minX = [Math]::Min($minX, $column); $maxX = [Math]::Max($maxX, $column)
            $minY = [Math]::Min($minY, $row); $maxY = [Math]::Max($maxY, $row)
          }
        }
      }
      $errorX = [Math]::Abs(($minX + $maxX + 1 - $pixels) / 2)
      $errorY = [Math]::Abs(($minY + $maxY + 1 - $pixels) / 2)
      $checks++
      if ($maxX -lt 0 -or $errorX -gt 1 -or $errorY -gt 1) {
        $failures++
        Write-Host "FAIL '$label' size=$fontSize scale=$scale offset=$errorX,$errorY pixels"
      }
    }
  }
}
Write-Host "$checks rendered text checks; $failures failures (one physical pixel tolerance)."
if ($failures) { exit 1 }
