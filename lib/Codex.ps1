function Get-CodexHome([string]$profileRoot = $HOME) {
  if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    return [IO.Path]::GetFullPath($env:CODEX_HOME)
  }
  return [IO.Path]::GetFullPath((Join-Path $profileRoot '.codex'))
}

function Test-CodexProfile([string]$dir) {
  if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
  try { return [IO.File]::Exists((Join-Path $dir 'auth.json')) } catch { return $false }
}

function Find-CodexAccounts([string]$profileRoot = $HOME) {
  $dirs = @()
  try { $dirs += Get-CodexHome $profileRoot } catch {}
  $dirs += @(Get-ChildItem -LiteralPath $profileRoot -Directory -Filter '.codex-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
  $seen = @{}
  foreach ($dir in $dirs) {
    if (-not (Test-CodexProfile $dir)) { continue }
    $full = [IO.Path]::GetFullPath($dir).TrimEnd([char[]]'\/')
    $normalized = $full.Replace('/', '\').ToLowerInvariant()
    if ($seen.ContainsKey($normalized)) { continue }
    $seen[$normalized] = $true
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [pscustomobject]@{ source = 'codex'; name = ('codex-' + $hash.Substring(0, 24)); label = 'Codex'; dir = $full }
  }
}

function Find-CodexExecutable {
  $command = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { return $command.Source }
  if ($env:LOCALAPPDATA) {
    $bundled = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'
    if ([IO.File]::Exists($bundled)) { return $bundled }
  }
  $command = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { return $command.Source }
  throw 'codex-cli-missing'
}

function Start-CodexProcess($startInfo) {
  return [Diagnostics.Process]::Start($startInfo)
}

function New-CodexProcessJob {
  if (-not ('UsageWidget.CodexProcessJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace UsageWidget {
  public sealed class CodexProcessJob : IDisposable {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public CodexProcessJob() {
      handle = CreateJobObject(IntPtr.Zero, null);
      if (handle == IntPtr.Zero) throw new Win32Exception();
    }
    public void Attach(Process process) {
      if (!AssignProcessToJobObject(handle, process.Handle)) throw new Win32Exception();
    }
    public void Dispose() {
      if (handle == IntPtr.Zero) return;
      TerminateJobObject(handle, 1);
      CloseHandle(handle);
      handle = IntPtr.Zero;
    }
  }
}
'@ -ErrorAction Stop
  }
  return New-Object UsageWidget.CodexProcessJob
}

function Wait-CodexTask($task, $clock, [int]$timeoutSeconds) {
  $remaining = [int][Math]::Floor($timeoutSeconds * 1000 - $clock.Elapsed.TotalMilliseconds)
  if ($remaining -le 0 -or -not $task.Wait($remaining)) { throw 'codex-timeout' }
}

function Send-CodexMessage($process, [string]$message, $clock, [int]$timeoutSeconds) {
  $pending = $process.StandardInput.WriteLineAsync($message)
  Wait-CodexTask $pending $clock $timeoutSeconds
}

function Stop-CodexProcess($process) {
  if ($null -eq $process) { return }
  try {
    if (-not $process.HasExited) {
      $info = New-Object Diagnostics.ProcessStartInfo
      $info.FileName = Join-Path $env:WINDIR 'System32\taskkill.exe'
      $info.Arguments = "/PID $($process.Id) /T /F"
      $info.UseShellExecute = $false
      $info.CreateNoWindow = $true
      $info.RedirectStandardOutput = $true
      $info.RedirectStandardError = $true
      $killer = $null
      try {
        $killer = [Diagnostics.Process]::Start($info)
        $outDrain = $killer.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        $errDrain = $killer.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        if (-not $killer.WaitForExit(1000)) { $killer.Kill() }
        if (-not $process.WaitForExit(500)) {
          $process.Kill()
          [void]$process.WaitForExit(500)
        }
      } finally { if ($killer) { $killer.Dispose() } }
    }
  } catch {
    try { if (-not $process.HasExited) { $process.Kill() } } catch {}
  } finally { $process.Dispose() }
}

function Invoke-CodexRead([string]$dir, [ValidateRange(1, 120)][int]$timeoutSeconds = 25) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $process = $null
  $job = $null
  try {
    $executable = Find-CodexExecutable
    $job = New-CodexProcessJob
    $info = New-Object Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($executable) -ieq '.cmd') {
      if ($executable -match '[\r\n"%!]') { throw 'codex-cli-missing' }
      $info.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
      $info.Arguments = "/d /s /v:off /c `"`"$executable`" app-server`""
    } else {
      $info.FileName = $executable
      $info.Arguments = 'app-server'
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.WorkingDirectory = [IO.Path]::GetFullPath($dir)
    $info.EnvironmentVariables['CODEX_HOME'] = [IO.Path]::GetFullPath($dir)
    $process = Start-CodexProcess $info
    $job.Attach($process)
    $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $version = '2.1.0'
    $appVersionVariable = Get-Variable -Name AppVersion -ErrorAction SilentlyContinue
    if ($appVersionVariable -and $appVersionVariable.Value) { $version = [string]$appVersionVariable.Value }
    $initialize = @{ id = 1; method = 'initialize'; params = @{ clientInfo = @{ name = 'usage_widget'; title = 'Usage Widget'; version = $version } } } | ConvertTo-Json -Depth 5 -Compress
    Send-CodexMessage $process $initialize $clock $timeoutSeconds
    $expected = 1
    $account = $null
    while ($true) {
      $pending = $process.StandardOutput.ReadLineAsync()
      Wait-CodexTask $pending $clock $timeoutSeconds
      $line = $pending.Result
      if ($null -eq $line) { throw 'codex-stopped' }
      try { $message = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { throw 'codex-protocol' }
      if ($null -eq $message.id) { continue }
      if ($message.method -or [string]$message.id -cne [string]$expected) { throw 'codex-protocol' }
      if ($null -ne $message.error) { throw 'codex-rpc' }
      if ($null -eq $message.result) { throw 'codex-protocol' }
      switch ($expected) {
        1 {
          Send-CodexMessage $process '{"method":"initialized"}' $clock $timeoutSeconds
          Send-CodexMessage $process '{"id":2,"method":"account/read","params":{"refreshToken":false}}' $clock $timeoutSeconds
          $expected = 2
        }
        2 {
          $account = $message.result.account
          if ($null -eq $account) { throw 'codex-auth-missing' }
          if ($account.type -eq 'apiKey') { throw 'codex-api-key' }
          if ($account.type -ne 'chatgpt') { throw 'codex-auth-type' }
          Send-CodexMessage $process '{"id":3,"method":"account/rateLimits/read"}' $clock $timeoutSeconds
          $expected = 3
        }
        3 { return [pscustomobject]@{ account = $account; usage = $message.result } }
      }
    }
  } finally {
    if ($job) { $job.Dispose() }
    Stop-CodexProcess $process
  }
}

function Convert-CodexWindow($window) {
  $pct = $null
  $reset = $null
  $minutes = $null
  if ($null -ne $window) {
    if ($null -ne $window.usedPercent) {
      $pct = [double]$window.usedPercent
      if ([double]::IsNaN($pct) -or [double]::IsInfinity($pct) -or $pct -lt 0) { throw 'codex-protocol' }
    }
    if ($null -ne $window.resetsAt) { $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$window.resetsAt).UtcDateTime.ToString('o') }
    if ($null -ne $window.windowDurationMins) { $minutes = [long]$window.windowDurationMins }
  }
  return [pscustomobject]@{ pct = $pct; reset = $reset; minutes = $minutes }
}

function Convert-CodexQuotaBucket([string]$id, $bucket) {
  $windows = @{}
  $invalid = $false
  foreach ($key in 'primary', 'secondary') {
    try {
      $window = $bucket.$key
      # JSON numbers only: PowerShell casts empty strings and booleans to zero.
      foreach ($field in 'usedPercent', 'resetsAt', 'windowDurationMins') {
        $value = $window.$field
        if ($null -ne $value -and $value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) { throw 'codex-protocol' }
      }
      $windows[$key] = Convert-CodexWindow $window
    } catch {
      $invalid = $true
      $windows[$key] = Convert-CodexWindow $null
    }
  }
  $five = $windows.primary
  $seven = $windows.secondary
  $reached = if ($bucket.rateLimitReachedType -is [string]) { $bucket.rateLimitReachedType } else { $null }
  $status = if ($invalid) { 'error' }
    elseif ($reached -or ($null -ne $five.pct -and $five.pct -ge 100) -or ($null -ne $seven.pct -and $seven.pct -ge 100)) { 'limited' }
    elseif ($null -eq $five.pct -and $null -eq $seven.pct) { 'error' }
    else { 'ok' }
  return [pscustomobject]@{
    id = $id
    name = $(if ($bucket.limitName -is [string] -and -not [string]::IsNullOrWhiteSpace($bucket.limitName)) { $bucket.limitName } elseif ($id -eq 'codex') { 'General Codex' } else { $id })
    normalModelSlug = $(if ($bucket.normalModelSlug -is [string]) { $bucket.normalModelSlug } else { $null })
    five_h = $five; seven_d = $seven; status = $status; rateLimitReachedType = $reached
  }
}

function Read-CodexAccount($acct, [ValidateRange(1, 120)][int]$timeoutSeconds = 25) {
  $row = [ordered]@{
    name = $acct.name; label = $(if ($acct.label) { $acct.label } else { 'Codex' })
    plan = $null; apiPlan = $null; status = 'error'; error = $null; method = 'codex-app-server'
    five_h = (Convert-CodexWindow $null); seven_d = (Convert-CodexWindow $null)
    fable = $null; provider = 'codex'; quotaBuckets = @()
  }
  try {
    $dir = if ($acct.dir) { $acct.dir } else { Get-CodexHome }
    if (-not (Test-CodexProfile $dir)) { throw 'codex-auth-missing' }
    $response = Invoke-CodexRead $dir $timeoutSeconds
    $row.plan = $response.account.planType
    $row.apiPlan = $row.plan
    $map = $response.usage.rateLimitsByLimitId
    $entries = @()
    if ($map -is [System.Collections.IDictionary]) {
      $entries = @($map.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } })
    } elseif ($map -is [pscustomobject]) {
      $entries = @($map.PSObject.Properties)
    }
    $row.quotaBuckets = @($entries | ForEach-Object { Convert-CodexQuotaBucket $_.Name $_.Value })
    $bucket = $map.codex
    if ($null -eq $bucket) {
      $legacy = $response.usage.rateLimits
      if ($null -ne $legacy -and (-not $legacy.limitId -or $legacy.limitId -eq 'codex')) {
        $bucket = $legacy
        $row.quotaBuckets = @($row.quotaBuckets | Where-Object { $_.id -ne 'codex' }) + @(Convert-CodexQuotaBucket 'codex' $legacy)
      } elseif ($entries.Count -eq 0 -and $null -ne $legacy) {
        $row.quotaBuckets = @(Convert-CodexQuotaBucket $legacy.limitId $legacy)
      }
    }
    if ($null -eq $bucket -or ($bucket.limitId -and $bucket.limitId -ne 'codex')) { throw 'codex-no-windows' }
    $five = Convert-CodexWindow $bucket.primary
    $seven = Convert-CodexWindow $bucket.secondary
    if ($null -eq $five.pct -and $null -eq $seven.pct) { throw 'codex-no-windows' }
    $row.five_h = $five
    $row.seven_d = $seven
    $row.status = if (($null -ne $five.pct -and $five.pct -ge 100) -or ($null -ne $seven.pct -and $seven.pct -ge 100)) { 'limited' } else { 'ok' }
  } catch {
    $row.error = switch ($_.Exception.Message) {
      'codex-cli-missing' { 'Codex CLI not found. Install Codex and sign in with ChatGPT.' }
      'codex-auth-missing' { 'Codex profile is not signed in. Run codex login for this profile.' }
      'codex-api-key' { 'API-key accounts do not expose ChatGPT plan limits. Sign in with ChatGPT.' }
      'codex-auth-type' { 'This account does not expose ChatGPT plan limits.' }
      'codex-timeout' { 'Codex usage request timed out.' }
      'codex-stopped' { 'Codex app-server stopped before returning usage.' }
      'codex-no-windows' { 'No Codex quota windows are available for this account.' }
      'codex-protocol' { 'Codex app-server returned an unexpected response.' }
      default { 'Unable to read Codex usage. Check Codex login and the network connection.' }
    }
  }
  return [pscustomobject]$row
}

