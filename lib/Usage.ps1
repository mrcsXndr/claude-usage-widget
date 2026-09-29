# Account config, token sources and usage reads. No UI: the widget dot-sources this
# on the UI thread (config paths) and in a background runspace (the actual fetch).
#
# Two ways to read an account's 5h / 7d usage:
#   usage-api  GET /api/oauth/usage. Free, but needs a token with the user:profile
#              scope (a `claude login` token). Setup-tokens get a 403.
#   probe      A 1-token Haiku request; the unified rate-limit headers on the reply
#              carry the same numbers. Works for any token and costs a handful of tokens.
# Each account tries the usage API first; a scope 403 switches it to the probe for
# the rest of the session.

$AppDir     = Join-Path $env:APPDATA 'claude-usage-widget'
$ConfigPath = Join-Path $AppDir 'config.json'
$StatePath  = Join-Path $AppDir 'state.json'
$LogPath    = Join-Path $AppDir 'widget.log'

$UsageUrl   = 'https://api.anthropic.com/api/oauth/usage'
$ProbeUrl   = 'https://api.anthropic.com/v1/messages'
$ProbeModel = 'claude-haiku-4-5-20251001'
$UserAgent  = 'claude-usage-widget/1.0 (+https://github.com/mrcsXndr/claude-usage-widget)'

function Write-Log([string]$msg) {
  try {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    Add-Content $LogPath ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg)
  } catch {}
}

function Get-ClaudeConfigDir {
  if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
  return Join-Path $HOME '.claude'
}

function Get-XndrClaudeHome {
  if ($env:XNDR_CLAUDE_HOME) { return $env:XNDR_CLAUDE_HOME }
  return Join-Path $HOME '.xndr-claude'
}

function Test-Command([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Runs a command line through cmd (so npm shims and PATH lookups work) and captures its output.
function Invoke-Captured([string]$commandLine, [int]$timeoutSec = 30) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = "/d /s /c `"$commandLine`""
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  try {
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
      try { $p.Kill() } catch {}
      throw "timed out after ${timeoutSec}s"
    }
    $p.WaitForExit()
    return [pscustomobject]@{ exit = $p.ExitCode; out = $out.Result; err = $err.Result }
  } finally {
    $p.Dispose()
  }
}

function Get-LastLine([string]$text) {
  ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
}

# ---------------------------------------------------------------- config

# Claude Code's own login (~/.claude/.credentials.json). Read-only: we never refresh it,
# because refreshing rotates the refresh token and would log Claude Code out.
function Get-ClaudeCodeLogin {
  $path = Join-Path (Get-ClaudeConfigDir) '.credentials.json'
  if (-not (Test-Path $path)) { return $null }
  try { $o = (Get-Content $path -Raw | ConvertFrom-Json).claudeAiOauth } catch { return $null }
  if (-not $o -or -not $o.accessToken) { return $null }
  $expires = if ($o.expiresAt) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$o.expiresAt).UtcDateTime } else { $null }
  return [pscustomobject]@{ token = $o.accessToken; expires = $expires; plan = $o.subscriptionType }
}

# One-time import of xndr-claude's accounts. `usage --json` is its only machine-readable
# listing, so this costs one probe per account, once.
function Import-XndrClaudeAccounts {
  if (-not (Test-Command 'xndr-claude')) { return @() }
  try {
    $r = Invoke-Captured 'xndr-claude usage --json' 60
    if ($r.exit -ne 0) { throw (Get-LastLine $r.err) }
    $list = @()
    foreach ($a in (ConvertFrom-Json $r.out)) {
      $list += [ordered]@{ name = $a.name; label = $a.label; plan = $a.plan; source = 'xndr-claude' }
    }
    return $list
  } catch {
    Write-Log "xndr-claude import failed: $_"
    return @()
  }
}

function New-DefaultConfig {
  $accounts = @(Import-XndrClaudeAccounts)
  $login = Get-ClaudeCodeLogin
  if ($login -and (-not $accounts.Count -or ($login.expires -and $login.expires -gt [DateTime]::UtcNow))) {
    $plan = if ($login.plan) { (Get-Culture).TextInfo.ToTitleCase($login.plan) } else { $null }
    $accounts += [ordered]@{ name = 'claude-code'; label = 'Claude Code login'; plan = $plan; source = 'claude-code' }
  }
  return [ordered]@{ refreshMinutes = 30; accounts = $accounts }
}

# Reads config.json, creating it on first run.
function Read-Config {
  if (-not (Test-Path $ConfigPath)) {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    $cfg = New-DefaultConfig
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
  }
  $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
  if (-not $cfg.refreshMinutes) { $cfg | Add-Member -Force refreshMinutes 30 }
  if (-not $cfg.accounts) { $cfg | Add-Member -Force accounts @() }
  return $cfg
}

# ---------------------------------------------------------------- tokens

function Get-AccountToken($acct) {
  switch ($acct.source) {
    'claude-code' {
      $login = Get-ClaudeCodeLogin
      if (-not $login) { throw 'no Claude Code login found' }
      if ($login.expires -and $login.expires -le [DateTime]::UtcNow) { throw 'Claude Code login expired; run claude to refresh it' }
      return $login.token
    }
    'xndr-claude' {
      $name = if ($acct.account) { $acct.account } else { $acct.name }
      if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "bad xndr-claude account name '$name'" }
      return Get-CommandToken "xndr-claude token $name"
    }
    'command' { return Get-CommandToken $acct.command }
    'env' {
      $t = [Environment]::GetEnvironmentVariable($acct.env)
      if (-not $t) { throw "environment variable $($acct.env) is not set" }
      return $t.Trim()
    }
    default { throw "unknown source '$($acct.source)'" }
  }
}

function Get-CommandToken([string]$commandLine) {
  if (-not $commandLine) { throw 'no token command' }
  $r = Invoke-Captured $commandLine 30
  # stderr only: stdout is the token and must never reach a message or log.
  if ($r.exit -ne 0) { throw "token command failed ($($r.exit)): $(Get-LastLine $r.err)" }
  $t = $r.out.Trim()
  if (-not $t) { throw 'token command printed nothing' }
  return $t
}

# ---------------------------------------------------------------- usage reads

Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function New-HttpClient {
  $c = New-Object System.Net.Http.HttpClient
  $c.Timeout = [TimeSpan]::FromSeconds(15)
  [void]$c.DefaultRequestHeaders.UserAgent.TryParseAdd($UserAgent)
  return $c
}

function Send-Request($client, [string]$method, [string]$url, [string]$token, [string]$body) {
  $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod $method), $url)
  $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
  [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
  if ($body) {
    [void]$req.Headers.TryAddWithoutValidation('anthropic-version', '2023-06-01')
    $req.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
  }
  try {
    return $client.SendAsync($req).GetAwaiter().GetResult()
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    throw "network: $($e.Message)"
  }
}

function New-Window($pct, $reset) {
  [pscustomobject]@{ pct = $pct; reset = $reset }
}

# Free read. Returns $null when this token can't use the endpoint (so the caller probes instead).
function Read-UsageApi($client, [string]$token) {
  $res = Send-Request $client 'GET' $UsageUrl $token $null
  try {
    $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $code = [int]$res.StatusCode
    if ($code -eq 200) {
      $j = ConvertFrom-Json $text
      $win = {
        param($w)
        if (-not $w) { return New-Window $null $null }
        $reset = if ($w.resets_at -is [DateTime]) { $w.resets_at.ToUniversalTime().ToString('o') } else { $w.resets_at }
        New-Window ([double]$w.utilization) $reset
      }
      return [pscustomobject]@{ http = 200; five_h = (& $win $j.five_hour); seven_d = (& $win $j.seven_day) }
    }
    if ($code -eq 403 -and $text -match 'oauth_scope_insufficient|scope requirement') { return [pscustomobject]@{ noScope = $true } }
    if ($code -eq 401) { return [pscustomobject]@{ http = 401; invalid = $true } }
    return [pscustomobject]@{ http = $code; retry = $true }  # 429s are common here; the probe still works
  } finally { $res.Dispose() }
}

# 1-token Haiku request; the numbers ride on the response headers (also on a 429).
function Read-Probe($client, [string]$token) {
  $body = '{"model":"' + $ProbeModel + '","max_tokens":1,"messages":[{"role":"user","content":"."}]}'
  $res = Send-Request $client 'POST' $ProbeUrl $token $body
  try {
    $code = [int]$res.StatusCode
    if ($code -eq 401 -or $code -eq 403) { return [pscustomobject]@{ http = $code; invalid = $true } }
    $h = {
      param($name)
      $vals = $null
      if ($res.Headers.TryGetValues("anthropic-ratelimit-unified-$name", [ref]$vals)) { return @($vals)[0] }
      return $null
    }
    $win = {
      param($key)
      $u = & $h "$key-utilization"; $r = & $h "$key-reset"
      $pct = if ($u) { [Math]::Round([double]::Parse($u, [Globalization.CultureInfo]::InvariantCulture) * 100, 1) } else { $null }
      $reset = if ($r) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$r).UtcDateTime.ToString('o') } else { $null }
      New-Window $pct $reset
    }
    $five = & $win '5h'; $seven = & $win '7d'
    if ($null -eq $five.pct -and $null -eq $seven.pct) { return [pscustomobject]@{ http = $code; error = "http $code, no usage headers" } }
    return [pscustomobject]@{ http = $code; five_h = $five; seven_d = $seven }
  } finally { $res.Dispose() }
}

# Reads every configured account. $MethodCache (name -> 'probe') persists across calls
# so accounts whose token lacks the profile scope skip the usage API after the first try.
# Results never contain a token.
function Get-AllUsage($Config, [hashtable]$MethodCache = @{}) {
  $client = New-HttpClient
  try {
    foreach ($a in @($Config.accounts)) {
      $row = [ordered]@{
        name = $a.name; label = $(if ($a.label) { $a.label } else { $a.name }); plan = $a.plan
        status = 'error'; error = $null; method = $null
        five_h = (New-Window $null $null); seven_d = (New-Window $null $null)
      }
      try {
        $token = Get-AccountToken $a
        $r = $null
        if ($MethodCache[$a.name] -ne 'probe') {
          $r = Read-UsageApi $client $token
          if ($r.noScope) { $MethodCache[$a.name] = 'probe'; $r = $null }
          elseif ($r.retry) { $r = $null }
          else { $row.method = 'usage-api' }
        }
        if (-not $r) { $r = Read-Probe $client $token; $row.method = 'probe' }
        if ($r.invalid) { $row.status = 'invalid'; $row.error = "token invalid (http $($r.http))" }
        elseif ($r.error) { $row.error = $r.error }
        else {
          $row.five_h = $r.five_h; $row.seven_d = $r.seven_d
          $row.status = if ($r.http -eq 429) { 'limited' } else { 'ok' }
        }
      } catch {
        $row.error = "$_"
      } finally {
        $token = $null
      }
      [pscustomobject]$row
    }
  } finally {
    $client.Dispose()
  }
}
