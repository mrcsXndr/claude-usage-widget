$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'lib\Usage.ps1')
$script:failures = 0

function Assert-Provider([string]$name, [bool]$condition) {
  if (-not $condition) { $script:failures++; Write-Host "FAIL $name" } else { Write-Host "PASS $name" }
}

function New-HttpClient { [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Dispose -Value {} -PassThru }
function Get-AccountToken($account) {
  if ($account.source -eq 'codex') { throw 'Codex must not enter Claude token handling' }
  return 'fixture-not-a-token'
}
function Read-UsageApi($client, $token) {
  [pscustomobject]@{ five_h = (New-Window 0 $null); seven_d = (New-Window 25 $null); fable = (New-Window $null $null) }
}
function Read-ProfilePlan($client, $token) { 'Pro' }
function Read-CodexAccount($account) {
  [pscustomobject]@{
    name = $account.name; label = $account.label; plan = 'plus'; provider = 'codex'
    status = $(if ($account.name -eq 'offline') { 'error' } else { 'ok' })
    error = $(if ($account.name -eq 'offline') { 'offline fixture' } else { $null })
    five_h = (New-Window $null $null); seven_d = (New-Window 31 $null); fable = (New-Window $null $null)
  }
}

$config = [pscustomobject]@{ accounts = @(
  [pscustomobject]@{ name = 'claude'; label = 'Claude'; source = 'claude-code' }
  [pscustomobject]@{ name = 'codex'; label = 'Codex'; source = 'codex' }
  [pscustomobject]@{ name = 'offline'; label = 'Offline'; source = 'codex' }
  [pscustomobject]@{ name = 'claude-after'; label = 'Claude after'; source = 'env' }
) }
$rows = @(Get-AllUsage $config)
Assert-Provider 'mixed provider ordering preserved' (($rows.name -join ',') -eq 'claude,codex,offline,claude-after')
Assert-Provider 'Claude zero percent preserved' ($rows[0].five_h.pct -eq 0 -and $rows[0].provider -eq 'claude')
Assert-Provider 'Codex routed without Claude token handling' ($rows[1].status -eq 'ok' -and $rows[1].provider -eq 'codex' -and $rows[1].apiPlan -eq 'plus')
Assert-Provider 'missing Codex primary not fabricated' ($null -eq $rows[1].five_h.pct)
Assert-Provider 'one failed provider does not prevent next account' ($rows[2].status -eq 'error' -and $rows[3].status -eq 'ok')
Assert-Provider 'profile comparison normalizes path and case' (Test-SameAccount ([pscustomobject]@{name='one';source='codex';dir='C:\profiles\work\'}) ([pscustomobject]@{name='two';source='codex';dir='c:\profiles\work'}))
Assert-Provider 'provider profiles do not merge by directory' (-not (Test-SameAccount ([pscustomobject]@{name='one';source='codex';dir='C:\profiles\work'}) ([pscustomobject]@{name='two';source='claude-code';dir='C:\profiles\work'})))

Add-Type -AssemblyName System.IO.Compression.FileSystem
$scratch = Join-Path $PSScriptRoot ('.provider-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $scratch | Out-Null
try {
  foreach ($case in @(@('2.0.0', $false, $true), @('2.1.0', $false, $false), @('2.1.0', $true, $true))) {
    $zipPath = Join-Path $scratch ([guid]::NewGuid().ToString('N') + '.zip')
    $archive = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
      $entry = $archive.CreateEntry('ClaudeUsageWidget.ps1')
      $writer = New-Object IO.StreamWriter($entry.Open())
      try { $writer.Write('fixture') } finally { $writer.Dispose() }
      $entry = $archive.CreateEntry('lib/Usage.ps1')
      $writer = New-Object IO.StreamWriter($entry.Open())
      try { $writer.Write("`$AppVersion = '$($case[0])'") } finally { $writer.Dispose() }
      if ($case[1]) { [void]$archive.CreateEntry('lib/Codex.ps1') }
    } finally { $archive.Dispose() }
    $accepted = $false
    try { $accepted = (Get-ZipVersion $zipPath) -eq $case[0] } catch {}
    Assert-Provider "release $($case[0]) Codex=$($case[1]) completeness" ($accepted -eq $case[2])
  }
} finally {
  $scratchPath = [IO.Path]::GetFullPath($scratch)
  $distPath = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
  if (-not $scratchPath.StartsWith($distPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected scratch path' }
  Remove-Item -LiteralPath $scratchPath -Recurse -Force
}
if ($script:failures) { throw "$($script:failures) provider check(s) failed" }
'All mixed-provider checks passed'
