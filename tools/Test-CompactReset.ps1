$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$trees = @{}
foreach ($file in 'ClaudeUsageWidget.ps1', 'lib/Usage.ps1') {
  $errors = $null
  $trees[$file] = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$null, [ref]$errors)
  if ($errors.Count) { throw ($errors | Out-String) }
}
foreach ($name in 'ConvertTo-LocalTime', 'Format-ClockShort', 'Format-ResetShort', 'Format-ResetLong',
    'Get-TimeFormat', 'Get-Reset', 'Get-ResetLong', 'Get-TaskbarReset', 'Format-ResetAt', 'Format-ResetIn', 'Get-NextText') {
  $definition = @($trees.Values | ForEach-Object {
    $_.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  } | Where-Object { $_ })[0]
  if (-not $definition) { throw "Missing function $name" }
  Invoke-Expression $definition.Extent.Text
}
$DayCodes = @('Su', 'M', 'Tu', 'W', 'Th', 'F', 'Sa')
$script:now = [datetime]'2026-11-04 12:00:00'
function Get-Date { $script:now }
function Get-SizeKey { $script:size }
$script:config = [pscustomobject]@{ timeFormat = '12h' }
$script:size = 'compact'
$DASH = '-'
$checks = 0
function Assert-Equal($label, $actual, $expected) {
  $script:checks++
  if ("$actual" -cne "$expected") { throw "$label : got [$actual], expected [$expected]" }
}
foreach ($fmt in '12h', '24h') {
  $script:config.timeFormat = $fmt
  $is12 = $fmt -eq '12h'
  Assert-Equal 'minutes rounded' (Get-TaskbarReset ([datetime]'2026-11-04 17:14:00')) $(if ($is12) { '~6pm' } else { '~18:00' })
  Assert-Equal 'seconds rounded' (Get-TaskbarReset ([datetime]'2026-11-04 17:00:01')) $(if ($is12) { '~6pm' } else { '~18:00' })
  Assert-Equal 'exact five hours' (Get-TaskbarReset $now.AddHours(5)) $(if ($is12) { '5pm' } else { '17:00' })
  Assert-Equal 'midnight rollover' (Get-TaskbarReset ([datetime]'2026-11-04 23:14:00')) $(if ($is12) { 'Th ~12am' } else { 'Th ~00:00' })
  Assert-Equal 'exact midnight' (Get-TaskbarReset ([datetime]'2026-11-05 00:00:00')) $(if ($is12) { 'Th 12am' } else { 'Th 00:00' })
  foreach ($minutes in 0.3, 37, 59.5, 60, 134, 298, 299.5) {
    $reset = $now.AddMinutes($minutes)
    Assert-Equal "unchanged short wait $minutes" (Get-TaskbarReset $reset) (Format-ResetShort $reset $fmt $now)
    Assert-Equal 'resetin unchanged' (Get-NextText resetin 42 '' $reset) (Format-ResetIn $reset)
  }
  Assert-Equal 'resetat short absolute' (Get-NextText resetat 42 '' $now.AddMinutes(14)) $(if ($is12) { '~1pm' } else { '~13:00' })
  Assert-Equal 'resetat exact hour' (Get-NextText resetat 42 '' $now.AddHours(1)) $(if ($is12) { '1pm' } else { '13:00' })
  for ($day = 1; $day -le 7; $day++) {
    $reset = $now.Date.AddDays($day).AddHours(17).AddMinutes(14)
    Assert-Equal 'day codes' (Get-TaskbarReset $reset) "$($DayCodes[[int]$reset.DayOfWeek]) $(if ($is12) { '~6pm' } else { '~18:00' })"
  }
  $reset = [datetime]'2026-11-04 17:14:00'
  Assert-Equal 'UTC input' (Get-TaskbarReset $reset.ToUniversalTime().ToString('o')) (Get-TaskbarReset $reset)
  Assert-Equal 'list exact' (Get-Reset $reset) $(if ($is12) { '5:14pm' } else { '17:14' })
  Assert-Equal 'tooltip exact' (Get-ResetLong $reset) $(if ($is12) { 'Resets today 5:14 pm (in 5h 14m)' } else { 'Resets today 17:14 (in 5h 14m)' })
  foreach ($script:size in 'normal', 'large') {
    Assert-Equal 'other size usage' (Get-TaskbarReset $reset) (Get-Reset $reset)
    Assert-Equal 'other size resetat' (Get-NextText resetat 42 '' $reset) (Format-ResetAt $reset)
  }
  $script:size = 'compact'
}
foreach ($reset in @($null, '', $now, $now.AddSeconds(-1))) {
  Assert-Equal 'missing or expired' (Get-TaskbarReset $reset) ''
  Assert-Equal 'missing or expired absolute' (Get-NextText resetat 42 '' $reset) $DASH
}
# Verify the taskbar call sites use the new helper while exact display paths retain theirs.
foreach ($pair in @(
    @('Get-UsageTextXaml', 'Get-TaskbarReset'), @('New-LimitGroupElement', 'Get-TaskbarReset'),
    @('Get-WindowRowXaml', 'Get-Reset'), @('Get-RingTip', 'Get-ResetLong'), @('Get-LimitGroupTip', 'Get-Reset'))) {
  $name = $pair[0]
  $definition = $trees['ClaudeUsageWidget.ps1'].Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  $commands = @($definition.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
  Assert-Equal "$name formatter" ($commands -contains $pair[1]) $true
}
Write-Host "$checks compact reset checks passed."
