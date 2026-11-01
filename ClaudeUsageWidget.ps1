#Requires -Version 5.1
<#
.SYNOPSIS
  Claude 5h / 7d / Fable usage rings on the Windows taskbar, with a per-account list on click.

.DESCRIPTION
  Left click   open / close the account list; tick accounts to show them on the taskbar
  Gear         rename accounts, pick each account's rings, rename ring captions
  Ctrl + drag  move the rings along the taskbar
  Right click  refresh, settings, scan for accounts, start with Windows, uninstall, exit

  Settings live in %APPDATA%\claude-usage-widget\config.json (created on first run from the
  Claude Code logins and xndr-claude accounts found on this PC).

.PARAMETER Once
  Print every account's usage as JSON and exit, without the UI. Never prints a token.
.PARAMETER Demo
  Run with made-up accounts and no network; your config isn't touched.
.PARAMETER Snapshot
  Render the demo UI to PNGs in this folder (used for the README) and exit.
.PARAMETER RingCheck
  Render the rings at known percentages, measure each arc's sweep from the pixels, print a table and exit
  (exit code 1 when any arc is off by more than 1 degree).
#>
param([switch]$Once, [switch]$Demo, [string]$Snapshot, [switch]$RingCheck)

$ErrorActionPreference = 'Stop'
$LibPath = Join-Path $PSScriptRoot 'lib\Usage.ps1'
. $LibPath

if ($Once) {
  Get-AllUsage (Read-Config) | ConvertTo-Json -Depth 4
  exit
}
if ($Snapshot -or $RingCheck) { $Demo = $true }

# Source stays ASCII so Windows PowerShell 5.1 reads it correctly without a BOM.
$ELL = [string][char]0x2026; $DOT = [string][char]0x00B7; $DASH = [string][char]0x2013

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

if (-not $Snapshot -and -not $RingCheck) {
  $createdNew = $false
  $mutexName = if ($Demo) { 'Local\claude-usage-widget-demo' } else { 'Local\claude-usage-widget' }
  $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
  if (-not $createdNew) { exit }
}

Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class CuwNative {
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO i);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cb; public RECT rcMonitor, rcWork; public int flags; }

  // The taskbar is topmost too and rises above us whenever it's clicked, so this is re-applied on a timer.
  public static void KeepOnTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
  // WS_EX_TOOLWINDOW: no Alt+Tab entry.
  public static void MakeToolWindow(IntPtr h) { SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80); }
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
  // Dark title bar for a normal window (Windows 10 20H1 and later; ignored elsewhere).
  public static void DarkTitleBar(IntPtr h) { int v = 1; DwmSetWindowAttribute(h, 20, ref v, 4); }

  public static bool ForegroundIsFullscreen() {
    IntPtr h = GetForegroundWindow();
    if (h == IntPtr.Zero) return false;
    var sb = new StringBuilder(64); GetClassName(h, sb, 64);
    string c = sb.ToString();
    if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    var mi = new MONITORINFO(); mi.cb = Marshal.SizeOf(mi);
    if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
    return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
  }
}
'@

# Set CUW_DEBUG=1 to log popup show/hide decisions to widget.log.
function Write-Trace([string]$msg) { if ($env:CUW_DEBUG -eq '1') { Write-Log "trace: $msg" } }

$StartupLink   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$MinRefreshGap = 60  # seconds between refreshes, however they're triggered

# ---------------------------------------------------------------- UI state (position)

$script:state = @{ right = $null }
if (-not $Demo) {
  try {
    $saved = Get-Content $StatePath -Raw | ConvertFrom-Json
    if ($null -ne $saved.right) { $script:state.right = $saved.right }
    # Update check: when it last ran (unix seconds), the newer release found, which one was announced, which one is installing.
    foreach ($k in 'updateCheckedAt', 'updateVersion', 'updateNotes', 'notifiedVersion', 'pendingUpdate', 'ignoredAccounts') {
      if ($null -ne $saved.$k) { $script:state[$k] = $saved.$k }
    }
  } catch {}
}

function Save-State {
  if ($Demo) { return }
  try {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    $script:state | ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
  } catch { Write-Log "save state: $_" }
}

# ---------------------------------------------------------------- config

$script:config = $null
$script:configError = $null

# Until the first refresh has run (and, on a first run, discovered accounts), there may be no file yet.
function Import-UiConfig {
  if ($Demo) { return }
  try {
    $script:config = if (Test-Path $ConfigPath) { Read-Config } else { [pscustomobject]@{ refreshMinutes = 30; captions = [pscustomobject]$DefaultCaptions; accounts = @() } }
    $script:configError = $null
  } catch {
    $script:configError = "config.json: $($_.Exception.Message)"
    if (-not $script:config) { $script:config = [pscustomobject]@{ refreshMinutes = 30; captions = [pscustomobject]$DefaultCaptions; accounts = @() } }
  }
}

function Save-UiConfig {
  if ($script:editing) { Update-SettingsButtons }
  if ($Demo -or $script:editing) { return }
  try { Save-Config $script:config } catch { Write-Log "save config: $_" }
}

function Get-RefreshMinutes {
  $m = [int]$script:config.refreshMinutes
  if (-not $m) { return 30 }
  return [Math]::Max(5, $m)
}
# Taskbar options that default to on.
function Test-Option($key) { $script:config.$key -ne $false }
function Get-AcctCfgs { @($script:config.accounts | Where-Object { $_ }) }
function Get-AcctCfg($name) { Get-AcctCfgs | Where-Object name -eq $name | Select-Object -First 1 }
function Get-Visible { @(Get-AcctCfgs | Where-Object { $_.hidden -ne $true }) }
function Get-Result($name) { $script:accounts | Where-Object name -eq $name | Select-Object -First 1 }
function Get-Label($cfg) { if ("$($cfg.label)".Trim()) { "$($cfg.label)".Trim() } else { "$($cfg.name)" } }

# Name -> the 1-2 characters shown inside an account's ring when percentages are off: the initials set in
# Settings, else the first letter of its name; accounts whose first letters collide get two letters each.
function Get-Shorts {
  $out = @{}; $taken = @{}
  $all = @(Get-AcctCfgs)
  foreach ($c in $all) {
    $s = "$($c.short)".Trim()
    if ($s.Length -gt 2) { $s = $s.Substring(0, 2) }
    if ($s) { $out[$c.name] = $s; $taken[$s] = $true }
  }
  $auto = @($all | Where-Object { -not $out.ContainsKey($_.name) } | ForEach-Object {
    $t = (Get-Label $_) -replace '[^\p{L}\p{N}]', ''
    if (-not $t) { $t = "$($_.name)" -replace '[^\p{L}\p{N}]', '' }
    if (-not $t) { $t = '?' }
    [pscustomobject]@{ name = $_.name; text = $t; first = $t.Substring(0, 1).ToUpper() }
  })
  foreach ($a in $auto) {
    $s = $a.first
    if ($taken.ContainsKey($s) -or @($auto | Where-Object first -eq $a.first).Count -gt 1) {
      $s = $null
      foreach ($ch in $a.text.Substring(1).ToCharArray()) {
        $cand = $a.first + "$ch".ToLower()
        if (-not $taken.ContainsKey($cand)) { $s = $cand; break }
      }
      if (-not $s) { $n = 2; while ($taken.ContainsKey("$($a.first)$n")) { $n++ }; $s = "$($a.first)$n" }
    }
    $out[$a.name] = $s; $taken[$s] = $true
  }
  return $out
}
# The API's plan wins; the plan picked in settings (at first, the one found at discovery) covers tokens it can't read.
function Get-Plan($cfg, $res) { if ($res.apiPlan) { "$($res.apiPlan)" } elseif ("$($cfg.plan)".Trim()) { "$($cfg.plan)".Trim() } else { $null } }

function Get-Caption($key) {
  $c = "$($script:config.captions.$key)".Trim()
  if ($c) { return $c }
  return $DefaultCaptions[$key]
}

function Get-TaskbarLimits($cfg) {
  $l = @($LimitKeys | Where-Object { @($cfg.limits) -contains $_ })
  if ($l.Count) { return $l }
  return @('5h', '7d')
}

# Plans without a 5-hour window (Ultra) report none: the usage API's five_hour is null, or the probe has no
# anthropic-ratelimit-unified-5h-* headers. Only a read that worked counts, so an error or "loading" is not "no 5h".
function Test-NoFiveH($res) {
  if (-not $res -or $res.status -notin 'ok', 'limited') { return $false }
  $w = $res.five_h
  return (-not $w -or $null -eq $w.pct)
}

# The limits an account really shows: its taskbar choice minus 5h when it has none (never empty: 7d then).
function Get-ShownLimits($cfg, $res) {
  $l = @(Get-TaskbarLimits $cfg)
  if (Test-NoFiveH $res) { $l = @($l | Where-Object { $_ -ne '5h' }); if (-not $l.Count) { $l = @('7d') } }
  return $l
}

function Get-LastUsed {
  try { return (Get-Content (Join-Path (Get-XndrClaudeHome) 'state.json') -Raw | ConvertFrom-Json).last } catch { return $null }
}

# Accounts on the taskbar: the ticked ones; with none ticked, xndr-claude's last-used one, else the first.
function Get-TaskbarCfgs {
  $vis = Get-Visible
  $on = @($vis | Where-Object { $_.taskbar -eq $true })
  if ($on.Count) { return $on }
  $last = Get-LastUsed
  $hit = @($vis | Where-Object { $last -and $_.name -eq $last })
  if ($hit.Count) { return $hit }
  if ($vis.Count) { return @($vis[0]) }
  return @()
}

# Accounts drawn on the taskbar: the ticked ones, minus (when "Hide an account while it's at its limit" is on) those
# whose 5h or 7d window is full right now; they come back after the reset. If that would hide every account they all
# stay, so the widget never vanishes. The list and Settings always use Get-TaskbarCfgs (what is ticked).
function Get-ShownCfgs {
  $all = @(Get-TaskbarCfgs)
  if ($script:config.hideAtLimit -ne $true) { return $all }
  $ok = @($all | Where-Object { $r = Get-Result $_.name; -not ($r -and ((Get-Win $r '5h').pct -ge 100 -or (Get-Win $r '7d').pct -ge 100)) })
  if ($ok.Count) { return $ok }
  return $all
}

function Set-AcctProp($name, $key, $value) {
  $c = Get-AcctCfg $name
  if ($c) { $c | Add-Member -Force -NotePropertyName $key -NotePropertyValue $value }
}

function Set-Taskbar($name, [bool]$on, $checkbox) {
  $explicit = @(Get-Visible | Where-Object { $_.taskbar -eq $true })
  if (-not $on -and ($explicit.Count -le 1) -and (@(Get-TaskbarCfgs)[0].name -eq $name)) {
    $checkbox.IsChecked = $true  # keep at least one account on the taskbar
    return
  }
  # First tick: pin down whatever the fallback was showing, so it doesn't silently vanish.
  if (-not $explicit.Count) { foreach ($c in @(Get-TaskbarCfgs)) { Set-AcctProp $c.name 'taskbar' $true } }
  Set-AcctProp $name 'taskbar' $on
  Save-UiConfig
  Update-Widget
}

function Set-Limit($name, $key, [bool]$on, $checkbox) {
  $cur = @(Get-TaskbarLimits (Get-AcctCfg $name))
  $new = @($LimitKeys | Where-Object { ($_ -eq $key -and $on) -or ($_ -ne $key -and $cur -contains $_) })
  if (-not $new.Count) { $checkbox.IsChecked = $true; return }  # at least one ring
  Set-AcctProp $name 'limits' $new
  Save-UiConfig
  Update-Widget
}

# ---------------------------------------------------------------- theme

$isLight = $false
if (-not $Snapshot -and -not $RingCheck) {
  try { $isLight = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' SystemUsesLightTheme) -eq 1 } catch {}
}
$Theme = if ($isLight) {
  @{ fg = '#1A1A1A'; sub = '#5F5F5F'; ring = '#26000000'; card = '#F9F9F9'; border = '#D0D0D0'; hover = '#EAEAEA'; bar = '#E3E3E3'; field = '#FFFFFF'; widgetHover = '#1A000000' }
} else {
  @{ fg = '#FFFFFF'; sub = '#A3A3A3'; ring = '#3DFFFFFF'; card = '#202020'; border = '#3A3A3A'; hover = '#2B2B2B'; bar = '#3A3A3A'; field = '#2B2B2B'; widgetHover = '#1FFFFFFF' }
}
$Colors = @{ ok = '#4CC38A'; warn = '#F2B84B'; bad = '#F0625D'; none = '#8A8A8A'; accent = '#D97757' }

function Get-UsageColor($pct) {
  if ($null -eq $pct) { return $Colors.none }
  if ($pct -ge 90) { return $Colors.bad }
  if ($pct -ge 70) { return $Colors.warn }
  return $Colors.ok
}

function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }
$ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'

# ---------------------------------------------------------------- data

$script:accounts    = @()
$script:updated     = $null
$script:lastTry     = [DateTime]::MinValue
$script:lastError   = $null
$script:notice      = $null
$script:job         = $null
$script:methodCache = [hashtable]::Synchronized(@{})

function ConvertTo-LocalTime($v) {
  if ($null -eq $v -or $v -eq '') { return $null }
  if ($v -is [DateTime]) { return $v.ToLocalTime() }
  return [DateTime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
}

function Format-Pct($pct) { if ($null -eq $pct) { return $null } [string][Math]::Round([double]$pct) }

function Format-Reset($iso) {
  $dt = ConvertTo-LocalTime $iso
  if ($null -eq $dt) { return '' }
  $span = $dt - (Get-Date)
  if ($span.TotalMinutes -le 0) { return '' }
  if ($span.TotalHours -lt 1) { return 'in {0}m' -f [int][Math]::Ceiling($span.TotalMinutes) }
  if ($span.TotalHours -lt 24) { return 'in {0}h {1:00}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
  return $dt.ToString('ddd HH:mm')
}

function Get-RawWin($res, $key) {
  if (-not $res) { return $null }
  switch ($key) { '5h' { $res.five_h } '7d' { $res.seven_d } 'fable' { $res.fable } }
}

# A window whose reset time has passed since the last read has started over: show it as 0%
# until the next refresh (which the minute timer then triggers) brings the real number.
function Get-Win($res, $key) {
  $w = Get-RawWin $res $key
  if ($w -and $null -ne $w.pct -and $w.reset -and (ConvertTo-LocalTime $w.reset) -le (Get-Date)) {
    return [pscustomobject]@{ pct = 0; reset = $null }
  }
  return $w
}

function Test-ResetPassed {
  if (-not $script:updated) { return $false }
  foreach ($res in $script:accounts) {
    foreach ($k in $LimitKeys) {
      $w = Get-RawWin $res $k
      if ($w -and $w.reset) {
        $t = ConvertTo-LocalTime $w.reset
        if ($t -le (Get-Date) -and $t -gt $script:updated) { return $true }
      }
    }
  }
  return $false
}

function Get-Cooldown {
  $left = $MinRefreshGap - ((Get-Date) - $script:lastTry).TotalSeconds
  if ($left -le 0) { return 0 }
  return [int][Math]::Ceiling($left)
}

function Set-DemoData {
  $now = [DateTime]::UtcNow
  $w = { param($p, $mins) [pscustomobject]@{ pct = $p; reset = $(if ($null -ne $mins) { $now.AddMinutes($mins).ToString('o') }) } }
  $script:config = [pscustomobject]@{
    refreshMinutes = 30
    captions = [pscustomobject]$DefaultCaptions
    accounts = @(
      [pscustomobject]@{ name = 'personal'; label = 'Personal'; plan = 'Max 20x'; source = 'claude-code'; taskbar = $true; limits = @('5h', '7d', 'fable') }
      [pscustomobject]@{ name = 'work'; label = 'Work'; plan = 'Max 5x'; source = 'xndr-claude'; taskbar = $true; style = 'combined'; pie = '5h' }
      [pscustomobject]@{ name = 'side'; label = 'Side project'; plan = 'Pro'; source = 'env' }
      [pscustomobject]@{ name = 'ultra'; label = 'Ultra'; plan = 'Ultra'; source = 'env' }
    )
  }
  $script:accounts = @(
    [pscustomobject]@{ name = 'personal'; status = 'ok'; error = $null; method = 'usage-api'; apiPlan = 'Max 20x'; five_h = (& $w 64 72); seven_d = (& $w 43 1574); fable = (& $w 38 1574) }
    [pscustomobject]@{ name = 'work'; status = 'ok'; error = $null; method = 'probe'; five_h = (& $w 12 282); seven_d = (& $w 30 6060); fable = (& $w 56 6060) }
    [pscustomobject]@{ name = 'side'; status = 'limited'; error = $null; method = 'probe'; five_h = (& $w 100 38); seven_d = (& $w 71 2900); fable = (& $w $null $null) }
    [pscustomobject]@{ name = 'ultra'; status = 'ok'; error = $null; method = 'probe'; five_h = (& $w $null $null); seven_d = (& $w 58 3000); fable = (& $w 12 3000) }
  )
  $script:updated = (Get-Date).Date.AddHours(11).AddMinutes(46)
}

# Reads run in a background runspace so token commands and HTTP never block the UI.
function Start-Refresh([switch]$Discover) {
  if ($script:job -or (Get-Cooldown) -gt 0) { return }
  $script:lastTry = Get-Date
  $script:notice = $null
  if ($Demo) { Set-DemoData; Update-All; return }
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({
    param($lib, $cache, $discover)
    $ErrorActionPreference = 'Stop'
    . $lib
    $cfg = Read-Config
    $added = 0
    if ($discover) { $added = Add-DiscoveredAccounts $cfg; if ($added) { Save-Config $cfg } }
    [pscustomobject]@{ added = $added; rows = @(Get-AllUsage $cfg $cache) }
  }).AddArgument($LibPath).AddArgument($script:methodCache).AddArgument([bool]$Discover)
  $script:job = @{ ps = $ps; handle = $ps.BeginInvoke(); started = Get-Date; discover = [bool]$Discover }
  $pollTimer.Start()
  Update-All
}

function Complete-Refresh {
  $j = $script:job
  $timedOut = ((Get-Date) - $j.started).TotalSeconds -gt 180
  if (-not $timedOut -and -not $j.handle.IsCompleted) { return }
  $pollTimer.Stop()
  $script:job = $null
  try {
    if ($timedOut) { $j.ps.Stop(); throw 'refresh timed out after 180s' }
    $out = @($j.ps.EndInvoke($j.handle))[0]
    $script:accounts = @($out.rows)
    $script:updated = Get-Date
    $script:lastError = $null
    if ($j.discover) {
      $script:notice = if ($out.added -eq 1) { 'Found 1 new account' } elseif ($out.added) { "Found $($out.added) new accounts" } else { 'No new accounts found' }
    }
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $script:lastError = $e.Message
    Write-Log "refresh: $($script:lastError)"
  } finally {
    $j.ps.Dispose()
  }
  if (-not $script:editing) { Import-UiConfig }
  $script:forcePopup = $true
  Update-All
}

# ---------------------------------------------------------------- updates
# Once a day (and on "Check now" in Settings) the latest GitHub release is compared with $AppVersion.
# A newer one gets a tray notification once and an "Update available" box in the popup; "Update now"
# runs the official installer URL (and nothing else) in a separate process, which restarts the widget.

$script:update = $null        # newer release: { version, notes }
$script:updJob = $null
$script:updManual = $false
$script:updMsg = $null
$script:updatingSince = $null
$script:tray = $null
if ($script:state.updateVersion -and (Test-NewerVersion "$($script:state.updateVersion)" $AppVersion)) {
  $script:update = [pscustomobject]@{ version = "$($script:state.updateVersion)"; notes = "$($script:state.updateNotes)" }
}

function Test-UpdateDue {
  if ($Demo -or $script:updJob -or -not (Test-Option 'updateCheck')) { return $false }
  $last = if ($null -ne $script:state.updateCheckedAt) { [int64]$script:state.updateCheckedAt } else { 0 }
  return ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $last) -ge 86400
}

# A tray balloon (a toast on Windows 10/11); clicking it opens the popup.
function Show-Toast([string]$title, [string]$text) {
  if ($Demo) { return }
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not $script:tray) {
      $t = New-Object System.Windows.Forms.NotifyIcon
      $ico = Join-Path $PSScriptRoot 'assets\icon.ico'
      $t.Icon = if (Test-Path $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Information }
      $t.Text = 'Claude usage'
      $t.Add_BalloonTipClicked({ Show-Popup })
      $t.Add_BalloonTipClosed({ $script:tray.Visible = $false })
      $script:tray = $t
    }
    $script:tray.Visible = $true
    $script:tray.ShowBalloonTip(10000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info)
  } catch { Write-Log "toast: $_" }
}

function Set-DemoUpdate {
  $script:update = [pscustomobject]@{ version = '1.9.3'; notes = "Self-update check with a tray notification`nFaster refresh on wake" }
  $script:updMsg = if ($script:updManual) { 'v1.9.3 is available' }
}

function Start-UpdateCheck([switch]$Manual) {
  if ($script:updJob) { return }
  $script:updManual = [bool]$Manual
  if ($Demo) { Set-DemoUpdate; return }
  $script:updMsg = if ($Manual) { "Checking$ELL" }
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({ param($lib) $ErrorActionPreference = 'Stop'; . $lib; Get-LatestRelease }).AddArgument($LibPath)
  $script:updJob = @{ ps = $ps; handle = $ps.BeginInvoke(); started = Get-Date }
  $updTimer.Start()
  if ($Manual) { $script:forcePopup = $true; Update-All }
}

function Complete-UpdateCheck {
  $j = $script:updJob
  $timedOut = ((Get-Date) - $j.started).TotalSeconds -gt 30
  if (-not $timedOut -and -not $j.handle.IsCompleted) { return }
  $updTimer.Stop()
  $script:updJob = $null
  $rel = $null
  try {
    if ($timedOut) { $j.ps.Stop() } else { $rel = @($j.ps.EndInvoke($j.handle))[0] }
  } catch { Write-Log "update check: $($_.Exception.Message)" }
  finally { $j.ps.Dispose() }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($rel) {
    $script:state.updateCheckedAt = $now
    if (Test-NewerVersion $rel.version $AppVersion) {
      $script:update = [pscustomobject]@{ version = $rel.version; notes = (Format-ReleaseNotes $rel.notes) }
      $script:state.updateVersion = $rel.version; $script:state.updateNotes = $script:update.notes
      $script:updMsg = "v$($rel.version) is available"
      if ("$($script:state.notifiedVersion)" -ne $rel.version) {
        $script:state.notifiedVersion = $rel.version
        Show-Toast 'Update available' "Claude usage widget v$($rel.version) is available"
      }
    } else {
      $script:update = $null; $script:state.updateVersion = $null; $script:state.updateNotes = $null
      $script:updMsg = "Up to date (v$AppVersion)"
    }
  } else {
    $script:state.updateCheckedAt = $now - 82800  # offline or rate-limited: try again in an hour
    $script:updMsg = 'Could not reach GitHub'
  }
  Save-State
  if (-not $script:updManual) { $script:updMsg = $null }
  $script:forcePopup = $true
  Update-All
}

# "Install update": download the release zip here (progress shows in the Updates tab and the list), check that it
# really is a newer widget, then hand over to lib\Updater.ps1, a separate process that waits for this one to exit,
# replaces the files, starts the new widget and verifies it is running (update.log has every step). This process
# never kills itself and never depends on the shell opening a shortcut.
$script:dlJob = $null
$script:updPct = $null        # download progress 0-100 while one runs, else $null

# One place that sets the status text and keeps every control that shows it in step.
function Set-UpdStatus([string]$text, $pct) {
  $script:updMsg = $text
  $script:updPct = $pct
  Update-UpdateControls
}

function Update-UpdateControls {
  $busy = [bool]$script:updatingSince
  $PopupEls.UpdMsg.Text = if ($script:updMsg) { $script:updMsg } else { "Version $AppVersion" }
  $PopupEls.UpdBar.Visibility = if ($null -ne $script:updPct) { 'Visible' } else { 'Collapsed' }
  if ($null -ne $script:updPct) {
    $p = [Math]::Max(0, [Math]::Min(100, [double]$script:updPct))
    $PopupEls.UpdC1.Width = New-Object Windows.GridLength($p, [Windows.GridUnitType]::Star)
    $PopupEls.UpdC2.Width = New-Object Windows.GridLength((100 - $p), [Windows.GridUnitType]::Star)
  }
  $PopupEls.UpdNotesS.Text = if ($script:update) { "$($script:update.notes)" } else { '' }
  $PopupEls.UpdNotesS.Visibility = if ($script:update -and $script:update.notes) { 'Visible' } else { 'Collapsed' }
  $PopupEls.UpdInstallBtn.Visibility = if ($script:update) { 'Visible' } else { 'Collapsed' }
  $PopupEls.UpdInstallBtn.IsEnabled = -not $busy
  $PopupEls.UpdInstallBtn.Content = if ($busy) { "Updating$ELL" } elseif ($script:update) { "Install v$($script:update.version)" } else { 'Install update' }
  $PopupEls.UpdBtn.Content = if ($busy) { "Updating$ELL" } else { 'Update now' }
  $PopupEls.UpdBtn.IsEnabled = -not $busy
  if ($script:update -and $busy) { $PopupEls.UpdNotes.Text = "$($script:updMsg)"; $PopupEls.UpdNotes.Visibility = 'Visible' }
}

function Invoke-UpdateNow {
  if (-not $script:update -or $script:updatingSince) { return }
  $ver = $script:update.version
  $script:updatingSince = Get-Date
  $zip = Join-Path $env:TEMP "cuw-update-$ver.zip"
  Write-Log "update: downloading v$ver"
  $sync = [hashtable]::Synchronized(@{ pct = 0; bytes = 0 })
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({ param($lib, $url, $out, $sync) $ErrorActionPreference = 'Stop'; . $lib; Save-UpdateZip $url $out $sync }).AddArgument($LibPath).AddArgument($UpdateZipUrl).AddArgument($zip).AddArgument($sync)
  $script:dlJob = @{ ps = $ps; handle = $ps.BeginInvoke(); sync = $sync; zip = $zip; ver = $ver; started = Get-Date }
  Set-UpdStatus "Downloading v$ver$ELL 0%" 0
  $dlTimer.Start()
}

function Stop-UpdateAttempt([string]$why) {
  Write-Log "update: $why"
  $script:updatingSince = $null
  Set-UpdStatus $why $null
}

function Step-Download {
  $j = $script:dlJob
  $timedOut = ((Get-Date) - $j.started).TotalSeconds -gt 420
  if (-not $timedOut -and -not $j.handle.IsCompleted) {
    Set-UpdStatus "Downloading v$($j.ver)$ELL $($j.sync.pct)%" $j.sync.pct
    return
  }
  $dlTimer.Stop()
  $script:dlJob = $null
  $got = $null; $err = $null
  try {
    if ($timedOut) { $j.ps.Stop(); throw 'the download timed out' }
    $got = @($j.ps.EndInvoke($j.handle))[0]
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $err = $e.Message
  } finally { $j.ps.Dispose() }
  if ($err) { Stop-UpdateAttempt "Download failed: $err"; Remove-Item $j.zip -Force -ErrorAction SilentlyContinue; return }
  if (-not (Test-NewerVersion "$got" $AppVersion)) { Stop-UpdateAttempt "The download is v$got, which is not newer than v$AppVersion."; Remove-Item $j.zip -Force -ErrorAction SilentlyContinue; return }
  Set-UpdStatus "Installing v$got. The widget closes and restarts in a few seconds$ELL" 100
  $script:state.pendingUpdate = "$got"
  Save-State
  try { $helper = Start-UpdateHelper $PID $j.zip $PSScriptRoot }
  catch { Stop-UpdateAttempt "Could not start the installer: $($_.Exception.Message)"; return }
  Write-Log "update: helper pid $($helper.Id) started for v$got, exiting"
  # Let the status be seen for a moment, then leave; the helper waits for this process to end.
  $exitTimer = New-Object Windows.Threading.DispatcherTimer
  $exitTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
  $script:exitTimerRef = $exitTimer
  $exitTimer.Add_Tick({ $script:exitTimerRef.Stop(); Exit-Widget })
  $exitTimer.Start()
}

function Exit-Widget {
  $script:exiting = $true
  try { $settings.Close() } catch {}
  try { $popup.Close() } catch {}
  $widget.Close()
}

# After the restart: confirm the version that is now running (the Updates tab and a notification say so).
function Complete-PendingUpdate {
  $p = "$($script:state.pendingUpdate)"
  if (-not $p) { return }
  $script:state.pendingUpdate = $null
  Save-State
  if (Test-NewerVersion $p $AppVersion) {
    Write-Log "update to v$p did not apply (running v$AppVersion)"
    $script:updMsg = "The update to v$p did not apply (still v$AppVersion). Details: update.log in %APPDATA%\claude-usage-widget"
    return
  }
  $script:updMsg = "Updated to v$AppVersion"
  Show-Toast 'Updated' "Claude usage widget is now v$AppVersion"
}

# ---------------------------------------------------------------- widget

[xml]$widgetXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        UseLayoutRounding="True" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Root" Background="#01000000" CornerRadius="6" Padding="8,4" Cursor="Hand" TextOptions.TextFormattingMode="Display">
    <Border.LayoutTransform><ScaleTransform x:Name="Scale" ScaleX="1" ScaleY="1"/></Border.LayoutTransform>
    <StackPanel x:Name="Groups" Orientation="Horizontal"/>
  </Border>
</Window>
"@
$widget = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $widgetXaml))
$WidgetEls = @{}
foreach ($n in 'Root', 'Scale', 'Groups') { $WidgetEls[$n] = $widget.FindName($n) }

# Size presets. Everything the taskbar draws derives from the active one (Set-SizePreset), so a ring, its text
# and the widget's height stay in proportion; the widget's height is ring + 2 x pad and is scaled down to fit a short taskbar.
$SizePresets = @{
  compact = @{ dip = 32; thick = 4;   inner = 19; innerThick = 2.5; inFont = 11.5; nextFont = 11; pad = 4; rows = 1 }
  normal  = @{ dip = 36; thick = 4.5; inner = 21; innerThick = 3;   inFont = 13;   nextFont = 12; pad = 3; rows = 1 }
  large   = @{ dip = 40; thick = 5;   inner = 24; innerThick = 3;   inFont = 14;   nextFont = 13; pad = 2; rows = 2 }
}
function Get-SizeKey { $k = "$($script:config.size)"; if ($SizePresets.ContainsKey($k)) { $k } else { 'compact' } }
function Set-SizePreset {
  $p = $SizePresets[(Get-SizeKey)]
  $script:RingDip = $p.dip; $script:RingThick = $p.thick; $script:RingInnerDip = $p.inner; $script:RingInnerThick = $p.innerThick
  $script:InFont = $p.inFont; $script:NextFont = $p.nextFont; $script:PadV = $p.pad; $script:TwoRows = $p.rows -eq 2
  # Combined dials have no room for a second text row, so Normal and Large put the reset time on each limit's line.
  $script:ShowReset = (Get-SizeKey) -ne 'compact'
  $sp = $SpacingPresets[(Get-SpacingKey)]
  $script:GapSide = $sp.side; $script:GapRing = $sp.ring
}
# Space between account groups (each side of the divider) and between the rings of one account.
$SpacingPresets = @{ tight = @{ side = 5; ring = 6 }; normal = @{ side = 14; ring = 14 }; wide = @{ side = 26; ring = 22 } }
function Get-SpacingKey { $k = "$($script:config.spacing)"; if ($SpacingPresets.ContainsKey($k)) { $k } else { 'normal' } }
Set-SizePreset

# Where the account name goes: left of its rings, right of them, or nowhere (older configs: showNames).
function Get-NamesMode {
  $v = "$($script:config.names)"
  if ($v -in 'left', 'right', 'hidden') { return $v }
  if ($script:config.showNames -eq $false) { return 'hidden' }
  return 'left'
}
# Which limit is the inner ring of a combined dial: the account's own choice, else the global one, else 5h.
function Get-PieKey($cfg) {
  foreach ($v in "$($cfg.pie)", "$($script:config.innerWindow)") { if ($v -in '5h', '7d') { return $v } }
  return '5h'
}

# What goes inside a ring (none | initials | percent) and next to it (none | caption | percent). Configs from before
# these choices existed map from the old switches: percentages on = number inside + caption beside, off = initials only.
function Get-InsideMode {
  $v = "$($script:config.inside)"
  if ($v -in 'none', 'initials', 'percent') { return $v }
  if ($script:config.showPercents -eq $false) { return 'initials' }
  return 'percent'
}
function Get-NextMode {
  $v = "$($script:config.next)"
  if ($v -in 'none', 'caption', 'percent', 'resetin', 'resetat') { return $v }
  if ($script:config.showPercents -eq $false -or $script:config.showCaptions -eq $false) { return 'none' }
  return 'caption'
}

# The arc is drawn with flat caps and ends exactly at pct x 360 degrees. (Round caps stick out half a stroke
# width past both ends, which closed the gap: 91% looked like 95%. Measured with -RingCheck.)
function Set-Ring($path, $pct, [double]$size = $RingDip, [double]$thick = $RingThick) {
  $path.Stroke = Get-UsageColor $pct
  if ($null -eq $pct -or $pct -le 0) { $path.Data = $null; return }
  $r = ($size - $thick) / 2; $c = $size / 2
  if ($pct -ge 100) { $path.Data = New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point($c, $c)), $r, $r); return }
  $f = [double]$pct / 100; $a = 2 * [Math]::PI * $f
  $end = New-Object Windows.Point(($c + $r * [Math]::Sin($a)), ($c - $r * [Math]::Cos($a)))
  $seg = New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0, ($f -gt 0.5), ([Windows.Media.SweepDirection]::Clockwise), $true)
  $fig = New-Object Windows.Media.PathFigure
  $fig.StartPoint = New-Object Windows.Point($c, ($c - $r))
  $fig.Segments.Add($seg)
  $geo = New-Object Windows.Media.PathGeometry
  $geo.Figures.Add($fig)
  $path.Data = $geo
}

# The ring is an even number of device pixels across, so its centre sits on a pixel boundary at any
# display scale (30 DIP is 37.5 px at 125%, which put the centre half a pixel off and blurred one side).
function Get-RingSize([double]$dip = $RingDip) {
  $dpi = 1.0
  try { $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($widget).DpiScaleX } catch {}
  return 2 * [Math]::Round($dip * $dpi / 2, [MidpointRounding]::AwayFromZero) / $dpi
}

# Segoe UI puts its baseline at ~81% of the line box, so digits sit ~0.06 em below the box centre;
# the 1.3 / 1.2 bottom margins lift the text that much (about 0.6 px) so it is optically centred on the ring.
# Inside the ring: nothing, the account's initials or the percentage (Get-InsideMode).
function Get-InsideText($pct, [string]$short) {
  switch (Get-InsideMode) {
    'initials' { return (Esc $short) }
    'percent' { return $(if ($null -ne $pct) { Format-Pct $pct } elseif ($script:job) { $ELL } else { $DASH }) }
    default { return '' }
  }
}
function Get-InsideSize([string]$short) {
  if ((Get-InsideMode) -eq 'initials' -and $short.Length -eq 1) { return $InFont + 1.5 }
  return $InFont
}

# Reset time as "in 1h 34m" (relative) or as "Sat 03:02" (day and time; just the time when it is today).
function Format-ResetIn($iso) {
  $dt = ConvertTo-LocalTime $iso
  if ($null -eq $dt) { return '' }
  $span = $dt - (Get-Date)
  if ($span.TotalMinutes -le 0) { return '' }
  if ($span.TotalHours -lt 1) { return 'in {0}m' -f [int][Math]::Ceiling($span.TotalMinutes) }
  if ($span.TotalHours -lt 24) { return 'in {0}h {1:00}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
  return 'in {0}d {1}h' -f [int][Math]::Floor($span.TotalDays), $span.Hours
}
function Format-ResetAt($iso) {
  $dt = ConvertTo-LocalTime $iso
  if ($null -eq $dt -or $dt -le (Get-Date)) { return '' }
  if ($dt.Date -eq (Get-Date).Date) { return $dt.ToString('HH:mm') }
  return $dt.ToString('ddd HH:mm')
}

# The text for "next to the ring" in the given mode.
function Get-NextText([string]$mode, $pct, [string]$caption, $reset) {
  switch ($mode) {
    'caption' { return $caption }
    'resetin' { $t = Format-ResetIn $reset; return $(if ($t) { $t } else { $DASH }) }
    'resetat' { $t = Format-ResetAt $reset; return $(if ($t) { $t } else { $DASH }) }
    default { return $(if ($null -ne $pct) { "$(Format-Pct $pct)%" } elseif ($script:job) { $ELL } else { $DASH }) }
  }
}

# Next to the ring: nothing, the caption, the percentage, or when it resets (Get-NextMode). The large preset adds the
# reset time on a second row under a caption or percentage.
function Get-NextXaml($pct, [string]$caption, $reset) {
  $nx = Get-NextMode
  if ($nx -eq 'none') { return '' }
  $main = Get-NextText $nx $pct $caption $reset
  $weight = if ($nx -eq 'percent') { 'Bold' } else { 'SemiBold' }
  $opacity = if ($nx -in 'percent', 'resetin', 'resetat') { 1 } else { 0.8 }
  $r = if ($script:TwoRows -and $nx -in 'caption', 'percent') { Format-Reset $reset } else { '' }
  $second = if ($r) { "<TextBlock Text=`"$(Esc $r)`" FontSize=`"$($NextFont - 2)`" Foreground=`"$($Theme.sub)`"/>" } else { '' }
  return "<StackPanel VerticalAlignment=`"Center`" Margin=`"6,0,0,1`"><TextBlock Text=`"$(Esc $main)`" FontSize=`"$NextFont`" FontWeight=`"$weight`" Foreground=`"$($Theme.fg)`" Opacity=`"$opacity`"/>$second</StackPanel>"
}

# Hover text for one ring: which account, which limit, how full, when it resets.
function Get-RingTip($cfg, [string]$key, $w, [string]$place = '') {
  if (-not $cfg) { return '' }
  $pct = if ($w -and $null -ne $w.pct) { "$(Format-Pct $w.pct)%" } else { $DASH }
  $rs = if ($w) { Format-Reset $w.reset } else { '' }
  return "$(Get-Label $cfg)`n$(Get-Caption $key)  $pct$(if ($place) { "  ($place)" })$(if ($rs) { "`nresets $rs" })"
}

function New-RingElement($pct, [string]$caption, [bool]$gapAfter, [string]$short, $reset, [string]$tip = '') {
  $sz = Get-RingSize
  $el = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Orientation="Horizontal" Background="#01000000" Margin="0,0,$(if ($gapAfter) { $GapRing } else { 0 }),0">
  <Grid Width="$sz" Height="$sz">
    <Ellipse Stroke="$($Theme.ring)" StrokeThickness="$RingThick"/>
    <Path Name="Arc" StrokeThickness="$RingThick"/>
    <TextBlock Text="$(Get-InsideText $pct $short)" FontSize="$(Get-InsideSize $short)" FontWeight="Bold" Foreground="$($Theme.fg)" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1.3"/>
  </Grid>
  $(Get-NextXaml $pct $caption $reset)
</StackPanel>
"@)
  Set-Ring ($el.FindName('Arc')) $pct $sz
  if ($tip) { $el.ToolTip = $tip }
  return $el
}

# Filled wedge from 12 o'clock, clockwise.
function Set-Pie($path, $pct, [double]$c = ($RingDip / 2), [double]$r = 9.5) {
  $path.Fill = Get-UsageColor $pct
  if ($null -eq $pct -or $pct -le 0) { $path.Data = $null; return }
  if ($pct -ge 100) { $path.Data = New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point($c, $c)), $r, $r); return }
  $f = [double]$pct / 100; $a = 2 * [Math]::PI * $f
  $fig = New-Object Windows.Media.PathFigure
  $fig.StartPoint = New-Object Windows.Point($c, $c)
  $fig.IsClosed = $true
  $fig.Segments.Add((New-Object Windows.Media.LineSegment((New-Object Windows.Point($c, ($c - $r))), $true)))
  $end = New-Object Windows.Point(($c + $r * [Math]::Sin($a)), ($c - $r * [Math]::Cos($a)))
  $fig.Segments.Add((New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0, ($f -gt 0.5), ([Windows.Media.SweepDirection]::Clockwise), $true)))
  $geo = New-Object Windows.Media.PathGeometry
  $geo.Figures.Add($fig)
  $path.Data = $geo
}

# One dial for two limits. With the percentage inside it is a pie in the middle with a ring around it; otherwise two
# concentric rings with the initials (or nothing) in the middle. Beside it, one line per limit (a filled dot marks the
# inner one, a hollow dot the outer ring) with the caption or the percentage, or nothing.
function New-CombinedElement($cfg, $res, [string]$short) {
  $pieKey = Get-PieKey $cfg
  $ringKey = if ($pieKey -eq '5h') { '7d' } else { '5h' }
  $nx = Get-NextMode
  $lines = ''
  if ($nx -ne 'none' -or $script:ShowReset) {
    $lines = '<StackPanel VerticalAlignment="Center" Margin="7,0,0,0">' + (@(foreach ($k in '5h', '7d') {
      $w = Get-Win $res $k
      $main = if ($nx -eq 'none') { '' } else { Get-NextText $nx $w.pct (Get-Caption $k) $w.reset }
      $color = Get-UsageColor $w.pct
      $mark = if ($k -eq $pieKey) { "<Ellipse Width=`"8`" Height=`"8`" Fill=`"$color`"/>" } else { "<Ellipse Width=`"8`" Height=`"8`" Stroke=`"$color`" StrokeThickness=`"1.8`"/>" }
      $r = if ($script:ShowReset -and $nx -notin 'resetin', 'resetat') { Format-Reset $w.reset } else { '' }
      $reset = if ($r) { "<Run Text=`"$(if ($main) { '  ' })$(Esc $r)`" Foreground=`"$($Theme.sub)`" FontSize=`"$($NextFont - 1.5)`"/>" } else { '' }
      "<StackPanel Orientation=`"Horizontal`"><Grid Width=`"9`" Height=`"9`" VerticalAlignment=`"Center`" Margin=`"0,1,5,0`">$mark</Grid><TextBlock FontSize=`"$NextFont`"><Run Text=`"$(Esc $main)`" FontWeight=`"Bold`" Foreground=`"$($Theme.fg)`"/>$reset</TextBlock></StackPanel>"
    }) -join '') + '</StackPanel>'
  }
  $sz = Get-RingSize; $in = Get-RingSize $RingInnerDip
  if ((Get-InsideMode) -eq 'percent') {
    $dial = @"
  <Grid Width="$sz" Height="$sz">
    <Ellipse Stroke="$($Theme.ring)" StrokeThickness="$RingThick"/>
    <Path Name="Arc" StrokeThickness="$RingThick"/>
    <Ellipse Width="$($sz * 20 / 32)" Height="$($sz * 20 / 32)" Fill="$($Theme.ring)"/>
    <Path Name="Pie"/>
  </Grid>
"@
  } else {
    $text = if ((Get-InsideMode) -eq 'initials') { $short } else { '' }
    $dial = @"
  <Grid Width="$sz" Height="$sz">
    <Ellipse Stroke="$($Theme.ring)" StrokeThickness="$RingThick"/>
    <Path Name="Arc" StrokeThickness="$RingThick"/>
    <Ellipse Width="$in" Height="$in" Stroke="$($Theme.ring)" StrokeThickness="$RingInnerThick" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    <Path Name="Inner" Width="$in" Height="$in" StrokeThickness="$RingInnerThick" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    <TextBlock Text="$(Esc $text)" FontSize="$(if ($text.Length -eq 1) { $InFont - 1 } else { $InFont - 2 })" FontWeight="Bold" Foreground="$($Theme.fg)" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1.2"/>
  </Grid>
"@
  }
  $el = [Windows.Markup.XamlReader]::Parse("<StackPanel $ns Orientation=`"Horizontal`" Background=`"#01000000`">$dial$lines</StackPanel>")
  $inPlace = if ((Get-InsideMode) -ne 'percent') { 'inner ring' } else { 'middle' }
  $el.ToolTip = (Get-RingTip $cfg $pieKey (Get-Win $res $pieKey) $inPlace) + "`n`n" + (Get-RingTip $cfg $ringKey (Get-Win $res $ringKey) 'outer ring')
  Set-Ring ($el.FindName('Arc')) (Get-Win $res $ringKey).pct $sz
  if ((Get-InsideMode) -eq 'percent') { Set-Pie ($el.FindName('Pie')) (Get-Win $res $pieKey).pct ($sz / 2) ($sz * 9.5 / 32) }
  else { Set-Ring ($el.FindName('Inner')) (Get-Win $res $pieKey).pct $in $RingInnerThick }
  return $el
}

function Get-AccountTip($cfg, $res) {
  $tip = @()
  if ($cfg) {
    $plan = Get-Plan $cfg $res
    $short = if ((Get-InsideMode) -eq 'initials') { (Get-Shorts)[$cfg.name] }
    $tip += (Get-Label $cfg) + $(if ($short) { " ($short)" }) + $(if ($plan) { " $DOT $plan" })
    # Where each limit sits on the taskbar, so the bar itself needs no captions.
    $places = @{}
    if ($cfg.style -eq 'combined' -and -not (Test-NoFiveH $res)) {
      $pieKey = Get-PieKey $cfg
      $places[$pieKey] = if ((Get-InsideMode) -ne 'percent') { 'inner ring' } else { 'middle' }
      $places[$(if ($pieKey -eq '5h') { '7d' } else { '5h' })] = 'outer ring'
    } else {
      $keys = @(Get-ShownLimits $cfg $res)
      if ($keys.Count -gt 1) { for ($i = 0; $i -lt $keys.Count; $i++) { $places[$keys[$i]] = if ($i -eq 0) { 'left ring' } elseif ($i -eq $keys.Count - 1) { 'right ring' } else { 'middle ring' } } }
    }
    foreach ($k in $LimitKeys) {
      $w = Get-Win $res $k
      if ($w -and $null -ne $w.pct) { $tip += "$(Get-Caption $k)  $(Format-Pct $w.pct)%$(if ($places[$k]) { "  ($($places[$k]))" })  $DOT  resets $(Format-Reset $w.reset)" }
    }
    $tip += "Green under 70% $DOT amber from 70% $DOT red from 90%"
    if ($res.error) { $tip += $res.error }
  }
  if ($script:update) { $tip += "Update available: v$($script:update.version) (open the list to install)" }
  if ($script:job) { $tip += "Refreshing$ELL" }
  elseif ($script:updated) { $tip += 'Updated {0:HH:mm}' -f $script:updated }
  if ($script:lastError) { $tip += "Error: $($script:lastError)" }
  if ($script:configError) { $tip += $script:configError }
  return ($tip -join "`n")
}

function Get-AccountTipFor($name) {
  if (-not $name) { return $(if ($script:job) { "Looking for accounts$ELL" } else { (Get-AccountTip $null $null) + "`nNo accounts yet: right-click > Scan for accounts" }) }
  return (Get-AccountTip (Get-AcctCfg $name) (Get-Result $name))
}

# Everything that changes how the rings look. When it is the same as last time the rings are left alone
# (rebuilding them every time is what made the widget flash on click and close); only the tooltips are refreshed.
$script:widgetSig = $null
function Get-WidgetSig($cfgs) {
  $dpi = 1.0
  try { $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($widget).DpiScaleX } catch {}
  $parts = @(($script:config | ConvertTo-Json -Depth 6 -Compress), "$dpi", "$([bool]$script:job)", "$($widget.IsLoaded)", "$(@($script:newAccts | ForEach-Object name) -join ',')", (Get-Shorts | ConvertTo-Json -Compress), "shown:$(@($cfgs | ForEach-Object name) -join ',')")
  foreach ($cfg in $cfgs) {
    $res = Get-Result $cfg.name
    $parts += "no5h:$(Test-NoFiveH $res)"
    $parts += ($LimitKeys | ForEach-Object { "$((Get-Win $res $_).pct)" }) -join '/'
    if ($script:TwoRows -or $script:ShowReset -or (Get-NextMode) -in 'resetin', 'resetat') { $parts += ($LimitKeys | ForEach-Object { Format-Reset (Get-Win $res $_).reset }) -join '/' }
  }
  return ($parts -join '|')
}

function Update-Widget {
  Set-SizePreset
  $cfgs = @(Get-ShownCfgs)
  $sig = Get-WidgetSig $cfgs
  if ($sig -eq $script:widgetSig -and $WidgetEls.Groups.Children.Count) {
    foreach ($g in $WidgetEls.Groups.Children) { if ($g -is [Windows.Controls.StackPanel]) { $g.ToolTip = Get-AccountTipFor $g.Tag } }
    if ($widget.IsLoaded) { Set-WidgetPosition }
    return
  }
  $script:widgetSig = $sig
  $WidgetEls.Groups.Children.Clear()
  $WidgetEls.Root.Padding = "8,$PadV"
  if (-not $cfgs.Count) {
    $g = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Background = '#01000000' }
    [void]$g.Children.Add((New-RingElement $null (Get-Caption '5h') $true))
    [void]$g.Children.Add((New-RingElement $null (Get-Caption '7d') $false))
    $g.ToolTip = Get-AccountTipFor $null
    [void]$WidgetEls.Groups.Children.Add($g)
  }
  $shorts = Get-Shorts
  $dividers = $script:config.showDividers -eq $true
  for ($i = 0; $i -lt $cfgs.Count; $i++) {
    $cfg = $cfgs[$i]; $res = Get-Result $cfg.name
    $g = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Background = '#01000000'; Tag = $cfg.name }
    if ($i -gt 0) {
      # Same width with or without the line, so switching it on or off moves nothing.
      [void]$g.Children.Add((New-Object Windows.Controls.Border -Property @{ Width = 1; Height = $RingDip - 8; Background = $(if ($dividers) { $Theme.ring } else { 'Transparent' }); Margin = "$GapSide,0,$GapSide,0" }))
    }
    $nameMode = Get-NamesMode
    $nameEl = $null
    if ($nameMode -ne 'hidden') {
      $nameEl = New-Object Windows.Controls.TextBlock -Property @{
        Text = (Get-Label $cfg); FontSize = $NextFont + 0.5; FontWeight = 'SemiBold'; Foreground = $Theme.fg; Opacity = 0.9; MaxWidth = 110
        TextTrimming = 'CharacterEllipsis'; VerticalAlignment = 'Center'; Margin = $(if ($nameMode -eq 'left') { '0,0,8,1.2' } else { '8,0,0,1.2' })
      }
    }
    if ($nameEl -and $nameMode -eq 'left') { [void]$g.Children.Add($nameEl) }
    if ($cfg.style -eq 'combined' -and -not (Test-NoFiveH $res)) {
      [void]$g.Children.Add((New-CombinedElement $cfg $res $shorts[$cfg.name]))
    } else {
      $keys = @(Get-ShownLimits $cfg $res)
      for ($k = 0; $k -lt $keys.Count; $k++) {
        $w = Get-Win $res $keys[$k]
        [void]$g.Children.Add((New-RingElement $w.pct (Get-Caption $keys[$k]) ($k -lt $keys.Count - 1) $shorts[$cfg.name] $w.reset (Get-RingTip $cfg $keys[$k] $w)))
      }
    }
    if ($nameEl -and $nameMode -eq 'right') { [void]$g.Children.Add($nameEl) }
    $g.ToolTip = Get-AccountTipFor $cfg.name
    [void]$WidgetEls.Groups.Children.Add($g)
  }
  if ($script:newAccts.Count) {
    [void]$WidgetEls.Groups.Children.Add((New-Object Windows.Shapes.Ellipse -Property @{
      Width = 7; Height = 7; Fill = $Colors.accent; VerticalAlignment = 'Top'; Margin = '4,0,0,0'
      ToolTip = "New account found: $(($script:newAccts | ForEach-Object { Get-Label $_ }) -join ', '). Open the list to add or ignore it."
    }))
  }
  $WidgetEls.Root.Opacity = if ($script:job) { 0.6 } else { 1.0 }
  if ($widget.IsLoaded) { Set-WidgetPosition }
}

# Sit on the primary screen's taskbar, vertically centred in it; the right edge stays put as rings come and go.
function Set-WidgetPosition {
  $wa = [Windows.SystemParameters]::WorkArea
  $sh = [Windows.SystemParameters]::PrimaryScreenHeight
  $sw = [Windows.SystemParameters]::PrimaryScreenWidth
  $atTop = $wa.Top -gt 0
  $tb = if ($atTop) { $wa.Top } else { $sh - $wa.Bottom }
  if ($tb -lt 20) { $tb = 48 }  # auto-hidden taskbar: assume the default height
  $s = [Math]::Min(1.0, ($tb - 6) / ($RingDip + 2 * $PadV))
  $WidgetEls.Scale.ScaleX = $s; $WidgetEls.Scale.ScaleY = $s
  $widget.UpdateLayout()
  $h = $widget.ActualHeight; $w = $widget.ActualWidth
  $top = if ($atTop) { 0 } else { $sh - $tb }
  # Whole device pixels: a fractional window origin shifts the rings by up to half a pixel.
  $dpi = 1.0
  try { $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($widget).DpiScaleX } catch {}
  $widget.Top = [Math]::Round(($top + ($tb - $h) / 2) * $dpi) / $dpi
  $right = if ($null -ne $script:state.right) { [double]$script:state.right } else { 380 }
  $widget.Left = [Math]::Round([Math]::Max(0, [Math]::Min($sw - $w, $sw - $w - $right)) * $dpi) / $dpi
}

# ---------------------------------------------------------------- account list

[xml]$popupXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" Width="396" Height="600" Opacity="0"
        UseLayoutRounding="True" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Card" Background="$($Theme.card)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="10" Padding="8" Margin="8" VerticalAlignment="Bottom">
    <Border.RenderTransform><TranslateTransform x:Name="Slide"/></Border.RenderTransform>
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.35"/></Border.Effect>
    <Border.Resources>
      <Style x:Key="Seg" TargetType="RadioButton">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="FontSize" Value="11.5"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="RadioButton">
              <Border x:Name="Bd" Background="$($Theme.field)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="5" Padding="10,2" Margin="0,0,4,0">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="$($Theme.sub)"/></Trigger>
                <Trigger Property="IsChecked" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="$($Colors.accent)"/>
                  <Setter TargetName="Bd" Property="BorderBrush" Value="$($Colors.accent)"/>
                  <Setter Property="Foreground" Value="White"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="TextBtn" TargetType="Button">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="FontSize" Value="12"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bg" Background="$($Theme.field)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="5" Padding="12,4" Margin="6,0,0,0">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="BorderBrush" Value="$($Theme.sub)"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="AccentBtn" TargetType="Button">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Foreground" Value="White"/>
        <Setter Property="FontSize" Value="12"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bg" Background="$($Colors.accent)" BorderBrush="$($Colors.accent)" BorderThickness="1" CornerRadius="5" Padding="14,4" Margin="6,0,0,0">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Opacity" Value="0.88"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="IconBtn" TargetType="Button">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bg" Background="Transparent" CornerRadius="5" Padding="8,6">
                <ContentPresenter TextElement.FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" TextElement.FontSize="13" TextElement.Foreground="$($Theme.fg)"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="$($Theme.hover)"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bg" Property="Opacity" Value="0.35"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style TargetType="CheckBox">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="FontSize" Value="11.5"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="CheckBox">
              <StackPanel Orientation="Horizontal" Background="Transparent">
                <Border x:Name="Box" Width="16" Height="16" CornerRadius="4" BorderThickness="1.2" BorderBrush="$($Theme.sub)" Background="Transparent" VerticalAlignment="Center">
                  <TextBlock x:Name="Mark" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="White"
                             HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                </Border>
                <ContentPresenter x:Name="Label" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <ControlTemplate.Triggers>
                <Trigger Property="Content" Value="{x:Null}"><Setter TargetName="Label" Property="Margin" Value="0"/></Trigger>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="$($Theme.fg)"/></Trigger>
                <Trigger Property="IsChecked" Value="True">
                  <Setter TargetName="Box" Property="Background" Value="$($Colors.accent)"/>
                  <Setter TargetName="Box" Property="BorderBrush" Value="$($Colors.accent)"/>
                  <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style TargetType="PasswordBox">
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="CaretBrush" Value="$($Theme.fg)"/>
        <Setter Property="SelectionBrush" Value="$($Colors.accent)"/>
        <Setter Property="FontSize" Value="12.5"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="PasswordBox">
              <Border x:Name="Bd" Background="$($Theme.field)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="5" Padding="6,3">
                <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="$($Colors.accent)"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style TargetType="TextBox">
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="CaretBrush" Value="$($Theme.fg)"/>
        <Setter Property="SelectionBrush" Value="$($Colors.accent)"/>
        <Setter Property="FontSize" Value="12.5"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="TextBox">
              <Border x:Name="Bd" Background="$($Theme.field)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="5" Padding="6,3">
                <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="$($Colors.accent)"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </Border.Resources>
    <StackPanel>
      <DockPanel Margin="8,4,2,6">
        <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE72C;" VerticalAlignment="Top"/>
        <Button x:Name="EditBtn" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE713;" ToolTip="Settings" VerticalAlignment="Top"/>
        <StackPanel>
          <TextBlock x:Name="Title" Text="Claude usage" FontSize="14" FontWeight="SemiBold" Foreground="$($Theme.fg)"/>
          <TextBlock x:Name="Status" FontSize="11" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,1,0,0"/>
        </StackPanel>
      </DockPanel>
      <Border x:Name="UpdBox" Visibility="Collapsed" Background="$($Theme.hover)" BorderBrush="$($Colors.accent)" BorderThickness="1" CornerRadius="6" Padding="10,8" Margin="2,0,2,6">
        <DockPanel>
          <Button x:Name="UpdBtn" DockPanel.Dock="Right" Style="{StaticResource AccentBtn}" Content="Update now" VerticalAlignment="Top"/>
          <StackPanel>
            <TextBlock x:Name="UpdTitle" FontSize="12" FontWeight="SemiBold" Foreground="$($Colors.accent)" TextWrapping="Wrap"/>
            <TextBlock x:Name="UpdNotes" FontSize="11" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,3,0,0"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <StackPanel x:Name="NewAcctBox"/>
      <StackPanel x:Name="List"/>
      <TextBlock x:Name="Legend" FontSize="10.5" Foreground="$($Theme.sub)" Margin="10,8,10,0" TextWrapping="Wrap"/>
      <TextBlock x:Name="Footer" FontSize="10.5" Foreground="$($Theme.sub)" Margin="10,8,10,2" TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
</Window>
"@
$popup = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $popupXaml))
$PopupEls = @{}
foreach ($n in 'Card', 'Slide', 'RefreshBtn', 'EditBtn', 'Title', 'Status', 'List', 'Legend', 'Footer', 'UpdBox', 'UpdBtn', 'UpdTitle', 'UpdNotes', 'NewAcctBox') { $PopupEls[$n] = $popup.FindName($n) }

# ---------------------------------------------------------------- settings window
# A normal, resizable window (title bar, minimum size, OK / Cancel / Apply). Its size is fixed by the user, never by
# the tab shown: the tab panels sit in a scroll area, so switching tabs cannot move or resize anything.
# Edits preview live on the taskbar; OK or Apply keeps them, Cancel (or Esc, or the close button) undoes them.

[xml]$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage Widget - Settings" Width="740" Height="660" MinWidth="600" MinHeight="480"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize" ShowInTaskbar="True"
        Background="$($Theme.card)" UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" TextElement.Foreground="$($Theme.fg)">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Padding="20,16,20,12" BorderBrush="$($Theme.border)" BorderThickness="0,0,0,1">
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="Tab_acct" Style="{DynamicResource Seg}" GroupName="tabs" Content="Accounts" IsChecked="True" FontSize="13"/>
        <RadioButton x:Name="Tab_disp" Style="{DynamicResource Seg}" GroupName="tabs" Content="Display" FontSize="13"/>
        <RadioButton x:Name="Tab_cap" Style="{DynamicResource Seg}" GroupName="tabs" Content="Captions" FontSize="13"/>
        <RadioButton x:Name="Tab_upd" Style="{DynamicResource Seg}" GroupName="tabs" Content="Updates" FontSize="13"/>
      </StackPanel>
    </Border>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <Grid Margin="20,16,20,20">
        <StackPanel x:Name="PanAcct">
          <TextBlock Text="Pick an account below to change it. Tick On taskbar to put it there; the arrows set the order. The bin removes an account from the widget only; your Claude login stays." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,0,0,10"/>
          <WrapPanel x:Name="AcctChips" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
            <Button x:Name="FindBtn" Style="{DynamicResource TextBtn}" Content="Find new accounts" Margin="-6,0,0,0"/>
            <Button x:Name="AddBtn" Style="{DynamicResource TextBtn}" Content="Add account"/>
          </StackPanel>
          <TextBlock x:Name="AcctMsg" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
          <StackPanel x:Name="AcctTools"/>
          <StackPanel x:Name="SNewAcctBox" Margin="0,8,0,0"/>
          <StackPanel x:Name="SList" Margin="0,6,0,0"/>
          <TextBlock Text="Rings shows one ring per limit. Combined shows 5h and 7d in one dial. Plan: Auto shows what the API reports; setup-tokens can't read it, so pick theirs." FontSize="11.5" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="2,10,2,0"/>
        </StackPanel>
        <StackPanel x:Name="PanDisp">
          <TextBlock Text="Size" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="Sz_compact" Style="{DynamicResource Seg}" GroupName="size" Content="Compact" FontSize="12.5"/>
            <RadioButton x:Name="Sz_normal" Style="{DynamicResource Seg}" GroupName="size" Content="Normal" FontSize="12.5"/>
            <RadioButton x:Name="Sz_large" Style="{DynamicResource Seg}" GroupName="size" Content="Large" FontSize="12.5"/>
          </StackPanel>
          <TextBlock Text="Large also shows when each limit resets (when something is shown next to the ring)." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,16"/>
          <TextBlock Text="Inside the ring" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="In_none" Style="{DynamicResource Seg}" GroupName="inside" Content="Nothing" FontSize="12.5"/>
            <RadioButton x:Name="In_initials" Style="{DynamicResource Seg}" GroupName="inside" Content="Initials" FontSize="12.5"/>
            <RadioButton x:Name="In_percent" Style="{DynamicResource Seg}" GroupName="inside" Content="Percentage" FontSize="12.5"/>
          </StackPanel>
          <TextBlock Text="Set each account's initials under Accounts." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,16"/>
          <TextBlock Text="Next to the ring" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <WrapPanel>
            <RadioButton x:Name="Nx_none" Style="{DynamicResource Seg}" GroupName="next" Content="Nothing" FontSize="12.5" Margin="0,0,0,4"/>
            <RadioButton x:Name="Nx_caption" Style="{DynamicResource Seg}" GroupName="next" Content="Caption" FontSize="12.5" Margin="0,0,0,4"/>
            <RadioButton x:Name="Nx_percent" Style="{DynamicResource Seg}" GroupName="next" Content="Percentage" FontSize="12.5" Margin="0,0,0,4"/>
            <RadioButton x:Name="Nx_resetin" Style="{DynamicResource Seg}" GroupName="next" Content="Reset in" FontSize="12.5" Margin="0,0,0,4"/>
            <RadioButton x:Name="Nx_resetat" Style="{DynamicResource Seg}" GroupName="next" Content="Reset day + time" FontSize="12.5" Margin="0,0,0,4"/>
          </WrapPanel>
          <TextBlock Text="Caption is 5h / 7d (rename them under Captions). Reset in reads 'in 3h 05m'; Reset day + time reads 'Sat 03:02'. Hover the rings for everything." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,16"/>
          <TextBlock Text="Inner ring" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="Iw_5h" Style="{DynamicResource Seg}" GroupName="innerw" Content="5h inside, 7d outside" FontSize="12.5"/>
            <RadioButton x:Name="Iw_7d" Style="{DynamicResource Seg}" GroupName="innerw" Content="7d inside, 5h outside" FontSize="12.5"/>
          </StackPanel>
          <TextBlock Text="For combined dials. An account can override this under Accounts > Middle." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,16"/>
          <TextBlock Text="Account name" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="Nm_left" Style="{DynamicResource Seg}" GroupName="names" Content="Left" FontSize="12.5"/>
            <RadioButton x:Name="Nm_right" Style="{DynamicResource Seg}" GroupName="names" Content="Right" FontSize="12.5"/>
            <RadioButton x:Name="Nm_hidden" Style="{DynamicResource Seg}" GroupName="names" Content="Hidden" FontSize="12.5"/>
          </StackPanel>
          <TextBlock Text="Where each account's name sits relative to its rings." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,16"/>
          <TextBlock Text="Spacing" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="Sp_tight" Style="{DynamicResource Seg}" GroupName="spacing" Content="Tight" FontSize="12.5"/>
            <RadioButton x:Name="Sp_normal" Style="{DynamicResource Seg}" GroupName="spacing" Content="Normal" FontSize="12.5"/>
            <RadioButton x:Name="Sp_wide" Style="{DynamicResource Seg}" GroupName="spacing" Content="Wide" FontSize="12.5"/>
          </StackPanel>
          <TextBlock Text="The gap between accounts and between an account's rings. Works in every size." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,4,0,16"/>
          <CheckBox x:Name="OptDividers" Content="Dividers between accounts" FontSize="13"/>
          <TextBlock Text="A thin line between the accounts on the taskbar." FontSize="12" Foreground="$($Theme.sub)" Margin="22,2,0,14"/>
          <CheckBox x:Name="OptHideLimit" Content="Hide an account while it's at its limit" FontSize="13"/>
          <TextBlock Text="When its 5h or 7d window reaches 100% the account leaves the taskbar until the window resets. It stays in the list. If every account is at its limit they all stay." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="22,2,0,14"/>
          <CheckBox x:Name="OptLegend" Content="Show the legend in the account list" FontSize="13"/>
          <TextBlock Text="The line under the list that says which ring is which and what the colours mean." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="22,2,0,14"/>
          <CheckBox x:Name="OptAnim" Content="Animations" FontSize="13"/>
          <TextBlock Text="Fade and slide the account list in and out." FontSize="12" Foreground="$($Theme.sub)" Margin="22,2,0,18"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Refresh every" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox x:Name="OptRefresh" Width="56" TextAlignment="Center" FontSize="13" ToolTip="Minutes between refreshes (5 or more)"/>
            <TextBlock Text="minutes (5 or more)" FontSize="12" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="8,0,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel x:Name="PanCap">
          <TextBlock Text="The short names shown next to the rings and in the list." FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,0,0,10"/>
          <UniformGrid Columns="3">
            <DockPanel Margin="0,0,6,0"><TextBlock DockPanel.Dock="Top" Text="5-hour" FontSize="12" Foreground="$($Theme.sub)" Margin="0,0,0,3"/><TextBox x:Name="Cap_5h" FontSize="13"/></DockPanel>
            <DockPanel Margin="3,0,3,0"><TextBlock DockPanel.Dock="Top" Text="7-day" FontSize="12" Foreground="$($Theme.sub)" Margin="0,0,0,3"/><TextBox x:Name="Cap_7d" FontSize="13"/></DockPanel>
            <DockPanel Margin="6,0,0,0"><TextBlock DockPanel.Dock="Top" Text="Fable weekly" FontSize="12" Foreground="$($Theme.sub)" Margin="0,0,0,3"/><TextBox x:Name="Cap_fable" FontSize="13"/></DockPanel>
          </UniformGrid>
        </StackPanel>
        <StackPanel x:Name="PanUpd">
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <CheckBox x:Name="OptUpdates" Content="Check for updates daily" FontSize="13" VerticalAlignment="Center"/>
            <Button x:Name="UpdCheckBtn" Style="{DynamicResource TextBtn}" Content="Check now" Margin="8,0,0,0"/>
          </StackPanel>
          <TextBlock x:Name="UpdMsg" FontSize="12.5" Foreground="$($Theme.fg)" TextWrapping="Wrap" Margin="0,0,0,8"/>
          <Grid x:Name="UpdBar" Height="6" Visibility="Collapsed" Margin="0,0,0,10">
            <Border Background="$($Theme.bar)" CornerRadius="3"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition x:Name="UpdC1" Width="0*"/><ColumnDefinition x:Name="UpdC2" Width="100*"/></Grid.ColumnDefinitions>
              <Border Background="$($Colors.accent)" CornerRadius="3"/>
            </Grid>
          </Grid>
          <TextBlock x:Name="UpdNotesS" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,0,0,10" Visibility="Collapsed"/>
          <Button x:Name="UpdInstallBtn" Style="{DynamicResource AccentBtn}" Content="Install update" HorizontalAlignment="Left" Margin="-6,0,0,12" Visibility="Collapsed"/>
        </StackPanel>
      </Grid>
    </ScrollViewer>
    <Border Grid.Row="2" Padding="20,10,14,12" Background="$($Theme.hover)" BorderBrush="$($Theme.border)" BorderThickness="0,1,0,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="SApplyBtn" Style="{DynamicResource TextBtn}" Content="Apply" MinWidth="64"/>
          <Button x:Name="SCancelBtn" Style="{DynamicResource TextBtn}" Content="Cancel" MinWidth="64"/>
          <Button x:Name="SOkBtn" Style="{DynamicResource AccentBtn}" Content="OK" MinWidth="64"/>
        </StackPanel>
        <TextBlock x:Name="SStatus" Text="Changes preview on the taskbar. OK or Apply keeps them; Cancel undoes them." FontSize="12" Foreground="$($Theme.sub)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@
$settings = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $settingsXaml))
$settings.Resources.MergedDictionaries.Add($PopupEls.Card.Resources)
foreach ($n in 'Cap_5h', 'Cap_7d', 'Cap_fable', 'OptDividers', 'OptAnim', 'Sz_compact', 'Sz_normal', 'Sz_large', 'In_none', 'In_initials', 'In_percent', 'Nx_none', 'Nx_caption', 'Nx_percent', 'Nx_resetin', 'Nx_resetat', 'Iw_5h', 'Iw_7d', 'Nm_left', 'Nm_right', 'Nm_hidden', 'Sp_tight', 'Sp_normal', 'Sp_wide', 'OptLegend', 'AcctChips', 'OptRefresh', 'FindBtn', 'AddBtn', 'AcctMsg', 'AcctTools', 'OptUpdates', 'UpdCheckBtn', 'UpdMsg', 'UpdBar', 'UpdC1', 'UpdC2', 'UpdNotesS', 'UpdInstallBtn', 'OptHideLimit', 'SNewAcctBox', 'SList', 'PanAcct', 'PanDisp', 'PanUpd', 'PanCap', 'Tab_acct', 'Tab_disp', 'Tab_cap', 'Tab_upd', 'SApplyBtn', 'SCancelBtn', 'SOkBtn', 'SStatus') { $PopupEls[$n] = $settings.FindName($n) }
$settingsIcon = Join-Path $PSScriptRoot 'assets\icon.ico'
if (Test-Path $settingsIcon) { try { $settings.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $settingsIcon)) } catch {} }
$script:editing = $false
$script:tab = 'acct'          # Settings tab: acct | disp | cap | upd
$script:expanded = $null      # account whose details are open in the Accounts tab ('' = none)
$script:newAccts = @()        # accounts found on this PC that the widget doesn't have and wasn't told to ignore
$script:findAuto = $false
$script:lastFind = [DateTime]::MinValue

function Get-BarXaml($key, $win) {
  $pct = $win.pct
  $p = if ($null -ne $pct) { [Math]::Max(0, [Math]::Min(100, [double]$pct)) } else { 0 }
  $pctText = if ($null -ne $pct) { "$(Format-Pct $pct)%" } else { $DASH }
@"
<Grid $ns Margin="0,6,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/><ColumnDefinition Width="92"/></Grid.ColumnDefinitions>
  <TextBlock Text="$(Esc (Get-Caption $key))" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
  <Grid Grid.Column="1" Height="6" VerticalAlignment="Center">
    <Border Background="$($Theme.bar)" CornerRadius="3"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="$($p)*"/><ColumnDefinition Width="$(100 - $p)*"/></Grid.ColumnDefinitions>
      <Border Background="$(Get-UsageColor $pct)" CornerRadius="3"/>
    </Grid>
  </Grid>
  <TextBlock Grid.Column="2" Text="$pctText" FontSize="12" FontWeight="SemiBold" Foreground="$($Theme.fg)" TextAlignment="Right" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="3" Text="$(Esc (Format-Reset $win.reset))" FontSize="11" Foreground="$($Theme.sub)" TextAlignment="Right" VerticalAlignment="Center"/>
</Grid>
"@
}

function Get-Note($res) {
  if (-not $res) { return $(if ($script:job) { "Loading$ELL" } else { '' }) }
  switch ($res.status) {
    'limited' { 'Limit reached' }
    'expired' { 'Login expired: open Claude Code to renew it' }
    default   { if ($res.error) { $res.error } else { '' } }
  }
}

function New-AccountRow($cfg, $shownNames, [bool]$edit) {
  $res = Get-Result $cfg.name
  $label = Esc (Get-Label $cfg)
  $plan = Esc $(if (Get-Plan $cfg $res) { "   $(Get-Plan $cfg $res)" } else { '' })
  if ($edit) {
    $open = $true   # the account picked in the chip strip is always shown in full
    $limits = @(Get-TaskbarLimits $cfg)
    $combined = $cfg.style -eq 'combined'
    $pie = Get-PieKey $cfg
    $id = [regex]::Replace("$($cfg.name)", '[^A-Za-z0-9_]', '_')
    # Plan picker: Auto ('') plus the fixed choices, plus a custom plan from the config so it isn't lost.
    $planOpts = @('') + $PlanChoices
    $curPlan = "$($cfg.plan)".Trim()
    if ($curPlan -and $PlanChoices -notcontains $curPlan) { $planOpts += $curPlan }
    $planBoxes = (0..($planOpts.Count - 1) | ForEach-Object {
      "<RadioButton Name=`"PL_$_`" Style=`"{DynamicResource Seg}`" GroupName=`"plan_$id`" Content=`"$(Esc $(if ($planOpts[$_]) { $planOpts[$_] } else { 'Auto' }))`" IsChecked=`"$($planOpts[$_] -eq $curPlan)`"/>"
    }) -join ''
    $planApi = if ($res.apiPlan) { 'API: yes' } elseif ($res) { 'API: n/a' } else { '' }
    $ringBoxes = ($LimitKeys | ForEach-Object {
      "<CheckBox Name=`"L_$_`" Content=`"$(Esc (Get-Caption $_))`" Margin=`"0,0,14,0`" IsChecked=`"$(if ($limits -contains $_) { 'True' } else { 'False' })`"/>"
    }) -join ''
    $row = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns CornerRadius="6" Padding="10,8" Margin="0,1" Background="$($Theme.hover)">
  <StackPanel>
    <DockPanel>
      <CheckBox Name="Tb" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,12,0" Content="On taskbar" FontSize="12" ToolTip="Show this account on the taskbar"/>
      <Button Name="Del" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Content="&#xE74D;" ToolTip="Remove this account from the widget (your login is untouched)"/>
      <StackPanel Name="DelConfirm" DockPanel.Dock="Right" Orientation="Horizontal" Visibility="Collapsed">
        <Button Name="DelYes" Style="{DynamicResource TextBtn}" Content="Remove"/>
        <Button Name="DelNo" Style="{DynamicResource TextBtn}" Content="Keep"/>
      </StackPanel>
      <Button Name="Dn" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Content="&#xE74B;" ToolTip="Move down"/>
      <Button Name="Up" DockPanel.Dock="Right" Style="{DynamicResource IconBtn}" Content="&#xE74A;" ToolTip="Move up"/>
      <TextBlock Name="PlanText" DockPanel.Dock="Right" Text="$plan" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="6,0,0,0"/>
      <TextBox Name="Label" Text="$label" ToolTip="Account name"/>
    </DockPanel>
    <StackPanel Name="Det" Visibility="$(if ($open) { 'Visible' } else { 'Collapsed' })">
    <DockPanel Margin="26,9,0,0">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Style" Width="48" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
        <RadioButton Name="S_rings" Style="{DynamicResource Seg}" GroupName="style_$id" Content="Rings" IsChecked="$(-not $combined)"/>
        <RadioButton Name="S_combined" Style="{DynamicResource Seg}" GroupName="style_$id" Content="Combined" IsChecked="$combined"/>
      </StackPanel>
    </DockPanel>
    <StackPanel Orientation="Horizontal" Margin="26,8,0,0">
      <TextBlock Text="Initials" Width="48" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <TextBox Name="Short" Width="40" MaxLength="2" TextAlignment="Center" Text="$(Esc ((Get-Shorts)[$cfg.name]))" ToolTip="1 or 2 characters. Empty: automatic"/>
      <TextBlock Text="shown inside the ring when Display > Inside the ring is Initials" FontSize="10.5" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="8,0,0,0"/>
    </StackPanel>
    <WrapPanel Margin="26,8,0,0" ToolTip="Auto shows the plan the API reports. Setup-tokens can't read it, so pick it here.">
      <TextBlock Text="Plan" Width="48" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      $planBoxes
      <TextBlock Text="$(Esc $planApi)" FontSize="10.5" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="2,0,0,0"/>
    </WrapPanel>
    <WrapPanel Name="RingsPanel" Margin="26,8,0,0" Visibility="$(if ($combined) { 'Collapsed' } else { 'Visible' })">
      <TextBlock Text="Rings" Width="48" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      $ringBoxes
    </WrapPanel>
    <StackPanel Name="PiePanel" Orientation="Horizontal" Margin="26,8,0,0" Visibility="$(if ($combined) { 'Visible' } else { 'Collapsed' })">
      <TextBlock Text="Middle" Width="48" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <RadioButton Name="P_5h" Style="{DynamicResource Seg}" GroupName="pie_$id" Content="$(Esc (Get-Caption '5h'))" IsChecked="$($pie -eq '5h')"/>
      <RadioButton Name="P_7d" Style="{DynamicResource Seg}" GroupName="pie_$id" Content="$(Esc (Get-Caption '7d'))" IsChecked="$($pie -eq '7d')"/>
      <TextBlock Text="pie in the middle, the other on the ring" FontSize="10.5" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="6,0,0,0"/>
    </StackPanel>
    </StackPanel>
  </StackPanel>
</Border>
"@)
    $vis = @(Get-Visible | ForEach-Object name)
    $at = [array]::IndexOf($vis, $cfg.name)
    $up = $row.FindName('Up'); $up.Tag = $cfg.name; $up.IsEnabled = $at -gt 0
    $up.Add_Click({ param($s) Move-Account $s.Tag -1 })
    $dn = $row.FindName('Dn'); $dn.Tag = $cfg.name; $dn.IsEnabled = $at -ge 0 -and $at -lt $vis.Count - 1
    $dn.Add_Click({ param($s) Move-Account $s.Tag 1 })
    $del = $row.FindName('Del')
    $del.Tag = $row
    $del.Add_Click({ param($s) $s.Visibility = 'Collapsed'; $s.Tag.FindName('DelConfirm').Visibility = 'Visible' })
    $no = $row.FindName('DelNo')
    $no.Tag = $row
    $no.Add_Click({ param($s) $s.Tag.FindName('DelConfirm').Visibility = 'Collapsed'; $s.Tag.FindName('Del').Visibility = 'Visible' })
    $yes = $row.FindName('DelYes')
    $yes.Tag = $cfg.name
    $yes.Add_Click({ param($s) Remove-Account $s.Tag })
    $tb = $row.FindName('Label')
    $tb.Tag = $cfg.name
    $tb.Add_TextChanged({ param($s) Set-AcctProp $s.Tag 'label' $s.Text; Save-UiConfig; Update-Widget })
    $sb = $row.FindName('Short')
    $sb.Tag = $cfg.name
    $sb.Add_TextChanged({ param($s) Set-AcctProp $s.Tag 'short' $s.Text.Trim(); Save-UiConfig; Update-Widget })
    foreach ($k in $LimitKeys) {
      $cb = $row.FindName("L_$k")
      $cb.Tag = "$($cfg.name)|$k"
      $cb.Add_Click({ param($s) $n, $key = $s.Tag -split '\|', 2; Set-Limit $n $key ([bool]$s.IsChecked) $s })
    }
    foreach ($opt in 'rings', 'combined') {
      $rb = $row.FindName("S_$opt")
      $rb.Tag = @{ name = $cfg.name; value = $opt; row = $row }
      $rb.Add_Checked({
        param($s)
        Set-AcctProp $s.Tag.name 'style' $s.Tag.value
        $c = $s.Tag.value -eq 'combined'
        $s.Tag.row.FindName('RingsPanel').Visibility = if ($c) { 'Collapsed' } else { 'Visible' }
        $s.Tag.row.FindName('PiePanel').Visibility = if ($c) { 'Visible' } else { 'Collapsed' }
        Save-UiConfig; Update-Widget
      })
    }
    foreach ($opt in '5h', '7d') {
      $rb = $row.FindName("P_$opt")
      $rb.Tag = @{ name = $cfg.name; value = $opt }
      $rb.Add_Checked({ param($s) Set-AcctProp $s.Tag.name 'pie' $s.Tag.value; Save-UiConfig; Update-Widget })
    }
    for ($i = 0; $i -lt $planOpts.Count; $i++) {
      $rb = $row.FindName("PL_$i")
      $rb.Tag = @{ name = $cfg.name; value = $planOpts[$i]; row = $row }
      $rb.Add_Checked({
        param($s)
        Set-AcctProp $s.Tag.name 'plan' $s.Tag.value
        $shown = Get-Plan (Get-AcctCfg $s.Tag.name) (Get-Result $s.Tag.name)
        $s.Tag.row.FindName('PlanText').Text = if ($shown) { "   $shown" } else { '' }
        Save-UiConfig; Update-Widget
      })
    }
  } else {
    $note = Get-Note $res
    $bars = $(if (Test-NoFiveH $res) { '' } else { Get-BarXaml '5h' (Get-Win $res '5h') }) + (Get-BarXaml '7d' (Get-Win $res '7d'))
    $fable = Get-Win $res 'fable'
    if ($fable -and $null -ne $fable.pct) { $bars += Get-BarXaml 'fable' $fable }
    $noteXaml = if ($note) {
      $color = if ($res.status -in 'limited', 'expired', 'invalid', 'error') { $Colors.bad } else { $Theme.sub }
      "<TextBlock Text=`"$(Esc $note)`" FontSize=`"11`" Foreground=`"$color`" Margin=`"0,6,0,0`" TextWrapping=`"Wrap`"/>"
    } else { '' }
    $row = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns CornerRadius="6" Padding="10,8" Margin="0,1" Background="Transparent">
  <StackPanel>
    <DockPanel>
      <TextBlock TextTrimming="CharacterEllipsis" VerticalAlignment="Center"><Run Text="$label" FontSize="13" FontWeight="SemiBold" Foreground="$($Theme.fg)"/><Run Text="$plan" FontSize="11" Foreground="$($Theme.sub)"/></TextBlock>
    </DockPanel>
    <StackPanel Margin="26,0,0,0">$bars$noteXaml</StackPanel>
  </StackPanel>
</Border>
"@)
    $via = switch ($res.method) { 'usage-api' { 'Read via the usage API (free)' } 'probe' { 'Read via a 1-token probe (setup-tokens cannot use the usage API)' } default { $null } }
    $planVia = if ($res.apiPlan) { 'Plan read from the API' } elseif ($res -and $cfg.plan) { "Plan set in settings (the API doesn't report it for this token)" }
    $tipLines = @($via, $planVia) | Where-Object { $_ }
    if ($tipLines) { $row.ToolTip = $tipLines -join "`n" }
    $row.Add_MouseEnter({ param($s) $s.Background = $Theme.hover })
    $row.Add_MouseLeave({ param($s) $s.Background = 'Transparent' })
  }
  $cb = $row.FindName('Tb')
  if ($cb) {
    $cb.IsChecked = $shownNames -contains $cfg.name
    $cb.Tag = $cfg.name
    $cb.Add_Click({ param($s) Set-Taskbar $s.Tag ([bool]$s.IsChecked) $s })
  }
  return $row
}

function Update-RefreshButton {
  $cd = Get-Cooldown
  $PopupEls.RefreshBtn.IsEnabled = -not $script:job -and $cd -eq 0
  $PopupEls.RefreshBtn.ToolTip = if ($script:job) { "Refreshing$ELL" } elseif ($cd) { "You can refresh again in ${cd}s" } else { 'Refresh now' }
}

# The account list (the popup). Settings is its own window: Update-Settings. Edit flows call this to refresh both;
# -ListOnly leaves an open Settings window alone (rebuilding it would take the focus from someone typing).
function Update-Popup([switch]$ListOnly) {
  Update-RefreshButton
  $PopupEls.Status.Text = if ($script:job) { if ($script:job.discover) { "Scanning for accounts$ELL" } else { "Refreshing$ELL" } }
    elseif ($script:lastError) { "Error: $($script:lastError)" }
    elseif ($script:configError) { $script:configError }
    elseif ($script:updated) { "Updated {0:HH:mm} $DOT every {1} min{2}" -f $script:updated, (Get-RefreshMinutes), $(if ($script:notice) { " $DOT $($script:notice)" }) }
    else { '' }
  $PopupEls.Status.Foreground = if (-not $script:job -and ($script:lastError -or $script:configError)) { $Colors.bad } else { $Theme.sub }

  $PopupEls.UpdBox.Visibility = if ($script:update) { 'Visible' } else { 'Collapsed' }
  if ($script:update) {
    $PopupEls.UpdTitle.Text = "Update available: v$($script:update.version) (you have v$AppVersion)"
    $PopupEls.UpdNotes.Text = "$($script:update.notes)"
    $PopupEls.UpdNotes.Visibility = if ($script:update.notes) { 'Visible' } else { 'Collapsed' }
  }
  Update-UpdateControls

  $PopupEls.List.Children.Clear()
  $shown = @(Get-TaskbarCfgs | ForEach-Object name)
  $cfgs = Get-Visible
  foreach ($cfg in $cfgs) { [void]$PopupEls.List.Children.Add((New-AccountRow $cfg $shown $false)) }
  if (-not @($cfgs).Count) {
    $empty = New-Object Windows.Controls.TextBlock
    $empty.Text = if ($script:job) { "Looking for accounts$ELL" } else { 'No accounts found. Log in with Claude Code (run claude), then right-click the rings > Scan for accounts.' }
    $empty.Foreground = $Theme.sub; $empty.Margin = '10,8'; $empty.TextWrapping = 'Wrap'
    [void]$PopupEls.List.Children.Add($empty)
  }
  Update-NewAcctBox
  Update-Legend
  $PopupEls.Footer.Text = "Hover a ring for details $DOT Ctrl+drag the rings to move them $DOT choose accounts in Settings"
  if (-not $ListOnly -and $script:editing -and $settings.IsVisible) { Update-Settings }
}

# The Settings window: the active tab's panel, and the values every control starts from.
function Update-Settings {
  $acct = $script:tab -eq 'acct'
  $PopupEls.SList.Children.Clear()
  $shown = @(Get-TaskbarCfgs | ForEach-Object name)
  $cfgs = Get-Visible
  if (@($cfgs).Count -and (-not $script:expanded -or @($cfgs | Where-Object name -eq $script:expanded).Count -eq 0)) { $script:expanded = @($cfgs)[0].name }
  # Accounts tab: one chip per account (dimmed when it is not on the taskbar), and the picked account's details below.
  $PopupEls.AcctChips.Children.Clear()
  if ($acct) {
    foreach ($cfg in $cfgs) {
      $chip = New-Object Windows.Controls.RadioButton -Property @{ Content = (Get-Label $cfg); GroupName = 'acctchip'; Tag = $cfg.name; FontSize = 12.5; Margin = '0,0,0,4'; IsChecked = ($script:expanded -eq $cfg.name) }
      $chip.Style = $PopupEls.Card.Resources['Seg']
      if ($shown -notcontains $cfg.name) { $chip.Opacity = 0.6; $chip.ToolTip = 'Not on the taskbar' }
      $chip.Add_Checked({ param($s) if ($script:expanded -ne $s.Tag) { $script:expanded = $s.Tag; Update-Settings } })
      [void]$PopupEls.AcctChips.Children.Add($chip)
    }
    foreach ($cfg in $cfgs) { if ($cfg.name -eq $script:expanded) { [void]$PopupEls.SList.Children.Add((New-AccountRow $cfg $shown $true)) } }
  }
  $script:loadingCaptions = $true
  foreach ($k in $LimitKeys) { $PopupEls["Cap_$k"].Text = Get-Caption $k }
  $PopupEls.OptDividers.IsChecked = $script:config.showDividers -eq $true
  $PopupEls.OptHideLimit.IsChecked = $script:config.hideAtLimit -eq $true
  $PopupEls.OptLegend.IsChecked = $script:config.showLegend -eq $true
  $PopupEls["Nm_$(Get-NamesMode)"].IsChecked = $true
  $PopupEls["Sp_$(Get-SpacingKey)"].IsChecked = $true
  $PopupEls["Iw_$(Get-PieKey $null)"].IsChecked = $true
  $PopupEls["Sz_$(Get-SizeKey)"].IsChecked = $true
  $PopupEls["In_$(Get-InsideMode)"].IsChecked = $true
  $PopupEls["Nx_$(Get-NextMode)"].IsChecked = $true
  $PopupEls.OptAnim.IsChecked = Test-Option 'animations'
  $PopupEls.OptUpdates.IsChecked = Test-Option 'updateCheck'
  Update-UpdateControls
  $PopupEls.OptRefresh.Text = "$(Get-RefreshMinutes)"
  $script:loadingCaptions = $false
  foreach ($t in 'acct', 'disp', 'cap', 'upd') {
    $PopupEls["Pan$((Get-Culture).TextInfo.ToTitleCase($t))"].Visibility = if ($script:tab -eq $t) { 'Visible' } else { 'Collapsed' }
    $PopupEls["Tab_$t"].IsChecked = $script:tab -eq $t
  }
  if ($acct) { Show-AcctTool }
  Update-NewAcctBox
  Update-SettingsButtons
}

# Apply is live only while something differs from the last saved state.
function Update-SettingsButtons {
  $dirty = $script:editing -and $script:configBackup -and (($script:config | ConvertTo-Json -Depth 8) -ne $script:configBackup)
  $PopupEls.SApplyBtn.IsEnabled = [bool]$dirty
}

# One line under the list: which ring is which on the taskbar, and what the colours mean.
function Update-Legend {
  $t = $PopupEls.Legend
  $t.Inlines.Clear()
  # Off by default (Settings > Display > legend): the hover text on the rings says the same.
  $t.Visibility = if ($script:config.showLegend -eq $true) { 'Visible' } else { 'Collapsed' }
  if ($script:config.showLegend -ne $true) { return }
  $cfgs = @(Get-TaskbarCfgs)
  $parts = @()
  $isComb = { param($c) $c.style -eq 'combined' -and -not (Test-NoFiveH (Get-Result $c.name)) }
  $pies = @($cfgs | Where-Object { & $isComb $_ } | ForEach-Object { Get-PieKey $_ } | Select-Object -Unique)
  if ($pies.Count -eq 1) {
    $parts += "Inner $(Get-Caption $pies[0]), outer $(Get-Caption $(if ($pies[0] -eq '5h') { '7d' } else { '5h' }))"
  } elseif ($pies.Count -gt 1) { $parts += 'Inner and outer: hover a dial' }
  $ringKeys = @($cfgs | Where-Object { -not (& $isComb $_) } | ForEach-Object { Get-ShownLimits $_ (Get-Result $_.name) })
  $ringKeys = @($LimitKeys | Where-Object { $ringKeys -contains $_ })
  if ($ringKeys.Count -gt 1) { $parts += "Rings left to right: $(($ringKeys | ForEach-Object { Get-Caption $_ }) -join ', ')" }
  if ($parts.Count) {
    $t.Inlines.Add((New-Object Windows.Documents.Run($parts -join " $DOT ")))
    $t.Inlines.Add((New-Object Windows.Documents.LineBreak))
  }
  $nb = [string][char]0x00A0
  foreach ($c in @(@($Colors.ok, "under${nb}70%   "), @($Colors.warn, "70%+   "), @($Colors.bad, '90%+'))) {
    $dot = New-Object Windows.Documents.Run([string][char]0x25CF)
    $dot.Foreground = $c[0]
    $t.Inlines.Add($dot)
    $t.Inlines.Add((New-Object Windows.Documents.Run("$nb$($c[1])")))
  }
}

# Accounts found on this PC that the widget doesn't have yet (minus the ones the user chose to ignore).
function Get-IgnoredNames { @($script:state.ignoredAccounts | Where-Object { $_ }) }

function Update-NewAccts {
  $ign = Get-IgnoredNames
  $script:newAccts = @($script:found | Where-Object { $_ -and -not (Test-AcctKnown $_) -and $ign -notcontains $_.name })
}

function Add-NewAcct($a) {
  if (-not (Test-AcctKnown $a)) {
    $o = [ordered]@{ name = $a.name; label = $a.label; plan = "$($a.plan)".Trim(); source = $a.source }
    if ($a.dir) { $o.dir = $a.dir }
    Add-AcctCfg $o
  }
  if (-not $script:editing) {
    Save-UiConfig
    $script:lastTry = [DateTime]::MinValue; Start-Refresh
  }
  Update-NewAccts; Update-Widget; Update-Popup
}

function Skip-NewAcct($a) {
  $script:state.ignoredAccounts = @(Get-IgnoredNames) + @($a.name)
  Save-State
  Update-NewAccts; Update-Widget; Update-Popup
}

function Update-NewAcctBox {
  foreach ($box in $PopupEls.NewAcctBox, $PopupEls.SNewAcctBox) {
    $box.Children.Clear()
    foreach ($a in $script:newAccts) { [void]$box.Children.Add((New-NewAcctRow $a)) }
  }
}

function New-NewAcctRow($a) {
    $plan = "$($a.plan)".Trim()
    $row = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns Background="$($Theme.hover)" BorderBrush="$($Colors.accent)" BorderThickness="1" CornerRadius="6" Padding="10,6" Margin="2,0,2,6">
  <DockPanel>
    <Button Name="NIgn" DockPanel.Dock="Right" Style="{DynamicResource TextBtn}" Content="Ignore"/>
    <Button Name="NAdd" DockPanel.Dock="Right" Style="{DynamicResource AccentBtn}" Content="Add"/>
    <TextBlock VerticalAlignment="Center" TextTrimming="CharacterEllipsis" FontSize="12"><Run Text="New account found: " Foreground="$($Theme.sub)"/><Run Text="$(Esc (Get-Label $a))" FontWeight="SemiBold" Foreground="$($Theme.fg)"/><Run Text="$(Esc $(if ($plan) { "   $plan" } else { '' }))" Foreground="$($Theme.sub)"/></TextBlock>
  </DockPanel>
</Border>
"@)
    $add = $row.FindName('NAdd'); $add.Tag = $a; $add.Add_Click({ param($s) Add-NewAcct $s.Tag })
    $ign = $row.FindName('NIgn'); $ign.Tag = $a; $ign.Add_Click({ param($s) Skip-NewAcct $s.Tag })
    return $row
}

function Move-Account([string]$name, [int]$by) {
  $all = @(Get-AcctCfgs)
  $i = [array]::IndexOf(@($all | ForEach-Object name), $name)
  $j = $i + $by
  while ($i -ge 0 -and $j -ge 0 -and $j -lt $all.Count -and $all[$j].hidden -eq $true) { $j += $by }
  if ($i -lt 0 -or $j -lt 0 -or $j -ge $all.Count) { return }
  $t = $all[$i]; $all[$i] = $all[$j]; $all[$j] = $t
  $script:config.accounts = $all
  Save-UiConfig  # while Settings is open this waits for Save, like every other edit
  Update-Widget
  Update-Popup
}

foreach ($k in $LimitKeys) {
  $PopupEls["Cap_$k"].Tag = $k
  $PopupEls["Cap_$k"].Add_TextChanged({
    param($s)
    if ($script:loadingCaptions) { return }
    if (-not $script:config.captions) { $script:config | Add-Member -Force captions ([pscustomobject]$DefaultCaptions) }
    $script:config.captions | Add-Member -Force -NotePropertyName $s.Tag -NotePropertyValue $s.Text
    Save-UiConfig
    Update-Widget
  })
}

foreach ($choice in @(@('Sz', 'size', 'compact', 'normal', 'large'), @('In', 'inside', 'none', 'initials', 'percent'), @('Nx', 'next', 'none', 'caption', 'percent', 'resetin', 'resetat'),
    @('Nm', 'names', 'left', 'right', 'hidden'), @('Sp', 'spacing', 'tight', 'normal', 'wide'), @('Iw', 'innerWindow', '5h', '7d'))) {
  foreach ($v in $choice[2..($choice.Count - 1)]) {
    $rb = $PopupEls["$($choice[0])_$v"]
    $rb.Tag = @{ key = $choice[1]; value = $v }
    $rb.Add_Checked({
      param($s)
      if ($script:loadingCaptions) { return }
      $script:config | Add-Member -Force -NotePropertyName $s.Tag.key -NotePropertyValue $s.Tag.value
      # A global inner-ring choice replaces any per-account one, so every dial follows it.
      if ($s.Tag.key -eq 'innerWindow') { foreach ($a in @(Get-AcctCfgs)) { if ($a.pie) { Set-AcctProp $a.name 'pie' '' } } }
      Save-UiConfig
      Update-Widget
    })
  }
}
foreach ($opt in @(@('OptDividers', 'showDividers'), @('OptHideLimit', 'hideAtLimit'), @('OptLegend', 'showLegend'), @('OptAnim', 'animations'), @('OptUpdates', 'updateCheck'))) {
  $PopupEls[$opt[0]].Tag = $opt[1]
  $PopupEls[$opt[0]].Add_Click({
    param($s)
    $script:config | Add-Member -Force -NotePropertyName $s.Tag -NotePropertyValue ([bool]$s.IsChecked)
    Save-UiConfig
    Update-Widget
  })
}
# Minutes between refreshes: saved once it's a whole number from 5 to 1440; leaving the box restores the saved value.
$PopupEls.OptRefresh.Add_TextChanged({
  param($s)
  if ($script:loadingCaptions) { return }
  $m = 0
  if ([int]::TryParse($s.Text.Trim(), [ref]$m) -and $m -ge 5 -and $m -le 1440) {
    $script:config | Add-Member -Force refreshMinutes $m
    Save-UiConfig
  }
})
$PopupEls.OptRefresh.Add_LostKeyboardFocus({ param($s) $s.Text = "$(Get-RefreshMinutes)" })

# ---------------------------------------------------------------- account tools (Settings)
# Find / Add / Remove change the in-memory config like every other Settings edit: Save keeps it,
# Cancel drops it. Only references are stored (folder, env var name); a token is never read for display.
# A pasted token is the exception to "in memory until Save": it goes to the Windows user environment the
# moment the user approves it (to xndr-claude when installed, else a user variable) and stays even if Settings is
# cancelled; config.json keeps the variable NAME only.

$script:acctMode = $null      # 'find' | 'add' | 'delenv' | $null
$script:envDrop = @()         # user variables whose delete was approved (applied on Save)
$script:delEnvVar = $null     # variable the delete prompt is asking about
$script:acctNote = $null
$script:acctsChanged = $false
$script:found = $null         # discovered accounts (Claude Code logins + xndr-claude), $null = not searched yet
$script:findJob = $null
$script:modal = $false
$script:nf = @{ label = ''; src = 'claude-code'; input = ''; plan = '' }
$script:nfEls = @{}

function Test-AcctKnown($a) {
  @(Get-AcctCfgs | Where-Object {
    $_.name -eq $a.name -or ($_.source -eq 'claude-code' -and $a.source -eq 'claude-code' -and "$($_.dir)" -eq "$($a.dir)")
  }).Count -gt 0
}

function Get-UniqueName([string]$base) {
  $slug = ($base.ToLower() -replace '[^a-z0-9._-]+', '-').Trim('-')
  if (-not $slug) { $slug = 'account' }
  $name = $slug; $n = 2
  while (Get-AcctCfg $name) { $name = "$slug-$n"; $n++ }
  return $name
}

function Add-AcctCfg($a) {
  $script:config.accounts = @(Get-AcctCfgs) + @([pscustomobject]$a)
  $script:acctsChanged = $true
}

function Remove-Account([string]$name) {
  $gone = Get-AcctCfg $name
  $script:config.accounts = @(Get-AcctCfgs | Where-Object { $_.name -ne $name })
  $script:acctsChanged = $true
  $script:acctNote = "Removed. Save to keep it, Cancel to undo."
  # A token the widget saved gets its own approval before the variable is deleted.
  if ($gone.envManaged -eq $true -and "$($gone.env)" -match '^CLAUDE_USAGE_TOKEN_[A-Z0-9_]+$') {
    $script:delEnvVar = "$($gone.env)"; $script:acctMode = 'delenv'
  }
  Update-Widget
  Update-Popup
}

function Set-DemoFound {
  $script:found = @(
    [pscustomobject]@{ name = 'claude-code-work'; label = 'work@example.com'; plan = 'Max 5x'; source = 'claude-code'; dir = 'C:\Users\demo\.claude-work'; pick = $true; sel = 'Max 5x' }
    [pscustomobject]@{ name = 'ci-bot'; label = 'CI bot'; plan = ''; source = 'xndr-claude'; pick = $false; sel = '' }
  )
}

# Discovery can take a minute (xndr-claude, when installed, probes each account), so it runs in a background runspace.
function Start-Find([switch]$Auto) {
  if ($script:findJob) { if (-not $Auto) { $script:findAuto = $false }; return }
  $script:findAuto = [bool]$Auto
  $script:lastFind = Get-Date
  if ($Demo) { Set-DemoFound; return }
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({
    param($lib)
    $ErrorActionPreference = 'Stop'
    . $lib
    @(Find-ClaudeCodeLogins | ForEach-Object { [pscustomobject]$_ }) + @(Import-XndrClaudeAccounts | ForEach-Object { [pscustomobject]$_ })
  }).AddArgument($LibPath)
  $script:findJob = @{ ps = $ps; handle = $ps.BeginInvoke(); started = Get-Date }
  $findTimer.Start()
}

function Complete-Find {
  $j = $script:findJob
  $timedOut = ((Get-Date) - $j.started).TotalSeconds -gt 90
  if (-not $timedOut -and -not $j.handle.IsCompleted) { return }
  $findTimer.Stop()
  $script:findJob = $null
  $list = @()
  try {
    if ($timedOut) { $j.ps.Stop(); throw 'account search timed out' }
    $list = @($j.ps.EndInvoke($j.handle) | Where-Object { $_ })
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    Write-Log "find accounts: $($e.Message)"
    if (-not $script:findAuto) { $script:acctNote = "Search failed: $($e.Message)" }
    $failed = $true
  } finally { $j.ps.Dispose() }
  foreach ($a in $list) {
    $a | Add-Member -Force -NotePropertyName pick -NotePropertyValue $false
    $a | Add-Member -Force -NotePropertyName sel -NotePropertyValue "$($a.plan)".Trim()
  }
  # A failed background check must not wipe an earlier result.
  if (-not ($failed -and $script:findAuto)) { $script:found = $list }
  Update-NewAccts
  Update-Widget
  # Rebuilding the whole list under someone typing in Settings would steal their focus.
  if ($popup.IsVisible) { Update-Popup -ListOnly }
  if ($script:editing -and $settings.IsVisible) { Update-NewAcctBox; if ($script:tab -eq 'acct') { Show-AcctTool } }
}

# On startup and then hourly (see the minute timer): look for accounts the widget doesn't have.
# Nothing is added on its own; they show as "New account found" with Add / Ignore.
function Start-AutoFind {
  if ($Demo -or $script:editing -or $script:findJob) { return }
  Start-Find -Auto
}

function Get-PlanSegXaml([string]$prefix, [string]$cur) {
  $opts = @('') + $PlanChoices
  (0..($opts.Count - 1) | ForEach-Object {
    "<RadioButton Name=`"$($prefix)_$_`" Style=`"{DynamicResource Seg}`" GroupName=`"$prefix`" Content=`"$(if ($opts[$_]) { Esc $opts[$_] } else { 'Auto' })`" IsChecked=`"$($opts[$_] -eq $cur)`"/>"
  }) -join ''
}

function New-ToolBar([string]$addText, [scriptblock]$onAdd) {
  $bar = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
  <Button Name="TClose" Style="{DynamicResource TextBtn}" Content="Close"/>
  $(if ($addText) { "<Button Name=`"TAdd`" Style=`"{DynamicResource AccentBtn}`" Content=`"$addText`"/>" })
</StackPanel>
"@)
  $bar.FindName('TClose').Add_Click({ $script:acctMode = $null; Show-AcctTool })
  if ($addText) { $bar.FindName('TAdd').Add_Click($onAdd) }
  return $bar
}

function Show-AcctTool {
  $pan = $PopupEls.AcctTools
  $pan.Children.Clear()
  $PopupEls.AcctMsg.Text = "$($script:acctNote)"
  $PopupEls.AcctMsg.Visibility = if ($script:acctNote) { 'Visible' } else { 'Collapsed' }
  if ($script:acctMode -eq 'find') { Show-FindTool $pan }
  elseif ($script:acctMode -eq 'add') { Show-AddTool $pan }
  elseif ($script:acctMode -eq 'delenv') { Show-DelEnvTool $pan }
}

# Approval to delete the user environment variable that held a removed account's token.
function Show-DelEnvTool($pan) {
  $v = $script:delEnvVar
  $bar = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Margin="0,8,0,0">
  <TextBlock Text="$(Esc "Also delete the Windows user environment variable $v (the saved token)?")" FontSize="11.5" Foreground="$($Theme.fg)" TextWrapping="Wrap"/>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
    <Button Name="DKeep" Style="{DynamicResource TextBtn}" Content="Keep it"/>
    <Button Name="DDel" Style="{DynamicResource AccentBtn}" Content="Delete it"/>
  </StackPanel>
</StackPanel>
"@)
  $bar.FindName('DKeep').Add_Click({ $script:acctMode = $null; $script:delEnvVar = $null; Show-AcctTool })
  $bar.FindName('DDel').Add_Click({
    $script:envDrop = @($script:envDrop) + @($script:delEnvVar)
    $script:acctNote = "Removed. $($script:delEnvVar) is deleted when you Save."
    $script:acctMode = $null; $script:delEnvVar = $null
    Show-AcctTool
  })
  [void]$pan.Children.Add($bar)
}

# Save deletes the variables of accounts the user explicitly removed. Cancel never touches a saved token.
function Complete-EnvChanges([bool]$keep) {
  if ($keep) {
    foreach ($v in @($script:envDrop)) {
      try { Remove-UserEnvToken $v } catch { Write-Log "env var delete failed ($v): $($_.Exception.GetType().Name)" }
    }
  }
  $script:envDrop = @()
}

function Show-FindTool($pan) {
  $hd = New-Object Windows.Controls.TextBlock -Property @{ FontSize = 11.5; Foreground = $Theme.fg; Margin = '0,8,0,2'; TextWrapping = 'Wrap' }
  [void]$pan.Children.Add($hd)
  if ($script:findJob -or $null -eq $script:found) { $hd.Text = "Searching for accounts$ELL"; return }
  $new = @($script:found | Where-Object { -not (Test-AcctKnown $_) })
  if (-not $new.Count) { $hd.Text = 'No new accounts found.'; [void]$pan.Children.Add((New-ToolBar $null $null)); return }
  $hd.Text = "Found $($new.Count) not in the widget yet. Tick the ones to add:"
  for ($i = 0; $i -lt $new.Count; $i++) {
    $a = $new[$i]
    $plan = "$($a.plan)".Trim()
    $from = if ($a.source -eq 'xndr-claude') { 'xndr-claude account' } else { "Claude Code login$(if ($a.dir) { ' ' + $a.dir } else { '' })" }
    $planPick = if (-not $plan) {
      "<WrapPanel Margin=`"22,4,0,0`"><TextBlock Text=`"Plan`" Width=`"34`" FontSize=`"11`" Foreground=`"$($Theme.sub)`" VerticalAlignment=`"Center`"/>$(Get-PlanSegXaml "PF$i" '')</WrapPanel>"
    } else { '' }
    $row = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Margin="0,5,0,0">
  <CheckBox Name="CK"><TextBlock TextTrimming="CharacterEllipsis"><Run Text="$(Esc (Get-Label $a))" FontWeight="SemiBold"/><Run Text="$(Esc $(if ($plan) { "   $plan" } else { '' }))" Foreground="$($Theme.sub)"/></TextBlock></CheckBox>
  <TextBlock Text="$(Esc $from)" Margin="22,1,0,0" FontSize="10.5" Foreground="$($Theme.sub)" TextTrimming="CharacterEllipsis"/>
  $planPick
</StackPanel>
"@)
    $ck = $row.FindName('CK')
    $ck.Tag = $a
    $ck.IsChecked = [bool]$a.pick
    $ck.Add_Click({ param($s) $s.Tag.pick = [bool]$s.IsChecked })
    if (-not $plan) {
      $opts = @('') + $PlanChoices
      for ($k = 0; $k -lt $opts.Count; $k++) {
        $rb = $row.FindName("PF$($i)_$k")
        $rb.Tag = @{ a = $a; v = $opts[$k] }
        $rb.Add_Checked({ param($s) $s.Tag.a.sel = $s.Tag.v })
      }
    }
    [void]$pan.Children.Add($row)
  }
  [void]$pan.Children.Add((New-ToolBar 'Add ticked' {
    $n = 0
    foreach ($a in @($script:found)) {
      if (-not $a.pick -or (Test-AcctKnown $a)) { continue }
      $o = [ordered]@{ name = $a.name; label = $a.label; plan = "$($a.sel)"; source = $a.source }
      if ($a.dir) { $o.dir = $a.dir }
      Add-AcctCfg $o
      $n++
    }
    if ($n) {
      $script:acctNote = "Added $n account$(if ($n -ne 1) { 's' }). Save to keep $(if ($n -ne 1) { 'them' } else { 'it' })."
      $script:acctMode = $null
      Update-Widget
      Update-Popup
    } else {
      $script:acctNote = 'Nothing ticked.'
      Show-AcctTool
    }
  }))
}

function Update-NfSource {
  $e = $script:nfEls; $src = $script:nf.src
  $tok = $src -eq 'token'
  $e.hint.Text = switch ($src) { 'token' { 'Token' } 'xndr-claude' { 'Account' } default { 'Folder' } }
  $e.note.Text = switch ($src) {
    'token'       { 'Paste the token from running "claude setup-token". It is saved to your Windows user environment after you approve it, and never shown again.' }
    'xndr-claude' { 'Name of an xndr-claude account.' }
    default       { 'Folder holding .credentials.json. Empty = your default Claude Code login (~\.claude).' }
  }
  $e.browse.Visibility = if ($src -eq 'claude-code') { 'Visible' } else { 'Collapsed' }
  $e.chips.Visibility = if ($src -eq 'xndr-claude' -and $e.chips.Children.Count) { 'Visible' } else { 'Collapsed' }
  $e.input.Visibility = if ($tok) { 'Collapsed' } else { 'Visible' }
  $e.token.Visibility = if ($tok) { 'Visible' } else { 'Collapsed' }
  $e.approve.Visibility = 'Collapsed'
  $e.msg.Visibility = 'Collapsed'
}

function Show-AddTool($pan) {
  $nf = $script:nf
  # xndr-claude is offered only on a PC that has it (or when the search found its accounts).
  $hasXc = Test-Command 'xndr-claude'
  $hasX = $hasXc -or @($script:found | Where-Object { $_.source -eq 'xndr-claude' }).Count -gt 0
  $srcs = @(@('claude-code', 'Claude Code login'), @('token', 'Token'))
  if ($hasX) { $srcs += ,@('xndr-claude', 'xndr-claude') }
  if ($nf.src -notin ($srcs | ForEach-Object { $_[0] })) { $nf.src = 'claude-code' }
  $srcBoxes = ($srcs | ForEach-Object {
    "<RadioButton Name=`"NS_$($_[0] -replace '\W', '_')`" Style=`"{DynamicResource Seg}`" GroupName=`"nfsrc`" Content=`"$($_[1])`" IsChecked=`"$($nf.src -eq $_[0])`"/>"
  }) -join ''
  $form = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Margin="0,8,0,0">
  <DockPanel><TextBlock Text="Name" Width="56" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/><TextBox Name="NfLabel" Text="$(Esc $nf.label)" ToolTip="Shown in the list and on the taskbar. Optional."/></DockPanel>
  <StackPanel Orientation="Horizontal" Margin="0,8,0,0"><TextBlock Text="Source" Width="56" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>$srcBoxes</StackPanel>
  <DockPanel Margin="0,8,0,0">
    <TextBlock Name="NfHint" Width="56" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
    <Button Name="NfBrowse" DockPanel.Dock="Right" Style="{DynamicResource TextBtn}" Content="Browse$ELL"/>
    <Grid>
      <TextBox Name="NfInput" Text="$(Esc $nf.input)"/>
      <PasswordBox Name="NfToken" Visibility="Collapsed" ToolTip="Setup token (sk-ant-oat...)"/>
    </Grid>
  </DockPanel>
  <WrapPanel Name="NfChips" Margin="56,6,0,0"/>
  <TextBlock Name="NfNote" Margin="56,4,0,0" FontSize="10.5" Foreground="$($Theme.sub)" TextWrapping="Wrap"/>
  <WrapPanel Margin="0,8,0,0" ToolTip="Auto uses the plan of a Claude Code login, else whatever the API reports.">
    <TextBlock Text="Plan" Width="56" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>$(Get-PlanSegXaml 'NP' $nf.plan)
  </WrapPanel>
  <TextBlock Name="NfMsg" Margin="0,6,0,0" FontSize="11" Foreground="$($Colors.bad)" TextWrapping="Wrap" Visibility="Collapsed"/>
  <StackPanel Name="NfApprove" Margin="0,8,0,0" Visibility="Collapsed">
    <TextBlock Name="NfApproveText" FontSize="11.5" Foreground="$($Theme.fg)" TextWrapping="Wrap"/>
    <TextBlock Name="NfWarn" Margin="0,4,0,0" FontSize="10.5" Foreground="$($Colors.bad)" TextWrapping="Wrap" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,6,0,0">
      <Button Name="NfNo" Style="{DynamicResource TextBtn}" Content="Cancel"/>
      <Button Name="NfX" Style="{DynamicResource AccentBtn}" Content="Save to xndr-claude" Visibility="Collapsed"/>
      <Button Name="NfYes" Style="{DynamicResource AccentBtn}" Content="Save as environment variable"/>
    </StackPanel>
  </StackPanel>
</StackPanel>
"@)
  $script:nfEls = @{
    hint = $form.FindName('NfHint'); note = $form.FindName('NfNote'); browse = $form.FindName('NfBrowse')
    chips = $form.FindName('NfChips'); input = $form.FindName('NfInput'); token = $form.FindName('NfToken'); label = $form.FindName('NfLabel'); msg = $form.FindName('NfMsg')
    approve = $form.FindName('NfApprove'); approveText = $form.FindName('NfApproveText'); warn = $form.FindName('NfWarn')
  }
  $script:nfEls.label.Add_TextChanged({ param($s) $script:nf.label = $s.Text })
  $script:nfEls.input.Add_TextChanged({ param($s) $script:nf.input = $s.Text })
  $script:nfEls.token.Add_PasswordChanged({ $script:nfEls.approve.Visibility = 'Collapsed'; $script:nfEls.msg.Visibility = 'Collapsed' })
  $form.FindName('NfNo').Add_Click({ $script:nfEls.approve.Visibility = 'Collapsed' })
  $form.FindName('NfYes').Add_Click({ Complete-AddToken 'env' })
  $nfX = $form.FindName('NfX')
  if ($hasXc) { $nfX.Visibility = 'Visible' }
  $nfX.Add_Click({ Complete-AddToken 'xndr-claude' })
  foreach ($src in ($srcs | ForEach-Object { $_[0] })) {
    $rb = $form.FindName('NS_' + ($src -replace '\W', '_'))
    $rb.Tag = $src
    $rb.Add_Checked({ param($s) $script:nf.src = $s.Tag; $script:nfEls.input.Text = ''; $script:nfEls.token.Clear(); Update-NfSource })
  }
  $opts = @('') + $PlanChoices
  for ($k = 0; $k -lt $opts.Count; $k++) {
    $rb = $form.FindName("NP_$k")
    $rb.Tag = $opts[$k]
    $rb.Add_Checked({ param($s) $script:nf.plan = $s.Tag })
  }
  # Names of xndr-claude accounts found by the search that the widget doesn't have yet.
  foreach ($a in @($script:found | Where-Object { $_.source -eq 'xndr-claude' -and -not (Test-AcctKnown $_) })) {
    $b = New-Object Windows.Controls.Button -Property @{ Content = $a.name; Tag = $a.name; Style = $PopupEls.Card.FindResource('TextBtn') }
    $b.Add_Click({ param($s) $script:nfEls.input.Text = $s.Tag; if (-not $script:nfEls.label.Text.Trim()) { $script:nfEls.label.Text = $s.Tag } })
    [void]$script:nfEls.chips.Children.Add($b)
  }
  $script:nfEls.browse.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the folder that holds the Claude Code login (.credentials.json)'
    $dlg.ShowNewFolderButton = $false
    $dlg.SelectedPath = $HOME
    try { if ($dlg.ShowDialog() -eq 'OK') { $script:nfEls.input.Text = $dlg.SelectedPath } }
    finally { $dlg.Dispose(); [void]$settings.Activate() }
  })
  Update-NfSource
  [void]$pan.Children.Add($form)
  [void]$pan.Children.Add((New-ToolBar 'Add' { Invoke-AddAccount }))
}

function Invoke-AddAccount {
  $nf = $script:nf
  $in = $nf.input.Trim(); $label = $nf.label.Trim()
  $msg = $null; $detected = ''
  $o = [ordered]@{ name = $null; label = $null; plan = ''; source = $nf.src }
  switch ($nf.src) {
    'claude-code' {
      $default = [IO.Path]::GetFullPath((Join-Path $HOME '.claude')).TrimEnd('\')
      $dir = ''
      if ($in) { try { $dir = [IO.Path]::GetFullPath($in).TrimEnd('\') } catch { $msg = 'That is not a valid folder path.' } }
      if ($dir -eq $default) { $dir = '' }
      $login = if ($msg) { $null } else { Get-ClaudeCodeLogin $dir }
      if (-not $msg -and -not $login) { $msg = 'No Claude Code login (.credentials.json) in that folder.' }
      if (-not $msg) {
        $detected = "$($login.plan)"; $login = $null
        if (@(Get-AcctCfgs | Where-Object { $_.source -eq 'claude-code' -and "$($_.dir)" -eq $dir }).Count) { $msg = 'That login is already in the widget.' }
      }
      if (-not $msg) {
        $id = Get-ClaudeCodeIdentity $(if ($dir) { $dir } else { $default })
        $base = if ($dir) { 'claude-code-' + ((Split-Path $dir -Leaf) -replace '^\.claude[-_.]?', '') } else { 'claude-code' }
        $o.name = Get-UniqueName $base
        $o.label = if ($label) { $label } elseif ($id.emailAddress) { $id.emailAddress } else { 'Claude Code' }
        if ($dir) { $o.dir = $dir }
      }
    }
    'xndr-claude' {
      if ($in -notmatch '^[A-Za-z0-9._-]+$') { $msg = 'Enter the xndr-claude account name (letters, digits, . _ -).' }
      elseif (@(Get-AcctCfgs | Where-Object { $_.name -eq $in -or $_.account -eq $in }).Count) { $msg = 'That account is already in the widget.' }
      else { $o.name = $in; $o.label = if ($label) { $label } else { $in } }
    }
    default {
      # Token: nothing is written yet. Validate, then ask for approval (Complete-AddToken does the write).
      $e = $script:nfEls
      $var = Get-TokenVarName $label
      $tok = "$($e.token.Password)".Trim()
      if (-not $var) { $msg = 'Give the account a name (letters or digits); it names the environment variable.' }
      elseif (-not $tok) { $msg = 'Paste the token first.' }
      elseif ($tok -match '\s') { $msg = 'A token has no spaces or line breaks. Paste just the token.' }
      elseif (@(Get-AcctCfgs | Where-Object { "$($_.env)" -eq $var }).Count) { $msg = "An account already uses $var. Pick another name." }
      else {
        $exists = [bool](Get-UserEnvToken $var)
        $e.approveText.Text = if (Test-Command 'xndr-claude') { "Where should this token be saved? In xndr-claude, or as the Windows user environment variable ${var}. It stays on this PC.$(if ($exists) { ' The variable already has a value; saving there replaces it.' })" }
          else { "Save this token as the Windows user environment variable ${var}? It stays on this PC.$(if ($exists) { ' This replaces the value already stored there.' })" }
        $e.warn.Text = 'This does not look like a setup token (it should start with sk-ant-oat). You can still save it.'
        $e.warn.Visibility = if (Test-TokenFormat $tok) { 'Collapsed' } else { 'Visible' }
        $e.approve.Visibility = 'Visible'
        $e.msg.Visibility = 'Collapsed'
      }
      $tok = $null
      if (-not $msg) { return }
    }
  }
  if ($msg) {
    $script:nfEls.msg.Text = $msg
    $script:nfEls.msg.Visibility = 'Visible'
    return
  }
  $o.plan = if ($nf.plan) { $nf.plan } else { $detected }
  Add-AcctCfg $o
  $script:nf = @{ label = ''; src = $nf.src; input = ''; plan = '' }
  $script:acctNote = "Added $($o.label). Save to keep it."
  $script:acctMode = $null
  Update-Widget
  Update-Popup
}

# The user approved the line shown by Invoke-AddAccount: store the token, add the account that points at it.
function Complete-AddToken([string]$target = 'env') {
  $e = $script:nfEls; $label = $script:nf.label.Trim()
  $var = Get-TokenVarName $label
  $name = Get-UniqueName $label
  $tok = "$($e.token.Password)".Trim()
  $e.approve.Visibility = 'Collapsed'
  try {
    if (-not $var -or -not $tok) { throw 'name or token missing' }
    if ($Demo) { $stored = $true }
    elseif ($target -eq 'xndr-claude') { Save-XndrClaudeToken $name $tok; $stored = $true }
    else { $stored = Set-UserEnvToken $var $tok }
    if (-not $stored) { throw 'read-back mismatch' }
  } catch {
    # Only the error type: a message could carry the value.
    Write-Log "saving token failed ($target, $($_.Exception.GetType().Name))"
    $e.msg.Text = if ($target -eq 'xndr-claude') { 'Could not save the token to xndr-claude.' } else { 'Could not save the token to your user environment.' }
    $e.msg.Visibility = 'Visible'
    return
  } finally { $tok = $null; $e.token.Clear() }
  $o = if ($target -eq 'xndr-claude') { [ordered]@{ name = $name; label = $label; plan = $script:nf.plan; source = 'xndr-claude' } }
       else { [ordered]@{ name = $name; label = $label; plan = $script:nf.plan; source = 'env'; env = $var; envManaged = $true } }
  Add-AcctCfg $o
  # The token is already stored, so its account must survive Cancel/Esc: put it in the Cancel copy and on disk now.
  if (-not $Demo) {
    try {
      $bk = $script:configBackup | ConvertFrom-Json
      $bk.accounts = @($bk.accounts | Where-Object { $_ }) + @([pscustomobject]$o)
      $script:configBackup = $bk | ConvertTo-Json -Depth 8
      Save-Config $bk
    } catch { Write-Log "save config: $($_.Exception.GetType().Name)" }
  }
  $script:nf = @{ label = ''; src = 'token'; input = ''; plan = '' }
  $script:acctNote = if ($target -eq 'xndr-claude') { "Saved to xndr-claude as $name." }
                     else { "Saved as user environment variable $var (Windows Settings $([char]0x2192) Environment Variables $([char]0x2192) User variables)" }
  $script:acctMode = $null
  Update-Widget
  Update-Popup
}

$PopupEls.FindBtn.Add_Click({
  $script:acctMode = 'find'; $script:acctNote = $null; $script:found = $null
  Start-Find
  Show-AcctTool
})
$PopupEls.AddBtn.Add_Click({
  $script:acctMode = 'add'; $script:acctNote = $null
  if ($null -eq $script:found) { Start-Find }
  Show-AcctTool
})

# The popup spans the work area's full height with the card pinned to the taskbar edge, so
# switching between the list and settings never resizes (and never flickers) the window.
function Set-PopupPosition {
  $wa = [Windows.SystemParameters]::WorkArea
  $atTop = $wa.Top -gt 0
  $popup.Height = $wa.Height
  $popup.Top = $wa.Top
  $PopupEls.Card.VerticalAlignment = if ($atTop) { 'Top' } else { 'Bottom' }
  $x = $widget.Left + $widget.ActualWidth / 2 - $popup.Width / 2
  $popup.Left = [Math]::Max($wa.Left, [Math]::Min($wa.Right - $popup.Width, $x))
}

function New-Ease([double]$from, [double]$to, [int]$ms) {
  $a = New-Object Windows.Media.Animation.DoubleAnimation($from, $to, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds($ms))))
  $a.EasingFunction = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }
  return $a
}

# Fade in and slide from the taskbar edge; with animations off, just appear.
function Start-PopupEntrance {
  if (Test-Option 'animations') {
    $dy = if ([Windows.SystemParameters]::WorkArea.Top -gt 0) { -10 } else { 10 }
    $popup.BeginAnimation([Windows.Window]::OpacityProperty, (New-Ease 0 1 170))
    $PopupEls.Slide.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Ease $dy 0 220))
  } else {
    $popup.BeginAnimation([Windows.Window]::OpacityProperty, $null)
    $PopupEls.Slide.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    $popup.Opacity = 1
  }
}

# The taskbar rises above the widget whenever the popup opens or closes; put the widget back on top at once
# (and a few times over the next half second) instead of waiting for the 750 ms timer, which showed as a flash.
$script:raiseLeft = 0
$raiseTimer = New-Object Windows.Threading.DispatcherTimer
$raiseTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$raiseTimer.Add_Tick({
  if ($script:hwnd -ne [IntPtr]::Zero) { [CuwNative]::KeepOnTop($script:hwnd) }
  $script:raiseLeft--
  if ($script:raiseLeft -le 0) { $raiseTimer.Stop() }
})
function Start-Raise {
  if ($script:hwnd -ne [IntPtr]::Zero) { [CuwNative]::KeepOnTop($script:hwnd) }
  $script:raiseLeft = 5
  $raiseTimer.Start()
}

# Settings work on the live config (so the taskbar previews them) with a copy to go back to.
function Start-Editing {
  $script:configBackup = $script:config | ConvertTo-Json -Depth 8
  $script:editing = $true
  $script:acctMode = $null; $script:acctNote = $null; $script:acctsChanged = $false
  $script:tab = 'acct'; $script:expanded = $null
  $script:envDrop = @()
}

function Stop-Editing([bool]$keep) {
  if (-not $script:editing) { return }
  $script:editing = $false
  $script:acctMode = $null; $script:acctNote = $null
  if (-not $Demo) { Complete-EnvChanges $keep }
  if ($keep) { Save-UiConfig }
  elseif ($script:configBackup) { $script:config = $script:configBackup | ConvertFrom-Json }
  $script:configBackup = $null
  Update-NewAccts
  Update-Widget
  # New accounts have no numbers yet: read them now rather than at the next timer.
  if ($keep -and $script:acctsChanged -and -not $Demo) { $script:lastTry = [DateTime]::MinValue; Start-Refresh }
  $script:acctsChanged = $false
}

# Apply: keep what has been edited so far and stay in Settings.
function Save-Editing {
  if (-not $script:editing) { return }
  if (-not $Demo) { Complete-EnvChanges $true }
  $script:editing = $false
  Save-UiConfig
  $script:editing = $true
  $script:configBackup = $script:config | ConvertTo-Json -Depth 8
  if ($script:acctsChanged -and -not $Demo) { $script:lastTry = [DateTime]::MinValue; Start-Refresh }
  $script:acctsChanged = $false
  Update-SettingsButtons
}

function Show-Settings {
  if ($settings.IsVisible) {
    if ($settings.WindowState -eq 'Minimized') { $settings.WindowState = 'Normal' }
    [void]$settings.Activate()
    return
  }
  Start-Editing
  Update-Settings
  $settings.Show()
  [void]$settings.Activate()
}

# OK keeps the edits, Cancel (and Esc, and the close button) undoes them; either way the window is only hidden, so it opens again at the size the user left it.
function Close-Settings([bool]$keep) {
  Stop-Editing $keep
  $settings.Hide()
}

# Content and position are settled while the window is still fully transparent, so the first
# frame on screen is the finished one.
function Show-Popup {
  Write-Trace 'show'
  $script:pendingHide = $false
  $hideTimer.Stop()
  $popup.BeginAnimation([Windows.Window]::OpacityProperty, $null)
  $popup.Opacity = 0
  Update-Popup -ListOnly
  Set-PopupPosition
  $popup.Show()
  [void]$popup.Activate()
  Start-PopupEntrance
  Start-Raise
}

# Windows re-shows a transparent window's last drawn frame when it reappears, so before hiding
# the popup goes to zero opacity and only hides once that frame is drawn. Nothing is rebuilt on the way out.
$script:pendingHide = $false
$hideTimer = New-Object Windows.Threading.DispatcherTimer
$hideTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$hideTimer.Add_Tick({
  $hideTimer.Stop()
  Write-Trace "hide timer: pending=$($script:pendingHide)"
  if ($script:pendingHide) { $script:pendingHide = $false; $popup.Hide() }
})

function Hide-Popup {
  Write-Trace "hide requested: visible=$($popup.IsVisible) pending=$($script:pendingHide)"
  if (-not $popup.IsVisible -or $script:pendingHide) { return }
  $popup.BeginAnimation([Windows.Window]::OpacityProperty, $null)
  $popup.Opacity = 0
  $script:pendingHide = $true
  $hideTimer.Start()
  Start-Raise
}

$script:popupClosedAt = [DateTime]::MinValue
$popup.Add_Deactivated({ Write-Trace 'popup deactivated'; Hide-Popup; $script:popupClosedAt = Get-Date })
$popup.Add_Activated({ Write-Trace 'popup activated' })
$popup.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape') { Hide-Popup }
})
$PopupEls.RefreshBtn.Add_Click({ Start-Refresh })
# The update always runs where its status can be seen: the Settings window, Updates tab.
$PopupEls.UpdBtn.Add_Click({
  Hide-Popup
  Show-Settings
  $script:tab = 'upd'; Update-Settings
  Invoke-UpdateNow
})
$PopupEls.UpdInstallBtn.Add_Click({ Invoke-UpdateNow })
$PopupEls.UpdCheckBtn.Add_Click({ Start-UpdateCheck -Manual })
$PopupEls.EditBtn.Add_Click({ Hide-Popup; Show-Settings })
$PopupEls.SOkBtn.Add_Click({ Close-Settings $true })
$PopupEls.SCancelBtn.Add_Click({ Close-Settings $false })
$PopupEls.SApplyBtn.Add_Click({ Save-Editing })
$settings.Add_Closing({ param($s, $e) if ($script:exiting) { return }; $e.Cancel = $true; Close-Settings $false })
$settings.Add_SourceInitialized({ if (-not $isLight) { [CuwNative]::DarkTitleBar((New-Object Windows.Interop.WindowInteropHelper($settings)).Handle) } })
$widget.Add_Closing({ $script:exiting = $true })
$settings.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Close-Settings $false } })
$script:exiting = $false
foreach ($t in 'acct', 'disp', 'cap', 'upd') {
  $PopupEls["Tab_$t"].Tag = $t
  $PopupEls["Tab_$t"].Add_Checked({ param($s) if ($script:tab -ne $s.Tag) { $script:tab = $s.Tag; Update-Settings } })
}

# Settings, once opened, is only ever hidden. The list is rebuilt freely; Settings only when asked
# (a refresh finishing must not rebuild it under someone typing).
function Update-All {
  Update-Widget
  if ($popup.IsVisible) { Update-Popup -ListOnly }
  if ($script:forcePopup -and $script:editing -and $settings.IsVisible -and -not ([Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Primitives.TextBoxBase])) { Update-Settings }
  $script:forcePopup = $false
}

# ---------------------------------------------------------------- widget interaction

$script:dragged = $false
$WidgetEls.Root.Add_MouseEnter({ $WidgetEls.Root.Background = $Theme.widgetHover })
$WidgetEls.Root.Add_MouseLeave({ $WidgetEls.Root.Background = '#01000000' })
$widget.Add_MouseLeftButtonDown({
  $script:dragged = $false
  if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
    $before = $widget.Left
    $widget.DragMove()
    $script:dragged = $true
    if ($widget.Left -ne $before) {
      $script:state.right = [Math]::Round([Windows.SystemParameters]::PrimaryScreenWidth - $widget.Left - $widget.ActualWidth)
      Save-State
    }
    Set-WidgetPosition
  }
})
$widget.Add_MouseLeftButtonUp({
  Write-Trace "click: dragged=$($script:dragged) visible=$($popup.IsVisible) pending=$($script:pendingHide) sinceClose=$([int64]((Get-Date) - $script:popupClosedAt).TotalMilliseconds)ms"
  if ($script:dragged) { return }
  if ($popup.IsVisible -and -not $script:pendingHide) { Hide-Popup; return }
  # Clicking the widget first deactivates (and hides) an open list; don't reopen it straight away.
  if (((Get-Date) - $script:popupClosedAt).TotalMilliseconds -lt 300) { return }
  Show-Popup
})

function New-MenuItem($header, $action) {
  $mi = New-Object Windows.Controls.MenuItem
  $mi.Header = $header
  $mi.Add_Click($action)
  return $mi
}
$menu = New-Object Windows.Controls.ContextMenu
$refreshItem = New-MenuItem 'Refresh now' { Start-Refresh }
$scanItem = New-MenuItem 'Scan for accounts' { Start-Refresh -Discover; Show-Popup }
[void]$menu.Items.Add($refreshItem)
[void]$menu.Items.Add((New-MenuItem "Settings$ELL" { Show-Settings }))
[void]$menu.Items.Add($scanItem)
[void]$menu.Items.Add((New-MenuItem "Open config file$ELL" {
  if (-not (Test-Path $ConfigPath)) { Save-UiConfig }
  Start-Process notepad.exe -ArgumentList "`"$ConfigPath`""
}))
[void]$menu.Items.Add((New-MenuItem 'Reset position' { $script:state.right = $null; Save-State; Set-WidgetPosition }))
$startupItem = New-MenuItem 'Start with Windows' {
  if (Test-Path $StartupLink) { Remove-Item $StartupLink } else { New-LauncherShortcut $StartupLink $PSScriptRoot }
}
$startupItem.IsCheckable = $true
[void]$menu.Items.Add($startupItem)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
$Uninstaller = Join-Path $PSScriptRoot 'uninstall.ps1'
if (-not $Demo -and (Test-Path $Uninstaller)) {
  [void]$menu.Items.Add((New-MenuItem "Uninstall$ELL" {
    $answer = [Windows.MessageBox]::Show($widget,
      "Remove Claude Usage Widget from this PC?`n`nIts settings are removed too. Your Claude logins aren't touched.",
      'Uninstall Claude Usage Widget', 'YesNo', 'Question')
    if ("$answer" -ne 'Yes') { return }
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Uninstaller`""
  }))
}
[void]$menu.Items.Add((New-MenuItem 'Exit' { $popup.Close(); $widget.Close() }))
$menu.Add_Opened({
  $startupItem.IsChecked = Test-Path $StartupLink
  $ok = -not $script:job -and (Get-Cooldown) -eq 0
  $refreshItem.IsEnabled = $ok; $scanItem.IsEnabled = $ok
  $refreshItem.Header = if ($ok -or $script:job) { 'Refresh now' } else { "Refresh now (in $(Get-Cooldown)s)" }
})
$widget.ContextMenu = $menu

# ---------------------------------------------------------------- snapshot (README images)

function Save-Snapshot([string]$file, [scriptblock]$after) {
  $script:editing = $false
  Update-Widget
  Update-Popup -ListOnly
  if ($after) { & $after }
  foreach ($el in $WidgetEls.Root, $PopupEls.Card) {
    if ($el.Parent -is [Windows.Window]) { $el.Parent.Content = $null }
    elseif ($el.Parent) { $el.Parent.Content = $null }
  }
  $PopupEls.Card.Width = 380
  $scene = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns Width="820" CornerRadius="14" ClipToBounds="True" TextOptions.TextRenderingMode="Grayscale"
        TextElement.FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#2E3257" Offset="0"/><GradientStop Color="#5A3A5E" Offset="0.55"/><GradientStop Color="#B8664E" Offset="1"/>
    </LinearGradientBrush>
  </Border.Background>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Height="48" Background="#F21C1C1C">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Right" Margin="0,0,16,0" VerticalAlignment="Center">
          <TextBlock Text="11:46" Foreground="White" FontSize="11.5" HorizontalAlignment="Right"/>
          <TextBlock Text="2026-09-29" Foreground="White" FontSize="11.5" HorizontalAlignment="Right"/>
        </StackPanel>
        <ContentControl Name="Slot" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,60,0"/>
      </DockPanel>
    </Border>
    <ContentControl Name="CardSlot" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,40,150,0"/>
  </DockPanel>
</Border>
"@)
  $scene.FindName('Slot').Content = $WidgetEls.Root
  $scene.FindName('CardSlot').Content = $PopupEls.Card
  $scene.Measure((New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
  $scene.Arrange((New-Object Windows.Rect($scene.DesiredSize)))
  $scene.UpdateLayout()
  $scale = 2
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($scene.ActualWidth * $scale), [int]($scene.ActualHeight * $scale), (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32))
  $rtb.Render($scene)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [IO.File]::Create($file)
  try { $enc.Save($fs) } finally { $fs.Close() }
  $scene.FindName('Slot').Content = $null
  $scene.FindName('CardSlot').Content = $null
}

# The Settings window's content at its default size, rendered at $scale display scaling (no window frame).
function Save-SettingsSnapshot([string]$file, [double]$scale, [scriptblock]$after) {
  $script:editing = $true
  if (-not $script:configBackup) { $script:configBackup = $script:config | ConvertTo-Json -Depth 8 }
  Update-Widget
  Update-Settings
  if ($after) { & $after }
  $dpi = New-Object Windows.DpiScale($scale, $scale)
  $grid = $settings.Content
  $settings.Content = $null
  $shot = New-Object Windows.Controls.Border -Property @{ Width = $settings.Width; Height = $settings.Height; Background = $Theme.card; Child = $grid }
  $shot.Resources.MergedDictionaries.Add($PopupEls.Card.Resources)
  $shot.SetValue([Windows.Documents.TextElement]::ForegroundProperty, (New-Object Windows.Media.BrushConverter).ConvertFromString($Theme.fg))
  $shot.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, (New-Object Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')))
  $shot.UseLayoutRounding = $true
  [Windows.Media.VisualTreeHelper]::SetRootDpi($shot, $dpi)
  $shot.Measure((New-Object Windows.Size($settings.Width, $settings.Height)))
  $shot.Arrange((New-Object Windows.Rect(0, 0, $settings.Width, $settings.Height)))
  $shot.UpdateLayout()
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][Math]::Ceiling($settings.Width * $scale), [int][Math]::Ceiling($settings.Height * $scale), (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32))
  $rtb.Render($shot)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [IO.File]::Create($file)
  try { $enc.Save($fs) } finally { $fs.Close() }
  $shot.Child = $null
  $settings.Content = $grid
}

# The taskbar strip alone, laid out and rendered as at $scale display scaling, with an optional tooltip above it.
function Save-BarSnapshot([string]$file, [double]$scale, [string]$tip) {
  $dpi = New-Object Windows.DpiScale($scale, $scale)
  [Windows.Media.VisualTreeHelper]::SetRootDpi($widget, $dpi)
  Update-Widget
  if ($WidgetEls.Root.Parent) { $WidgetEls.Root.Parent.Content = $null }
  $scene = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Background="#2E3257" TextElement.FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <ContentControl Name="TipSlot" HorizontalAlignment="Left" Margin="40,12,12,8"/>
  <Border Height="48" Background="#F21C1C1C" Padding="24,0,24,0">
    <DockPanel LastChildFill="False">
      <StackPanel DockPanel.Dock="Right" Margin="40,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="11:46" Foreground="White" FontSize="11.5" HorizontalAlignment="Right"/>
        <TextBlock Text="2026-10-13" Foreground="White" FontSize="11.5" HorizontalAlignment="Right"/>
      </StackPanel>
      <ContentControl Name="Slot" DockPanel.Dock="Right" VerticalAlignment="Center"/>
    </DockPanel>
  </Border>
</StackPanel>
"@)
  [Windows.Media.VisualTreeHelper]::SetRootDpi($scene, $dpi)
  $scene.FindName('Slot').Content = $WidgetEls.Root
  # A ToolTip can't be parented, so its text is drawn in a box like the system one.
  if ($tip) {
    $scene.FindName('TipSlot').Content = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns Background="#FFFFFF" BorderBrush="#767676" BorderThickness="1" Padding="6,3"><TextBlock Text="$((Esc $tip) -replace "`n", '&#10;')" FontFamily="Segoe UI" FontSize="12" Foreground="#000000"/></Border>
"@)
  }
  $scene.Measure((New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
  $scene.Arrange((New-Object Windows.Rect($scene.DesiredSize)))
  $scene.UpdateLayout()
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][Math]::Ceiling($scene.ActualWidth * $scale), [int][Math]::Ceiling($scene.ActualHeight * $scale), (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32))
  $rtb.Render($scene)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [IO.File]::Create($file)
  try { $enc.Save($fs) } finally { $fs.Close() }
  $scene.FindName('Slot').Content = $null
  $scene.FindName('TipSlot').Content = $null
}

# Renders $el (8 px per DIP) and measures how many degrees of the circle of radius $r (DIP) around ($c, $c) are
# painted by an opaque stroke, and how many of those fall inside the expected sweep from 12 o'clock.
function Measure-RingSweep($el, [double]$r, [double]$c, [double]$expected) {
  $k = 8
  $host2 = New-Object Windows.Controls.Border -Property @{ Child = $el }
  $host2.Measure((New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
  $host2.Arrange((New-Object Windows.Rect($host2.DesiredSize)))
  $host2.UpdateLayout()
  $w = [int][Math]::Ceiling($host2.ActualWidth * $k); $h = [int][Math]::Ceiling($host2.ActualHeight * $k)
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $k), (96 * $k), ([Windows.Media.PixelFormats]::Pbgra32))
  $rtb.Render($host2)
  $buf = New-Object byte[] ($w * $h * 4)
  $rtb.CopyPixels($buf, $w * 4, 0)
  $host2.Child = $null
  $step = 0.25; $total = 0; $inside = 0
  for ($a = 0.0; $a -lt 360; $a += $step) {
    $rad = $a * [Math]::PI / 180
    $x = [int][Math]::Floor(($c + $r * [Math]::Sin($rad)) * $k); $y = [int][Math]::Floor(($c - $r * [Math]::Cos($rad)) * $k)
    if ($buf[($y * $w + $x) * 4 + 3] -ge 128) { $total++; if ($a -lt $expected) { $inside++ } }
  }
  [pscustomobject]@{ total = $total * $step; inside = $inside * $step }
}

if ($RingCheck) {
  Set-DemoData
  $failed = 0
  foreach ($preset in 'compact', 'normal', 'large') {
  $script:config | Add-Member -Force size $preset
  Set-SizePreset
  foreach ($dpiScale in 1, 1.25, 1.5) {
    [Windows.Media.VisualTreeHelper]::SetRootDpi($widget, (New-Object Windows.DpiScale($dpiScale, $dpiScale)))
    foreach ($pct in 0, 25, 50, 91, 100) {
      $sz = Get-RingSize; $in = Get-RingSize $RingInnerDip
      $expected = $pct * 3.6
      $both = [pscustomobject]@{ five_h = [pscustomobject]@{ pct = $pct; reset = $null }; seven_d = [pscustomobject]@{ pct = $pct; reset = $null } }
      $innerOnly = [pscustomobject]@{ five_h = [pscustomobject]@{ pct = $pct; reset = $null }; seven_d = [pscustomobject]@{ pct = 0; reset = $null } }
      $script:config | Add-Member -Force inside 'percent'
      $m = Measure-RingSweep (New-RingElement $pct 'x' $false '' $null) (($sz - $RingThick) / 2) ($sz / 2) $expected
      $script:config | Add-Member -Force inside 'initials'
      $m2 = Measure-RingSweep (New-CombinedElement ([pscustomobject]@{ pie = '5h' }) $both 'Ab') (($sz - $RingThick) / 2) ($sz / 2) $expected
      $m3 = Measure-RingSweep (New-CombinedElement ([pscustomobject]@{ pie = '5h' }) $innerOnly 'Ab') (($in - $RingInnerThick) / 2) ($sz / 2) $expected
      foreach ($row in @(@('ring', $m), @('combined outer', $m2), @('combined inner', $m3))) {
        $ok = [Math]::Abs($row[1].total - $expected) -le 1.0 -and [Math]::Abs($row[1].inside - $expected) -le 1.0
        if (-not $ok) { $failed++ }
        '{0,-8} {1,-15} dpi {2,-4} {3,3}%  expected {4,6:0.0} deg  painted {5,6:0.0}  in place {6,6:0.0}  {7}' -f $preset, $row[0], $dpiScale, $pct, $expected, $row[1].total, $row[1].inside, $(if ($ok) { 'PASS' } else { 'FAIL' })
      }
    }
  }
  }
  if ($failed) { "$failed ring check(s) FAILED"; exit 1 }
  'all ring checks passed'
  exit 0
}

if ($Snapshot) {
  New-Item -ItemType Directory -Force $Snapshot | Out-Null
  Set-DemoData
  Set-DemoUpdate
  Save-Snapshot (Join-Path $Snapshot 'widget.png')
  Save-SettingsSnapshot (Join-Path $Snapshot 'settings.png') 1
  # Settings tabs with five accounts and a new-account notice, at 100% and 150% display scaling (used to check the layout).
  $script:config.accounts = @($script:config.accounts) + @(
    [pscustomobject]@{ name = 'cs'; label = 'CasinoStreamers'; plan = ''; source = 'xndr-claude' }
    [pscustomobject]@{ name = 'node'; label = 'Node'; plan = ''; source = 'xndr-claude' }
  )
  Set-DemoFound
  $script:found = @($script:found | Select-Object -First 1)
  Update-NewAccts
  foreach ($scale in 1, 1.5) {
    foreach ($t in 'acct', 'disp', 'cap', 'upd') {
      $script:tab = $t
      Save-SettingsSnapshot (Join-Path $Snapshot "settings-tab-$t-$([int]($scale * 100)).png") $scale
    }
  }
  $script:tab = 'acct'; $script:newAccts = @()
  # Account tools open (used to check the layout; not part of the README).
  Set-DemoFound
  $script:acctMode = 'find'
  Save-SettingsSnapshot (Join-Path $Snapshot 'settings-find.png') 1
  $script:acctMode = 'add'
  Save-SettingsSnapshot (Join-Path $Snapshot 'settings-add.png') 1
  # Token mode with the approval line open (fake value).
  $script:nf = @{ label = 'Side project'; src = 'token'; input = ''; plan = '' }
  Save-SettingsSnapshot (Join-Path $Snapshot 'settings-add-token.png') 1 {
    $script:nfEls.token.Password = 'sk-ant-oat01-FAKEFAKEFAKE'
    $script:nfEls.label.Text = 'Side project'
    Invoke-AddAccount
  }
  # Five accounts on the taskbar at 100/125/150% display scale, with and without percentages, plus one
  # account's hover tooltip (layout checks; not part of the README). 'Sandbox' and 'Side project' share an S.
  $now = [DateTime]::UtcNow
  $mkWin = { param($p, $mins) [pscustomobject]@{ pct = $p; reset = $now.AddMinutes($mins).ToString('o') } }
  $script:accounts = @($script:accounts) + @(
    [pscustomobject]@{ name = 'cs'; status = 'ok'; method = 'probe'; five_h = (& $mkWin 91 95); seven_d = (& $mkWin 58 3000); fable = (& $mkWin 20 3000) }
    [pscustomobject]@{ name = 'node'; status = 'ok'; method = 'probe'; five_h = (& $mkWin 3 250); seven_d = (& $mkWin 77 5000); fable = (& $mkWin 5 5000) }
  )
  (Get-AcctCfg 'cs').label = 'Sandbox'
  foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'taskbar' $true; Set-AcctProp $c.name 'style' 'combined' }
  $script:config | Add-Member -Force names 'hidden'
  $script:config | Add-Member -Force inside 'initials'; $script:config | Add-Member -Force next 'none'
  Save-Snapshot (Join-Path $Snapshot 'widget-nopct.png')
  foreach ($scale in 1, 1.25, 1.5) {
    foreach ($pcts in $true, $false) {
      $script:config | Add-Member -Force inside $(if ($pcts) { 'percent' } else { 'initials' }); $script:config | Add-Member -Force next $(if ($pcts) { 'caption' } else { 'none' })
      $tip = if (-not $pcts -and $scale -eq 1.25) { Get-AccountTip (Get-AcctCfg 'work') (Get-Result 'work') }
      Save-BarSnapshot (Join-Path $Snapshot "bar-$(if ($pcts) { 'pct' } else { 'nopct' })-$([int]($scale * 100)).png") $scale $tip
    }
  }
  foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'style' 'rings' }
  Save-BarSnapshot (Join-Path $Snapshot 'bar-rings-nopct-125.png') 1.25 $null
  # Known values: 91 / 50 / 25 and 100 / 0 (compare with the arcs; -RingCheck measures them).
  foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'taskbar' ($c.name -in 'personal', 'work') }
  Set-AcctProp 'personal' 'limits' @('5h', '7d', 'fable')
  Set-AcctProp 'work' 'limits' @('5h', '7d')
  $known = @{ personal = @(91, 50, 25); work = @(100, 0, $null) }
  foreach ($n in $known.Keys) {
    $r = Get-Result $n
    $r.five_h = & $mkWin $known[$n][0] 95; $r.seven_d = & $mkWin $known[$n][1] 3000
    $r.fable = if ($null -ne $known[$n][2]) { & $mkWin $known[$n][2] 3000 } else { & $mkWin $null 3000 }
  }
  $script:config | Add-Member -Force names 'left'
  $script:config | Add-Member -Force inside 'percent'; $script:config | Add-Member -Force next 'caption'
  foreach ($scale in 1, 1.25, 1.5) { Save-BarSnapshot (Join-Path $Snapshot "bar-known-$([int]($scale * 100)).png") $scale $null }
  # Every inside / next combination, and the three size presets (with names and dividers on, then off).
  foreach ($in in 'none', 'initials', 'percent') {
    foreach ($nx in 'none', 'caption', 'percent') {
      $script:config | Add-Member -Force inside $in; $script:config | Add-Member -Force next $nx
      Save-BarSnapshot (Join-Path $Snapshot "combo-in-$in-next-$nx.png") 1 $null
    }
  }
  $script:config | Add-Member -Force inside 'percent'; $script:config | Add-Member -Force next 'percent'
  foreach ($size in 'compact', 'normal', 'large') {
    $script:config | Add-Member -Force size $size
    foreach ($scale in 1, 1.5) {
      Save-BarSnapshot (Join-Path $Snapshot "size-$size-$([int]($scale * 100)).png") $scale $null
    }
  }
  $script:config | Add-Member -Force size 'large'; $script:config | Add-Member -Force showDividers $true
  Save-BarSnapshot (Join-Path $Snapshot 'size-large-dividers-100.png') 1 $null
  foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'style' 'combined' }
  Save-BarSnapshot (Join-Path $Snapshot 'size-large-combined-100.png') 1 $null
  $script:config | Add-Member -Force size 'normal'
  Save-BarSnapshot (Join-Path $Snapshot 'size-normal-combined-100.png') 1 $null
  $script:config | Add-Member -Force inside 'initials'; $script:config | Add-Member -Force next 'caption'
  Save-BarSnapshot (Join-Path $Snapshot 'size-normal-combined-initials-100.png') 1 $null

  # 1.9.2: combined dials with the reset time, the spacing / name / inner-ring / next-to-ring options, hover text.
  $script:config | Add-Member -Force showDividers $false
  $script:config | Add-Member -Force inside 'initials'; $script:config | Add-Member -Force next 'percent'
  foreach ($size in 'normal', 'large') {
    $script:config | Add-Member -Force size $size
    Save-BarSnapshot (Join-Path $Snapshot "dials-reset-$size.png") 1 $null
  }
  $script:config | Add-Member -Force size 'compact'
  Save-BarSnapshot (Join-Path $Snapshot 'dials-reset-compact-hover.png') 1 (Get-AccountTipFor 'personal')
  foreach ($nx in 'resetin', 'resetat') {
    $script:config | Add-Member -Force next $nx
    $script:config | Add-Member -Force size 'normal'
    Save-BarSnapshot (Join-Path $Snapshot "next-$nx-combined.png") 1 $null
    foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'style' 'rings' }
    Save-BarSnapshot (Join-Path $Snapshot "next-$nx-rings.png") 1 $null
    foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'style' 'combined' }
  }
  $script:config | Add-Member -Force next 'caption'
  foreach ($sp in 'tight', 'normal', 'wide') {
    $script:config | Add-Member -Force spacing $sp; $script:config | Add-Member -Force size 'compact'
    Save-BarSnapshot (Join-Path $Snapshot "spacing-$sp-compact.png") 1 $null
  }
  $script:config | Add-Member -Force spacing 'normal'; $script:config | Add-Member -Force size 'normal'
  foreach ($nm in 'left', 'right', 'hidden') {
    $script:config | Add-Member -Force names $nm
    Save-BarSnapshot (Join-Path $Snapshot "names-$nm.png") 1 $null
  }
  $script:config | Add-Member -Force names 'left'
  $script:config | Add-Member -Force innerWindow '7d'
  foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'pie' '' }
  Save-BarSnapshot (Join-Path $Snapshot 'inner-7d.png') 1 $null
  $script:config | Add-Member -Force innerWindow '5h'
  # Ring hover text, as the system tooltip would show it.
  $pk = Get-AcctCfg 'personal'
  Save-BarSnapshot (Join-Path $Snapshot 'ring-hover.png') 1 ((Get-RingTip $pk '5h' (Get-Win (Get-Result 'personal') '5h') 'inner ring') + "`n`n" + (Get-RingTip $pk '7d' (Get-Win (Get-Result 'personal') '7d') 'outer ring'))

  # Settings: Display and Accounts (chip strip) once more with the new controls, then every Updates tab state.
  $script:tab = 'disp'; Save-SettingsSnapshot (Join-Path $Snapshot 'settings-display-new.png') 1
  $script:acctMode = $null; $script:tab = 'acct'; $script:expanded = 'work'; Save-SettingsSnapshot (Join-Path $Snapshot 'settings-accounts-new.png') 1
  $script:tab = 'upd'
  $script:update = $null
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-1-idle.png') 1 { $script:updMsg = $null; Set-UpdStatus $null $null }
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-2-checking.png') 1 { Set-UpdStatus "Checking$ELL" $null }
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-3-uptodate.png') 1 { Set-UpdStatus "Up to date (v$AppVersion)" $null }
  Set-DemoUpdate
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-4-available.png') 1 { Set-UpdStatus 'v1.9.3 is available' $null }
  $script:updatingSince = Get-Date
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-5-downloading.png') 1 { Set-UpdStatus "Downloading v1.9.3$ELL 62%" 62 }
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-6-installing.png') 1 { Set-UpdStatus "Installing v1.9.3. The widget closes and restarts in a few seconds$ELL" 100 }
  $script:updatingSince = $null
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-7-error.png') 1 { Set-UpdStatus 'Download failed: the remote name could not be resolved' $null }
  $script:update = $null
  Save-SettingsSnapshot (Join-Path $Snapshot 'update-8-updated.png') 1 { Set-UpdStatus "Updated to v$AppVersion" $null }

  # 1.9.3: an account with no 5h window (Ultra) next to two with one: no 5h ring, row, caption or tooltip line.
  $script:update = $null
  Set-DemoData
  foreach ($c in Get-AcctCfgs) { Set-AcctProp $c.name 'taskbar' ($c.name -in 'personal', 'work', 'ultra') }
  Set-AcctProp 'ultra' 'limits' @('5h', '7d', 'fable')
  $script:config | Add-Member -Force names 'left'
  $script:config | Add-Member -Force inside 'percent'; $script:config | Add-Member -Force next 'caption'
  Set-AcctProp 'ultra' 'style' 'combined'
  Save-BarSnapshot (Join-Path $Snapshot 'ultra-bar-combined.png') 1 (Get-AccountTipFor 'ultra')
  Set-AcctProp 'ultra' 'style' 'rings'
  Save-BarSnapshot (Join-Path $Snapshot 'ultra-bar-rings.png') 1 (Get-AccountTipFor 'ultra')
  Save-Snapshot (Join-Path $Snapshot 'ultra-popup.png')
  exit
}

# ---------------------------------------------------------------- timers & run

$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$pollTimer.Add_Tick({ if ($script:job) { Complete-Refresh } else { $pollTimer.Stop() } })

$findTimer = New-Object Windows.Threading.DispatcherTimer
$findTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$findTimer.Add_Tick({ if ($script:findJob) { Complete-Find } else { $findTimer.Stop() } })

$dlTimer = New-Object Windows.Threading.DispatcherTimer
$dlTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$dlTimer.Add_Tick({ if ($script:dlJob) { Step-Download } else { $dlTimer.Stop() } })

$updTimer = New-Object Windows.Threading.DispatcherTimer
$updTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$updTimer.Add_Tick({ if ($script:updJob) { Complete-UpdateCheck } else { $updTimer.Stop() } })

$script:hwnd = [IntPtr]::Zero
$topTimer = New-Object Windows.Threading.DispatcherTimer
$topTimer.Interval = [TimeSpan]::FromMilliseconds(750)
$topTimer.Add_Tick({
  if ([CuwNative]::ForegroundIsFullscreen()) {
    if ($widget.Visibility -eq 'Visible') { $widget.Visibility = 'Hidden' }
  } else {
    if ($widget.Visibility -ne 'Visible') { $widget.Visibility = 'Visible' }
    [CuwNative]::KeepOnTop($script:hwnd)
  }
  if ($popup.IsVisible) { Update-RefreshButton }
})

# Once a minute: refresh when due (this also catches up after sleep), keep countdowns and position current.
$minuteTimer = New-Object Windows.Threading.DispatcherTimer
$minuteTimer.Interval = [TimeSpan]::FromMinutes(1)
$minuteTimer.Add_Tick({
  $due = ((Get-Date) - $script:lastTry).TotalMinutes -ge (Get-RefreshMinutes)
  if (-not $script:job -and ($due -or (Test-ResetPassed))) { Start-Refresh }
  else { Update-All }
  if (Test-UpdateDue) { Start-UpdateCheck }
  if (((Get-Date) - $script:lastFind).TotalMinutes -ge 60) { Start-AutoFind }
  # The installer never took over (offline, blocked): give the button back.
  if ($script:updatingSince -and -not $script:dlJob -and ((Get-Date) - $script:updatingSince).TotalSeconds -gt 600) { $script:updatingSince = $null; $script:updMsg = 'The update did not finish. Try again.'; Update-All }
})

$widget.Add_SourceInitialized({
  $script:hwnd = (New-Object Windows.Interop.WindowInteropHelper($widget)).Handle
  [CuwNative]::MakeToolWindow($script:hwnd)
})
$widget.Add_Loaded({
  Update-Widget
  $topTimer.Start()
  $minuteTimer.Start()
  Start-Refresh
  Complete-PendingUpdate
  if (Test-UpdateDue) { Start-UpdateCheck }
  Start-AutoFind
})

if ($Demo) { Set-DemoData } else { Import-UiConfig }

try {
  $app = New-Object Windows.Application
  $app.ShutdownMode = 'OnMainWindowClose'
  [void]$app.Run($widget)
} catch {
  Write-Log "fatal: $_"
  throw
} finally {
  if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() }
  $mutex.ReleaseMutex()
}
