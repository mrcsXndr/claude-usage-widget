$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'lib\Usage.ps1')
$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ClaudeUsageWidget.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in 'Esc', 'Test-CodexAccount', 'Get-RawWin', 'Get-Caption', 'Format-Pct', 'ConvertTo-LocalTime', 'Get-TimeFormat', 'Get-Reset', 'Get-ResetLong', 'Get-UsageColor', 'Get-WindowRowXaml', 'Get-CodexQuotaRowsXaml') {
  $definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Invoke-Expression $definition.Extent.Text
}
$Theme = @{ fg = '#FFFFFF'; sub = '#AAAAAA'; bar = '#333333' }
$Colors = @{ ok = '#00FF00'; warn = '#FFFF00'; bad = '#FF0000'; none = '#AAAAAA' }
$FontIcons = 'Segoe UI'
$script:config = [pscustomobject]@{ timeFormat = '24h' }
$cfg = [pscustomobject]@{ source = 'codex' }
$reset = (Get-Date).AddDays(2).Date.AddHours(14).AddMinutes(23).ToUniversalTime().ToString('o')
$res = [pscustomobject]@{ status = 'ok'; quotaBuckets = @(
  [pscustomobject]@{ id = 'codex'; name = 'General Codex' },
  [pscustomobject]@{ id = 'sol'; name = 'Sol & test'; normalModelSlug = 'reported-model'; status = 'limited'; rateLimitReachedType = 'rate_limit_reached'; five_h = [pscustomobject]@{ pct = 100; reset = $reset; minutes = 300 }; seven_d = $null },
  [pscustomobject]@{ id = 'weekly'; name = 'Weekly'; status = 'ok'; five_h = $null; seven_d = [pscustomobject]@{ pct = 0; reset = $reset; minutes = 10080 } },
  [pscustomobject]@{ id = 'unknown'; name = 'Unknown'; status = 'error'; five_h = $null; seven_d = $null }
) }
$markup = Get-CodexQuotaRowsXaml $cfg $res
$panel = [Windows.Markup.XamlReader]::Parse("<StackPanel xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" Width=`"360`" Background=`"#222222`">$markup</StackPanel>")
foreach ($expected in 'Sol &amp; test', '100%', '0%', '5h', '7d', '14:23', 'rate limit reached', 'Usage not reported') {
  if (-not $markup.Contains($expected)) { throw "Missing rendered field: $expected" }
}
if ($markup.Contains('General Codex')) { throw 'General quota duplicated in extra rows' }
if ((Get-CodexQuotaRowsXaml ([pscustomobject]@{ source = 'claude-code' }) $res)) { throw 'Codex quotas shown for Claude' }
$empty = Get-CodexQuotaRowsXaml $cfg ([pscustomobject]@{ status = 'ok'; quotaBuckets = @() })
if (-not $empty.Contains('No model-specific limits reported')) { throw 'Missing unavailable-data explanation' }
$panel.Measure((New-Object Windows.Size(360, [double]::PositiveInfinity)))
$panel.Arrange((New-Object Windows.Rect(0, 0, 360, $panel.DesiredSize.Height)))
$bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(360, ([int][Math]::Ceiling($panel.DesiredSize.Height)), 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($panel)
$output = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $output | Out-Null
$encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$stream = [IO.File]::Create((Join-Path $output 'quota-preview.png'))
try { $encoder.Save($stream) } finally { $stream.Dispose() }
'PASS quota names, XML escaping, percentages, durations, exact resets, reasons, unknown data and Claude isolation; WPF rendering passed'
