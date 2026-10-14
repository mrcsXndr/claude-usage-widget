# Account config, token sources and usage reads. No UI: the widget dot-sources this
# on the UI thread (config paths) and in a background runspace (the actual fetch).
#
# Two ways to read an account's 5h / 7d usage:
#   usage-api  GET /api/oauth/usage. Free, but needs a token with the user:profile
#              scope (a `claude login` token). Setup-tokens get a 403.
#   probe      A 1-token request; the unified rate-limit headers on the reply carry
#              the same numbers. Works for any token and costs a few dozen tokens.
#              Sent to Fable it also returns the Fable weekly limit (header 7d_oi);
#              when Fable isn't usable for the account it falls back to Haiku.
# Each account tries the usage API first; a scope 403 switches it to the probe for
# the rest of the session.

$AppDir     = Join-Path $env:APPDATA 'claude-usage-widget'
$ConfigPath = Join-Path $AppDir 'config.json'
$StatePath  = Join-Path $AppDir 'state.json'
$LogPath    = Join-Path $AppDir 'widget.log'

$UsageUrl   = 'https://api.anthropic.com/api/oauth/usage'
$ProfileUrl = 'https://api.anthropic.com/api/oauth/profile'
$ProbeUrl   = 'https://api.anthropic.com/v1/messages'
$ProbeModel = 'claude-haiku-4-5-20251001'
$FableModel = 'claude-fable-5-1'
# OAuth tokens only reach models other than Haiku with Claude Code's system prompt.
$ClaudeCodeSystem = "You are Claude Code, Anthropic's official CLI for Claude."
$LimitKeys  = @('5h', '7d', 'fable')
$DefaultCaptions = [ordered]@{ '5h' = '5h'; '7d' = '7d'; 'fable' = 'Fable' }
$AppVersion = '1.9.2'
# Self-update: the latest-release API, and the one zip "Update now" may download (the same asset install.ps1 uses).
$ReleaseApiUrl = 'https://api.github.com/repos/mrcsXndr/claude-usage-widget/releases/latest'
$UpdateZipUrl  = 'https://github.com/mrcsXndr/claude-usage-widget/releases/latest/download/ClaudeUsageWidget.zip'
# Plans the settings picker offers; an empty plan means Auto (whatever the API reports).
$PlanChoices = @('Pro', 'Max 5x', 'Max 20x')
$UserAgent  = "claude-usage-widget/$AppVersion (+https://github.com/mrcsXndr/claude-usage-widget)"

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

# A long-running widget keeps the PATH it started with, so a CLI installed later (npm -g xndr-claude)
# is invisible to it. Merge any Machine/User PATH entries the process lacks.
function Update-ProcessPath {
  $have = @($env:PATH -split ';' | Where-Object { $_ })
  foreach ($scope in 'Machine', 'User') {
    foreach ($p in ([Environment]::GetEnvironmentVariable('PATH', $scope) -split ';' | Where-Object { $_ })) {
      $e = [Environment]::ExpandEnvironmentVariables($p)
      if ($have -notcontains $e) { $have += $e }
    }
  }
  $env:PATH = $have -join ';'
}

function Test-Command([string]$name) {
  if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
  Update-ProcessPath
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# Runs a command line through cmd (so npm shims and PATH lookups work) and captures its output.
function Invoke-Captured([string]$commandLine, [int]$timeoutSec = 30, [string]$stdin) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  if ($stdin) { $psi.RedirectStandardInput = $true }
  $psi.FileName = $env:ComSpec
  $psi.Arguments = "/d /s /c `"$commandLine`""
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  try {
    if ($stdin) {
      # Raw UTF-8 bytes (no BOM) so a secret goes to the child without touching argv.
      $b = (New-Object Text.UTF8Encoding $false).GetBytes($stdin)
      $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
      $p.StandardInput.Close()
    }
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

# Shortcut that starts the widget with no console window (conhost --headless, no VBScript needed).
function New-LauncherShortcut([string]$path, [string]$appDir) {
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
  $sc.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
  $sc.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $appDir 'ClaudeUsageWidget.ps1')`""
  $sc.WorkingDirectory = $appDir
  $icon = Join-Path $appDir 'assets\icon.ico'
  if (Test-Path $icon) { $sc.IconLocation = "$icon,0" }
  $sc.Description = 'Claude usage on your taskbar'
  $sc.Save()
}

function Get-LastLine([string]$text) {
  ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
}

# ---------------------------------------------------------------- discovery & config

function Format-Plan($tier, $sub) {
  if ("$tier" -match 'max_(\d+x)') { return "Max $($Matches[1])" }
  if ($sub) { return (Get-Culture).TextInfo.ToTitleCase(("$sub" -replace '^claude_', '')) }
  return $null
}

# Claude Code's login in <dir>\.credentials.json (dir defaults to ~/.claude). Read-only: we never
# refresh it, because refreshing rotates the refresh token and would log Claude Code out.
function Get-ClaudeCodeLogin([string]$dir) {
  if (-not $dir) { $dir = Get-ClaudeConfigDir }
  $path = Join-Path $dir '.credentials.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { $o = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).claudeAiOauth } catch { return $null }
  if (-not $o -or -not $o.accessToken) { return $null }
  $expires = if ($o.expiresAt) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$o.expiresAt).UtcDateTime } else { $null }
  return [pscustomobject]@{ token = $o.accessToken; expires = $expires; plan = (Format-Plan $o.rateLimitTier $o.subscriptionType) }
}

# Who a config dir is logged in as: .claude.json sits beside ~/.claude, or inside a custom dir.
function Get-ClaudeCodeIdentity([string]$dir) {
  foreach ($p in @(($dir.TrimEnd('\', '/') + '.json'), (Join-Path $dir '.claude.json'))) {
    if (Test-Path -LiteralPath $p) {
      try { $o = (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).oauthAccount; if ($o) { return $o } } catch {}
    }
  }
  return $null
}

# Every Claude Code login on this PC: ~/.claude, other ~/.claude* dirs (a common way to keep
# one login per account via CLAUDE_CONFIG_DIR), and CLAUDE_CONFIG_DIR itself.
function Find-ClaudeCodeLogins {
  $default = [IO.Path]::GetFullPath((Join-Path $HOME '.claude')).TrimEnd('\')
  $dirs = @()
  if ($env:CLAUDE_CONFIG_DIR) { $dirs += $env:CLAUDE_CONFIG_DIR }
  $dirs += @(Get-ChildItem -LiteralPath $HOME -Directory -Force -Filter '.claude*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
  $seen = @{}
  foreach ($d in $dirs) {
    $full = [IO.Path]::GetFullPath($d).TrimEnd('\')
    if ($seen[$full.ToLower()]) { continue }
    $seen[$full.ToLower()] = $true
    $login = Get-ClaudeCodeLogin $full
    if (-not $login) { continue }
    $id = Get-ClaudeCodeIdentity $full
    if ($id.accountUuid) { if ($seen[$id.accountUuid]) { continue }; $seen[$id.accountUuid] = $true }
    $leaf = Split-Path $full -Leaf
    $acct = [ordered]@{
      name   = $(if ($full -eq $default) { 'claude-code' } else { 'claude-code-' + ($leaf -replace '^\.claude[-_.]?', '') })
      label  = $(if ($id.emailAddress) { $id.emailAddress } else { 'Claude Code' })
      plan   = $login.plan
      source = 'claude-code'
    }
    if ($full -ne $default) { $acct.dir = $full }
    $acct
  }
}

# xndr-claude's accounts, if it's installed. `usage --json` is its only machine-readable
# listing, so this costs one probe per account.
function Import-XndrClaudeAccounts {
  if (-not (Test-Command 'xndr-claude')) { return }
  try {
    $r = Invoke-Captured 'xndr-claude usage --json' 60
    # xndr-claude can exit non-zero while still listing every account (one limited or errored); the list is what counts.
    if ($r.exit -ne 0 -and "$($r.out)".TrimStart() -notmatch '^\[') { throw "exit $($r.exit): $(Get-LastLine $r.err)" }
    foreach ($a in (ConvertFrom-Json $r.out)) {
      [ordered]@{ name = $a.name; label = $a.label; plan = $a.plan; source = 'xndr-claude' }
    }
  } catch {
    Write-Log "xndr-claude import failed: $_"
  }
}

# Adds accounts found on this PC that the config doesn't have yet; returns how many were added.
function Add-DiscoveredAccounts($cfg) {
  $added = 0
  foreach ($a in @(@(Find-ClaudeCodeLogins) + @(Import-XndrClaudeAccounts))) {
    $known = @($cfg.accounts | Where-Object {
      $_.name -eq $a.name -or ($_.source -eq 'claude-code' -and $a.source -eq 'claude-code' -and "$($_.dir)" -eq "$($a.dir)")
    })
    if ($known.Count) { continue }
    $cfg.accounts = @($cfg.accounts) + @([pscustomobject]$a)
    $added++
  }
  return $added
}

function Save-Config($cfg) {
  New-Item -ItemType Directory -Force $AppDir | Out-Null
  $cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8
}

# Reads config.json. The first run creates it from whatever accounts are found on this PC.
function Read-Config {
  if (-not (Test-Path $ConfigPath)) {
    $cfg = [pscustomobject]@{ refreshMinutes = 30; captions = [pscustomobject]$DefaultCaptions; accounts = @() }
    [void](Add-DiscoveredAccounts $cfg)
    Save-Config $cfg
  }
  $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
  if (-not $cfg.refreshMinutes) { $cfg | Add-Member -Force refreshMinutes 30 }
  if (-not $cfg.captions) { $cfg | Add-Member -Force captions ([pscustomobject]$DefaultCaptions) }
  if (-not $cfg.accounts) { $cfg | Add-Member -Force accounts @() }
  return $cfg
}

# ---------------------------------------------------------------- tokens

function Get-AccountToken($acct) {
  switch ($acct.source) {
    'claude-code' {
      $login = Get-ClaudeCodeLogin $acct.dir
      if (-not $login) { throw 'Claude Code login not found' }
      if ($login.expires -and $login.expires -le [DateTime]::UtcNow) { throw 'login expired: open Claude Code to renew it' }
      return $login.token
    }
    'xndr-claude' {
      $name = if ($acct.account) { $acct.account } else { $acct.name }
      if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "bad xndr-claude account name '$name'" }
      return Get-CommandToken "xndr-claude token $name"
    }
    'command' { return Get-CommandToken $acct.command }
    'env' {
      $t = Get-UserEnvToken $acct.env
      if (-not $t) { throw "environment variable $($acct.env) is not set" }
      return $t.Trim()
    }
    default { throw "unknown source '$($acct.source)'" }
  }
}

# ---------------------------------------------------------------- tokens kept in the user environment
# The widget's own process never sees a user variable set after it started, so these read the
# registry (HKCU\Environment) directly; the process environment is the fallback for variables set elsewhere.

function Get-UserEnvToken([string]$name) {
  $v = $null
  try {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($k) { try { $v = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $k.Dispose() } }
  } catch {}
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name) }
  return $v
}

# CLAUDE_USAGE_TOKEN_<NAME>, or $null when the account name has nothing usable in it.
function Get-TokenVarName([string]$accountName) {
  $s = ("$accountName".ToUpper() -replace '[^A-Z0-9]+', '_').Trim('_')
  if (-not $s) { return $null }
  return "CLAUDE_USAGE_TOKEN_$s"
}

function Test-TokenFormat([string]$token) { "$token".Trim() -match '^sk-ant-oat\d*-' }

# Writes the user variable and reads it back from the registry; $true only when the value matches.
function Set-UserEnvToken([string]$name, [string]$value) {
  if ($name -notmatch '^CLAUDE_USAGE_TOKEN_[A-Z0-9_]+$') { throw 'bad variable name' }
  [Environment]::SetEnvironmentVariable($name, $value, 'User')
  return ((Get-UserEnvToken $name) -eq $value)
}

function Remove-UserEnvToken([string]$name) {
  if ($name -notmatch '^CLAUDE_USAGE_TOKEN_[A-Z0-9_]+$') { throw 'bad variable name' }
  [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'User')
}

# Stores a token with `xndr-claude add <name> --stdin`; the token goes over stdin only.
function Save-XndrClaudeToken([string]$name, [string]$token) {
  if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw 'bad xndr-claude account name' }
  $r = Invoke-Captured "xndr-claude add $name --stdin" 30 $token
  if ($r.exit -ne 0) { throw "xndr-claude add failed ($($r.exit))" }
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

# ---------------------------------------------------------------- update check

function ConvertTo-Version([string]$tag) {
  if ("$tag" -match '^v?(\d+)\.(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
  return $null
}

# The latest GitHub release as { tag, version, notes }, or $null when offline, rate-limited or
# malformed. Unauthenticated, 10 s timeout, never throws.
function Get-LatestRelease {
  $c = New-HttpClient
  try {
    $c.Timeout = [TimeSpan]::FromSeconds(10)
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $ReleaseApiUrl)
    [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/vnd.github+json')
    $res = $c.SendAsync($req).GetAwaiter().GetResult()
    try {
      if ([int]$res.StatusCode -ne 200) { return $null }
      $j = ConvertFrom-Json ($res.Content.ReadAsStringAsync().GetAwaiter().GetResult())
    } finally { $res.Dispose() }
    $v = ConvertTo-Version $j.tag_name
    if (-not $v) { return $null }
    return [pscustomobject]@{ tag = "$($j.tag_name)"; version = "$v"; notes = "$($j.body)" }
  } catch {
    return $null
  } finally {
    $c.Dispose()
  }
}

function Test-NewerVersion([string]$candidate, [string]$current) {
  $a = ConvertTo-Version $candidate; $b = ConvertTo-Version $current
  return [bool]($a -and $b -and $a -gt $b)
}

# Downloads the release zip to $out (only ever the fixed GitHub URL), publishing progress in the synchronized
# hashtable $sync (pct 0-100, bytes). Returns the version found inside the zip; throws on any problem.
function Save-UpdateZip([string]$url, [string]$out, $sync) {
  if ($url -ne $UpdateZipUrl -and -not $env:CUW_TEST_UPDATE_URL) { throw 'refusing to download from an unexpected URL' }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $c = New-HttpClient
  try {
    $c.Timeout = [TimeSpan]::FromMinutes(5)
    $res = $c.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
      if ([int]$res.StatusCode -ne 200) { throw "GitHub answered $([int]$res.StatusCode)" }
      $total = $res.Content.Headers.ContentLength
      $in = $res.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $fs = [IO.File]::Create($out)
      try {
        $buf = New-Object byte[] 65536; $done = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          $fs.Write($buf, 0, $n); $done += $n
          $sync.bytes = $done
          if ($total) { $sync.pct = [int][Math]::Min(100, 100 * $done / $total) }
        }
      } finally { $fs.Close(); $in.Dispose() }
    } finally { $res.Dispose() }
  } finally { $c.Dispose() }
  return (Get-ZipVersion $out)
}

# The widget version inside a release zip (lib/Usage.ps1's $AppVersion). Throws when the zip is not a release.
function Get-ZipVersion([string]$zip) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $names = @($z.Entries | ForEach-Object { $_.FullName })
    foreach ($need in 'ClaudeUsageWidget.ps1', 'lib/Usage.ps1') { if ($names -notcontains $need) { throw "the download is not a widget release (no $need)" } }
    $e = $z.GetEntry('lib/Usage.ps1')
    $r = New-Object IO.StreamReader($e.Open())
    try { $text = $r.ReadToEnd() } finally { $r.Dispose() }
    if ($text -notmatch "\`$AppVersion\s*=\s*'(\d+\.\d+\.\d+)'") { throw 'the download has no version' }
    return $Matches[1]
  } finally { $z.Dispose() }
}

# Hands the update to a separate process (a copy of lib\Updater.ps1 in TEMP, so replacing the install folder cannot
# disturb it). It waits for the widget (-WidgetPid) to exit, replaces the files in $dest from $zip, starts the new widget
# and checks that it is running; everything goes to update.log. Returns the helper's process.
function Start-UpdateHelper([int]$widgetPid, [string]$zip, [string]$dest) {
  $src = Join-Path $PSScriptRoot 'Updater.ps1'
  $tmp = Join-Path $env:TEMP ("cuw-updater-" + [guid]::NewGuid().ToString('N') + '.ps1')
  Copy-Item $src $tmp -Force
  $args2 = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tmp`" -WidgetPid $widgetPid -Zip `"$zip`" -Dest `"$dest`" -LogDir `"$AppDir`""
  Write-Log "update: starting helper (widget pid $widgetPid, zip $zip, dest $dest)"
  return (Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args2 -PassThru)
}

# First few lines of release notes, markdown marks stripped, for the update pill.
function Format-ReleaseNotes([string]$body, [int]$lines = 3) {
  $out = @($body -split "`r?`n" | ForEach-Object { ($_ -replace '^[\s#>*\-]+', '' -replace '[`*]', '').Trim() } | Where-Object { $_ } | Select-Object -First $lines)
  $t = $out -join "`n"
  if ($t.Length -gt 260) { $t = $t.Substring(0, 257) + '...' }
  return $t
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
      # Per-model weekly limits come as limits[] entries of kind weekly_scoped.
      $fable = if ($j.seven_day_fable) { & $win $j.seven_day_fable } else { New-Window $null $null }
      foreach ($l in @($j.limits)) {
        if ($l.kind -eq 'weekly_scoped' -and "$($l.scope.model.display_name)" -match 'fable') {
          $reset = if ($l.resets_at -is [DateTime]) { $l.resets_at.ToUniversalTime().ToString('o') } else { $l.resets_at }
          $fable = New-Window ([double]$l.percent) $reset
        }
      }
      return [pscustomobject]@{ http = 200; five_h = (& $win $j.five_hour); seven_d = (& $win $j.seven_day); fable = $fable }
    }
    if ($code -eq 403 -and $text -match 'oauth_scope_insufficient|scope requirement') { return [pscustomobject]@{ noScope = $true } }
    if ($code -eq 401) { return [pscustomobject]@{ http = 401; invalid = $true } }
    return [pscustomobject]@{ http = $code; retry = $true }  # 429s are common here; the probe still works
  } finally { $res.Dispose() }
}

# The plan as the profile endpoint reports it (organization.rate_limit_tier, e.g. default_claude_max_20x,
# and organization_type). Needs the same user:profile scope as the usage API, so setup-tokens get a 403
# and no header on the probe carries the plan either. Returns $null when the API can't tell.
function Read-ProfilePlan($client, [string]$token) {
  $res = Send-Request $client 'GET' $ProfileUrl $token $null
  try {
    if ([int]$res.StatusCode -ne 200) { return $null }
    $o = (ConvertFrom-Json $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()).organization
    return Format-Plan $o.rate_limit_tier $o.organization_type
  } finally { $res.Dispose() }
}

# 1-token request; the numbers ride on the response headers (also on a 429).
function Read-Probe($client, [string]$token, [string]$model = $ProbeModel) {
  $req = [ordered]@{ model = $model; max_tokens = 1; messages = @(@{ role = 'user'; content = '.' }) }
  if ($model -ne $ProbeModel) { $req.system = $ClaudeCodeSystem }
  $body = $req | ConvertTo-Json -Depth 4 -Compress
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
    $five = & $win '5h'; $seven = & $win '7d'; $fable = & $win '7d_oi'
    if ($null -eq $five.pct -and $null -eq $seven.pct) { return [pscustomobject]@{ http = $code; error = "http $code, no usage headers" } }
    return [pscustomobject]@{ http = $code; five_h = $five; seven_d = $seven; fable = $fable; limited = ((& $h 'status') -eq 'rejected') }
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
        name = $a.name; label = $(if ($a.label) { $a.label } else { $a.name }); plan = $a.plan; apiPlan = $null
        status = 'error'; error = $null; method = $null
        five_h = (New-Window $null $null); seven_d = (New-Window $null $null); fable = (New-Window $null $null)
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
        if (-not $r) {
          $row.method = 'probe'
          # Probe Fable (to get its weekly limit too) unless the account opts out or Fable didn't work for it.
          $fableKey = "$($a.name):fable"
          if ($a.fable -ne $false -and $MethodCache[$fableKey] -ne 'off') {
            $r = Read-Probe $client $token $FableModel
            if ($r.error) { $MethodCache[$fableKey] = 'off'; $r = $null }
            elseif (-not $r.invalid -and $null -eq $r.fable.pct) { $MethodCache[$fableKey] = 'off' }
          }
          if (-not $r) { $r = Read-Probe $client $token $ProbeModel }
        }
        # The plan comes from the API whenever the token may read it; the last good answer covers a failed call.
        if ($MethodCache[$a.name] -ne 'probe') {
          try { $p = Read-ProfilePlan $client $token; if ($p) { $MethodCache["$($a.name):plan"] = $p } } catch {}
        }
        $row.apiPlan = $MethodCache["$($a.name):plan"]
        if ($row.apiPlan) { $row.plan = $row.apiPlan }
        if ($r.invalid) { $row.status = 'invalid'; $row.error = "token invalid (http $($r.http))" }
        elseif ($r.error) { $row.error = $r.error }
        else {
          $row.five_h = $r.five_h; $row.seven_d = $r.seven_d
          if ($r.fable) { $row.fable = $r.fable }
          $row.status = if ($r.limited -or $r.five_h.pct -ge 100 -or $r.seven_d.pct -ge 100) { 'limited' } else { 'ok' }
        }
      } catch {
        $row.error = "$_"
        if ($row.error -like 'login expired*') { $row.status = 'expired' }
      } finally {
        $token = $null
      }
      [pscustomobject]$row
    }
  } finally {
    $client.Dispose()
  }
}
