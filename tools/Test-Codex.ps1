param([switch]$Mock)

$ErrorActionPreference = 'Stop'
if ($Mock) {
  $scratch = $env:CUW_CODEX_TEST_ROOT
  $mode = $env:CUW_CODEX_TEST_MODE
  [IO.File]::WriteAllText((Join-Path $scratch 'pid.txt'), [string]$PID)
  [IO.File]::WriteAllText((Join-Path $scratch 'home.txt'), $env:CODEX_HOME)
  [Console]::Error.Write(('sensitive-stderr-' * 10000))
  if ($mode -eq 'timeout') {
    $child = Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
    [IO.File]::WriteAllText((Join-Path $scratch 'child.txt'), [string]$child.Id)
    Start-Sleep -Seconds 60
    exit
  }
  $first = [Console]::ReadLine()
  [IO.File]::AppendAllText((Join-Path $scratch 'requests.jsonl'), $first + "`n")
  if ($mode -eq 'eof') { exit }
  if ($mode -eq 'malformed') { [Console]::WriteLine('sensitive-protocol-invalid'); exit }
  if ($mode -eq 'out-of-order') { [Console]::WriteLine('{"id":3,"result":{}}'); exit }
  if ($mode -eq 'rpc') { [Console]::WriteLine('{"id":1,"error":{"message":"sensitive-token-value"}}'); exit }
  [Console]::WriteLine('{"method":"account/updated","params":{}}')
  [Console]::WriteLine('{"id":1,"result":{}}')
  foreach ($requestNumber in 1..2) {
    $line = [Console]::ReadLine()
    [IO.File]::AppendAllText((Join-Path $scratch 'requests.jsonl'), $line + "`n")
  }
  $account = switch ($mode) {
    'null-account' { 'null' }
    'api-key' { '{"type":"apiKey"}' }
    default { '{"type":"chatgpt","email":"private@example.com","planType":"pro"}' }
  }
  [Console]::WriteLine('{"id":2,"result":{"account":' + $account + '}}')
  if ($mode -in @('null-account', 'api-key')) { Start-Sleep -Seconds 60; exit }
  $line = [Console]::ReadLine()
  [IO.File]::AppendAllText((Join-Path $scratch 'requests.jsonl'), $line + "`n")
  $usage = [IO.File]::ReadAllText((Join-Path $scratch 'usage.json'))
  [Console]::WriteLine('{"id":3,"result":' + $usage + '}')
  Start-Sleep -Seconds 60
  exit
}

$root = Split-Path $PSScriptRoot
. (Join-Path $root 'lib\Codex.ps1')
$scratch = Join-Path $PSScriptRoot ('.codex-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$originalCodexHome = $env:CODEX_HOME
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$originalStart = ${function:Start-CodexProcess}
$originalFind = ${function:Find-CodexExecutable}
$passed = 0
function Check([string]$name, [bool]$condition) {
  if (-not $condition) { throw "FAIL: $name" }
  $script:passed++
  Write-Output "PASS: $name"
}
function Write-Usage($value) {
  [IO.File]::WriteAllText((Join-Path $scratch 'usage.json'), ($value | ConvertTo-Json -Depth 12 -Compress))
}
function Run-Mock([string]$mode, [int]$seconds = 6) {
  $script:mockMode = $mode
  foreach ($file in 'pid.txt', 'child.txt', 'requests.jsonl') {
    $path = Join-Path $scratch $file
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
  }
  $row = Read-CodexAccount $script:acct $seconds
  $pidFile = Join-Path $scratch 'pid.txt'
  if ([IO.File]::Exists($pidFile)) {
    $mockId = [int][IO.File]::ReadAllText($pidFile)
    $settle = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Process -Id $mockId -ErrorAction SilentlyContinue) -and $settle.ElapsedMilliseconds -lt 1000) { Start-Sleep -Milliseconds 25 }
    Check "$mode process cleaned up" ($null -eq (Get-Process -Id $mockId -ErrorAction SilentlyContinue)) | Out-Host
  }
  Check "$mode errors sanitized" (($row | ConvertTo-Json -Depth 8 -Compress) -notmatch 'sensitive-|private@example') | Out-Host
  return $row
}

try {
  $env:TEMP = $scratch
  $env:TMP = $scratch
  $active = Join-Path $scratch 'custom-active'
  $profile = Join-Path $scratch '.codex-work'
  $default = Join-Path $scratch '.codex'
  foreach ($dir in @($active, $profile, $default, (Join-Path $scratch '.codex-empty'))) { [void][IO.Directory]::CreateDirectory($dir) }
  foreach ($dir in @($active, $profile, $default)) { [IO.File]::WriteAllText((Join-Path $dir 'auth.json'), 'not-json-never-read') }
  $env:CODEX_HOME = $active
  Check 'active home resolved' ((Get-CodexHome) -eq $active)
  $accounts = @(Find-CodexAccounts $scratch)
  Check 'active and authenticated sibling only' ($accounts.Count -eq 2 -and $accounts.dir -contains $active -and $accounts.dir -contains $profile)
  Check 'stable private names and labels' (@($accounts | Where-Object { $_.source -ne 'codex' -or $_.label -ne 'Codex' -or $_.name -notmatch '^codex-[0-9a-f]{24}$' }).Count -eq 0)
  $again = @(Find-CodexAccounts $scratch)
  Check 'names stable and unique' (($accounts.name -join ',') -eq ($again.name -join ',') -and @($accounts.name | Select-Object -Unique).Count -eq 2)
  $env:CODEX_HOME = $profile.ToUpperInvariant() + '\'
  Check 'normalized paths deduplicated' (@(Find-CodexAccounts $scratch).Count -eq 1)
  $env:CODEX_HOME = $null
  Check 'default home discovered' (@(Find-CodexAccounts $scratch).dir -contains $default)
  Check 'profile validation boolean' ((Test-CodexProfile $active) -and -not (Test-CodexProfile (Join-Path $scratch 'absent')) -and -not (Test-CodexProfile ''))
  $env:CODEX_HOME = 'parent-env-sentinel'
  $script:acct = $accounts[0]
  function Find-CodexExecutable { return 'mock-codex.exe' }
  function Start-CodexProcess($startInfo) {
    Check 'hidden redirected child' ($startInfo.CreateNoWindow -and -not $startInfo.UseShellExecute -and $startInfo.RedirectStandardError -and $startInfo.RedirectStandardOutput -and $startInfo.RedirectStandardInput) | Out-Host
    Check 'fixed app-server arguments' ($startInfo.Arguments -eq 'app-server') | Out-Host
    $startInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mock'
    $startInfo.EnvironmentVariables['CUW_CODEX_TEST_ROOT'] = $scratch
    $startInfo.EnvironmentVariables['CUW_CODEX_TEST_MODE'] = $script:mockMode
    return [Diagnostics.Process]::Start($startInfo)
  }
  $primary = @{ usedPercent = 0; resetsAt = 1730947200; windowDurationMins = 300 }
  $secondary = @{ usedPercent = 100; resetsAt = $null; windowDurationMins = 10080 }
  Write-Usage @{ rateLimitsByLimitId = @{ codex = @{ limitId = 'codex'; primary = $primary; secondary = $secondary }; other = @{ primary = @{ usedPercent = 99 } } }; rateLimits = @{ primary = @{ usedPercent = 88 } } }
  $result = @(Run-Mock 'good')[-1]
  Check 'standard row contract' ($result.name -eq $acct.name -and $result.label -eq 'Codex' -and $result.plan -eq 'pro' -and $result.apiPlan -eq 'pro' -and $result.provider -eq 'codex' -and $result.method -eq 'codex-app-server' -and $null -eq $result.fable -and $null -eq $result.error)
  Check 'zero retained and codex bucket preferred' ($null -ne $result.five_h.pct -and $result.five_h.pct -eq 0 -and $result.seven_d.pct -eq 100 -and $result.status -eq 'limited')
  Check 'reset and duration preserved' ($result.five_h.reset -eq '2024-11-07T02:40:00.0000000Z' -and $result.five_h.minutes -eq 300 -and $result.seven_d.minutes -eq 10080 -and $null -eq $result.seven_d.reset)
  $requests = @(Get-Content (Join-Path $scratch 'requests.jsonl') | ConvertFrom-Json)
  Check 'documented handshake order' (($requests.method -join ',') -eq 'initialize,initialized,account/read,account/rateLimits/read' -and $requests[0].params.clientInfo.name -eq 'usage_widget' -and $requests[2].params.refreshToken -eq $false)
  Check 'fallback client version' ($requests[0].params.clientInfo.version -eq '2.1.0')
  Check 'home scoped to child' ($env:CODEX_HOME -eq 'parent-env-sentinel' -and [IO.File]::ReadAllText((Join-Path $scratch 'home.txt')) -eq $acct.dir)
  Check 'all map buckets included' ($result.quotaBuckets -is [array] -and $result.quotaBuckets.Count -eq 2)
  $general = @($result.quotaBuckets | Where-Object id -eq 'codex')[0]
  Check 'general bucket normalized' ($general.name -eq 'General Codex' -and $general.five_h.pct -eq 0 -and $general.seven_d.pct -eq 100 -and $general.status -eq 'limited' -and $null -eq $general.normalModelSlug)
  Check 'exact bucket schema' (($general.PSObject.Properties.Name -join ',') -eq 'id,name,normalModelSlug,five_h,seven_d,status,rateLimitReachedType')
  Write-Usage @{ rateLimitsByLimitId = @{
    codex = @{ primary = @{ usedPercent = 1 }; rateLimitReachedType = 'workspace_owner_credits_depleted' }
    sol = @{ limitId = 'sol'; limitName = 'Sol'; normalModelSlug = 'reported-model'; primary = @{ usedPercent = 100 }; rateLimitReachedType = 'rate_limit_reached' }
    unnamed = @{ secondary = @{ usedPercent = 0; windowDurationMins = 10080 } }
    missing = @{}
    broken = @{ primary = @{ usedPercent = 'invalid' }; secondary = @{ usedPercent = 42 } }
    blank = @{ primary = @{ usedPercent = '' } }
    nullBucket = $null
    serverOnly = @{ rateLimitReachedType = 'workspace_member_usage_limit_reached' }
  }; rateLimits = @{ primary = @{ usedPercent = 99 } } }
  $result = @(Run-Mock 'multi-bucket')[-1]
  $buckets = @{}
  foreach ($item in $result.quotaBuckets) { $buckets[$item.id] = $item }
  Check 'Sol 100 does not limit general 1 row' ($result.five_h.pct -eq 1 -and $result.status -eq 'ok' -and $null -eq $result.error -and $buckets.sol.status -eq 'limited' -and $buckets.sol.five_h.pct -eq 100)
  Check 'reported label and alias retained' ($buckets.sol.name -eq 'Sol' -and $buckets.sol.normalModelSlug -eq 'reported-model' -and $buckets.sol.rateLimitReachedType -eq 'rate_limit_reached')
  Check 'server state affects bucket only' ($buckets.codex.status -eq 'limited' -and $buckets.codex.rateLimitReachedType -eq 'workspace_owner_credits_depleted' -and $buckets.serverOnly.status -eq 'limited' -and $null -eq $buckets.serverOnly.five_h.pct)
  Check 'id fallback without invented alias' ($buckets.unnamed.name -eq 'unnamed' -and $null -eq $buckets.unnamed.normalModelSlug -and $null -eq $buckets.unnamed.rateLimitReachedType)
  Check 'secondary only and zero preserved' ($null -eq $buckets.unnamed.five_h.pct -and $null -eq $buckets.unnamed.five_h.reset -and $null -eq $buckets.unnamed.five_h.minutes -and $null -ne $buckets.unnamed.seven_d.pct -and $buckets.unnamed.seven_d.pct -eq 0 -and $buckets.unnamed.status -eq 'ok')
  Check 'missing windows never zero' ($buckets.missing.status -eq 'error' -and $null -eq $buckets.missing.five_h.pct -and $null -eq $buckets.missing.seven_d.pct -and $null -eq $buckets.sol.seven_d.pct)
  Check 'malformed bucket isolated with valid window retained' ($result.quotaBuckets.Count -eq 8 -and $buckets.broken.status -eq 'error' -and $null -eq $buckets.broken.five_h.pct -and $buckets.broken.seven_d.pct -eq 42)
  Check 'blank and null buckets never zero' ($buckets.blank.status -eq 'error' -and $null -eq $buckets.blank.five_h.pct -and $buckets.nullBucket.status -eq 'error' -and $null -eq $buckets.nullBucket.five_h.pct)
  Write-Usage @{ rateLimits = @{ primary = $primary; secondary = $null } }
  $AppVersion = '2.1.0-test'
  $result = @(Run-Mock 'legacy')[-1]
  $requests = @(Get-Content (Join-Path $scratch 'requests.jsonl') | ConvertFrom-Json)
  Check 'parent client version' ($requests[0].params.clientInfo.version -eq $AppVersion)
  Remove-Variable -Name AppVersion
  Check 'legacy bucket and absent window' ($result.status -eq 'ok' -and $result.five_h.pct -eq 0 -and $null -eq $result.seven_d.pct -and $null -eq $result.seven_d.minutes)
  Check 'legacy normalized as general array' ($result.quotaBuckets -is [array] -and $result.quotaBuckets.Count -eq 1 -and $result.quotaBuckets[0].id -eq 'codex' -and $result.quotaBuckets[0].name -eq 'General Codex' -and $null -eq $result.quotaBuckets[0].seven_d.pct)
  Write-Usage @{ rateLimitsByLimitId = @{ sol = @{ primary = $secondary } }; rateLimits = @{ limitId = 'codex'; limitName = 'Reported General'; primary = $primary } }
  $result = @(Run-Mock 'mixed-legacy')[-1]
  Check 'legacy general fallback alongside extra bucket' ($result.status -eq 'ok' -and $result.quotaBuckets.Count -eq 2 -and @($result.quotaBuckets | Where-Object id -eq 'codex')[0].name -eq 'Reported General')
  Write-Usage @{ rateLimitsByLimitId = @{ other = @{ primary = $secondary } }; rateLimits = @{ limitId = 'other'; primary = $secondary } }
  $result = @(Run-Mock 'other-bucket')[-1]
  Check 'model buckets rejected' ($result.status -eq 'error' -and $result.error -like 'No Codex quota*')
  Check 'extra bucket retained without general' ($result.quotaBuckets.Count -eq 1 -and $result.quotaBuckets[0].id -eq 'other' -and $result.quotaBuckets[0].status -eq 'limited' -and $null -eq $result.five_h.pct)
  Write-Usage @{ rateLimits = @{ primary = @{ usedPercent = $null }; secondary = $null } }
  $result = @(Run-Mock 'null-windows')[-1]
  Check 'null is not zero' ($result.status -eq 'error' -and $null -eq $result.five_h.pct)
  Write-Usage @{ rateLimits = @{ primary = $primary } }
  foreach ($mode in 'null-account', 'api-key', 'rpc', 'malformed', 'out-of-order', 'eof') {
    $result = @(Run-Mock $mode)[-1]
    Check "$mode returns error row" ($result.status -eq 'error' -and $null -ne $result.error)
    if ($mode -in @('null-account', 'api-key')) {
      Check "$mode skips rate limits" ((Get-Content (Join-Path $scratch 'requests.jsonl') -Raw) -notmatch 'rateLimits/read')
    }
  }
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $result = @(Run-Mock 'timeout' 2)[-1]
  Check 'timeout bounded and sanitized' ($result.error -eq 'Codex usage request timed out.' -and $timer.Elapsed.TotalSeconds -lt 6)
  $childPath = Join-Path $scratch 'child.txt'
  Check 'timeout child was started' ([IO.File]::Exists($childPath))
  $childId = [int][IO.File]::ReadAllText($childPath)
  Check 'entire process tree cleaned up' ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue))
  function Find-CodexExecutable { throw 'codex-cli-missing' }
  $result = Read-CodexAccount $acct
  Check 'missing CLI error row' ($result.status -eq 'error' -and $result.error -like 'Codex CLI not found*')
  Check 'error row has empty bucket array' ($result.quotaBuckets -is [array] -and $result.quotaBuckets.Count -eq 0)
  $result = Read-CodexAccount ([pscustomobject]@{ name = 'missing'; dir = (Join-Path $scratch 'missing') })
  Check 'missing auth full row' ($result.status -eq 'error' -and $result.label -eq 'Codex' -and $result.error -like 'Codex profile is not signed in*' -and $null -eq $result.five_h.pct)
  foreach ($file in @((Join-Path $root 'lib\Codex.ps1'), $PSCommandPath)) {
    Check 'ASCII source' (@([IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0)
  }
  Write-Output "$passed checks passed."
} finally {
  $env:CODEX_HOME = $originalCodexHome
  $env:TEMP = $originalTemp
  $env:TMP = $originalTmp
  ${function:Start-CodexProcess} = $originalStart
  ${function:Find-CodexExecutable} = $originalFind
  $resolved = [IO.Path]::GetFullPath($scratch)
  $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
  if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like '.codex-test-*') {
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
