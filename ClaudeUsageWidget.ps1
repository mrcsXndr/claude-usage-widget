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
.PARAMETER FormatCheck
  Check the compact reset-time text (Format-ResetShort) against the table in the 2.0 spec; exit 1 on a miss.
.PARAMETER MigrateCheck
  Check the 1.x -> 2.0 config migration on fixture configs (and the config.v1.json backup); exit 1 on a miss.
#>
param([switch]$Once, [switch]$Demo, [string]$Snapshot, [switch]$RingCheck, [switch]$FormatCheck, [switch]$MigrateCheck)

$ErrorActionPreference = 'Stop'
$LibPath = Join-Path $PSScriptRoot 'lib\Usage.ps1'
. $LibPath

if ($Once) {
  Get-AllUsage (Read-Config) | ConvertTo-Json -Depth 4
  exit
}

$script:checkFails = 0
function Assert-Eq([string]$what, $got, $want) {
  $ok = "$got" -ceq "$want"
  if (-not $ok) { $script:checkFails++ }
  '{0,-4} {1}  got [{2}] want [{3}]' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $what, $got, $want
}

if ($FormatCheck) {
  $now = [DateTime]'2026-11-04 12:00:00'   # a Wednesday, local time
  $at = { param($t) $t.ToUniversalTime().ToString('o') }
  $cases = @(
    @('none', $null, '12h', ''), @('empty', '', '12h', ''),
    @('past', (& $at $now.AddMinutes(-1)), '12h', ''), @('now', (& $at $now), '12h', ''),
    @('37 min', (& $at $now.AddMinutes(37)), '12h', 'in 37m'),
    @('1 min', (& $at $now.AddSeconds(20)), '12h', 'in 1m'),
    @('59.5 min rounds up to 1 h', (& $at $now.AddSeconds(3570)), '12h', 'in 1h 00m'),
    @('exactly 60 min', (& $at $now.AddMinutes(60)), '12h', 'in 1h 00m'),
    @('2h 14m', (& $at $now.AddMinutes(134)), '12h', 'in 2h 14m'),
    @('4h 59m', (& $at $now.AddMinutes(299)), '12h', 'in 4h 59m'),
    @('exactly 5 h, same day', (& $at $now.AddHours(5)), '12h', '5pm'),
    @('later today :30', (& $at $now.AddMinutes(330)), '12h', '5:30pm'),
    @('later today 11pm', (& $at $now.AddHours(11)), '12h', '11pm'),
    @('midnight is next day 12am', (& $at $now.AddHours(12)), '12h', 'Th 12am'),
    @('00:30 next day', (& $at $now.AddMinutes(750)), '12h', 'Th 12:30am'),
    @('noon next day', (& $at $now.AddDays(1)), '12h', 'Th 12pm'),
    @('Fri 3pm', (& $at $now.AddDays(2).AddHours(3)), '12h', 'F 3pm'),
    @('Sat', (& $at $now.AddDays(3)), '12h', 'Sa 12pm'),
    @('Sun 11pm', (& $at $now.AddDays(4).AddHours(11)), '12h', 'Su 11pm'),
    @('Mon 6:05am', (& $at $now.AddDays(5).AddHours(-6).AddMinutes(5)), '12h', 'M 6:05am'),
    @('Tue 3pm', (& $at $now.AddDays(6).AddHours(3)), '12h', 'Tu 3pm'),
    @('next Wed 12pm', (& $at $now.AddDays(7)), '12h', 'W 12pm'),
    @('24h later today', (& $at $now.AddHours(5)), '24h', '17:00'),
    @('24h other day', (& $at $now.AddDays(4).AddHours(3)), '24h', 'Su 15:00'),
    @('24h midnight', (& $at $now.AddHours(12)), '24h', 'Th 00:00'),
    @('24h countdown unchanged', (& $at $now.AddMinutes(37)), '24h', 'in 37m')
  )
  foreach ($c in $cases) { Assert-Eq $c[0] (Format-ResetShort $c[1] $c[2] $now) $c[3] }
  Assert-Eq 'DateTime input' (Format-ResetShort $now.AddHours(11) '12h' $now) '11pm'
  Assert-Eq 'long form' (Format-ResetLong (& $at $now.AddDays(6).AddHours(3)) '12h' $now) 'Resets Tuesday 3:00 pm (in 6d 3h)'
  Assert-Eq 'long form 24h' (Format-ResetLong (& $at $now.AddHours(5)) '24h' $now) 'Resets today 17:00 (in 5h 00m)'
  if ($script:checkFails) { "$($script:checkFails) format check(s) FAILED"; exit 1 }
  'all format checks passed'
  exit 0
}

if ($MigrateCheck) {
  $accts = '"accounts":[{"name":"a","source":"env","env":"X","limits":["7d"],"style":"combined"}]'
  $fx = @{
    default = "{`"refreshMinutes`":15,$accts}"
    hideTrue = "{`"refreshMinutes`":15,`"hideAtLimit`":true,`"size`":`"normal`",`"inside`":`"percent`",`"next`":`"caption`",`"names`":`"right`",$accts}"
    hideFalse = "{`"refreshMinutes`":15,`"hideAtLimit`":false,$accts}"
    legacy = "{`"refreshMinutes`":15,`"showPercents`":false,`"showCaptions`":false,`"showNames`":false,`"showLegend`":true,$accts}"
    v194 = "{`"refreshMinutes`":15,`"hideAtLimit`":true,`"showPercents`":false,`"showLegend`":true,$accts}"
    preset = "{`"size`":`"normal`",`"inside`":`"initials`",`"next`":`"usage`",`"names`":`"hidden`",$accts}"
    v2 = "{`"configVersion`":2,`"look`":`"detailed`",`"atLimit`":`"show`",$accts}"
  }
  $m = @{}
  foreach ($k in $fx.Keys) { $m[$k] = ($fx[$k] | ConvertFrom-Json); [void](Update-ConfigV2 $m[$k]) }
  foreach ($k in 'default', 'hideTrue', 'hideFalse', 'legacy', 'v194', 'preset', 'v2') {
    $c = $m[$k]
    Assert-Eq "$k configVersion" $c.configVersion 2
    Assert-Eq "$k accounts kept" ($c.accounts[0].name + '/' + $c.accounts[0].style + '/' + $c.accounts[0].limits[0]) 'a/combined/7d'
    foreach ($gone in 'hideAtLimit', 'showLegend', 'showPercents', 'showCaptions', 'showNames') { Assert-Eq "$k drops $gone" ([bool]$c.PSObject.Properties[$gone]) $false }
  }
  $c = $m.default
  Assert-Eq 'default look' $c.look 'balanced'; Assert-Eq 'default atLimit' $c.atLimit 'group'; Assert-Eq 'default show5h' $c.show5h $true
  Assert-Eq 'default timeFormat' $c.timeFormat '12h'; Assert-Eq 'default listLimited' $c.listLimited 'group'
  Assert-Eq 'default listFable' $c.listFable 'used'; Assert-Eq 'default listPlan' $c.listPlan $true
  Assert-Eq 'default refresh kept' $c.refreshMinutes 15
  $c = $m.hideTrue
  Assert-Eq 'hideTrue atLimit' $c.atLimit 'hide'; Assert-Eq 'hideTrue look' $c.look 'custom'
  Assert-Eq 'hideTrue values kept' "$($c.size)/$($c.inside)/$($c.next)/$($c.names)" 'normal/percent/caption/right'
  Assert-Eq 'hideFalse atLimit' $m.hideFalse.atLimit 'show'
  $c = $m.legacy
  Assert-Eq 'legacy look' $c.look 'minimal'; Assert-Eq 'legacy values' "$($c.size)/$($c.inside)/$($c.next)/$($c.names)" 'compact/initials/none/hidden'
  $c = $m.v194
  Assert-Eq 'v194 atLimit' $c.atLimit 'hide'; Assert-Eq 'v194 look' $c.look 'custom'
  Assert-Eq 'v194 values' "$($c.size)/$($c.inside)/$($c.next)/$($c.names)" 'compact/initials/none/left'
  Assert-Eq 'preset look' $m.preset.look 'balanced'
  Assert-Eq 'v2 untouched' "$($m.v2.look)/$($m.v2.atLimit)" 'detailed/show'
  Assert-Eq 'v2 returns false' (Update-ConfigV2 $m.v2) $false

  # File round trip in a temp folder: the backup is a byte-for-byte copy and a second read changes nothing.
  $tmp = Join-Path $env:TEMP "cuw-migrate-$PID"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $AppDir = $tmp; $ConfigPath = Join-Path $tmp 'config.json'
  try {
    Set-Content $ConfigPath $fx.v194 -Encoding UTF8
    $hash = { param($p) [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($p))) }
    $orig = & $hash $ConfigPath
    $cfg = Read-Config
    Assert-Eq 'file: configVersion' $cfg.configVersion 2
    Assert-Eq 'file: config.v1.json exists' (Test-Path (Join-Path $tmp 'config.v1.json')) $true
    Assert-Eq 'file: backup identical to the old config' (& $hash (Join-Path $tmp 'config.v1.json')) $orig
    $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Assert-Eq 'file: saved atLimit' $saved.atLimit 'hide'
    $h1 = & $hash $ConfigPath
    [void](Read-Config)
    Assert-Eq 'file: second read leaves config.json alone' (& $hash $ConfigPath) $h1
    Assert-Eq 'file: second read leaves the backup alone' (& $hash (Join-Path $tmp 'config.v1.json')) $orig
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($script:checkFails) { "$($script:checkFails) migration check(s) FAILED"; exit 1 }
  'all migration checks passed'
  exit 0
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
    foreach ($k in 'updateCheckedAt', 'updateVersion', 'updateNotes', 'notifiedVersion', 'pendingUpdate', 'ignoredAccounts', 'hintCount', 'limitedOpen') {
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

function New-DefaultConfig($accounts = @()) {
  $c = [pscustomobject]@{ refreshMinutes = 30; captions = [pscustomobject]$DefaultCaptions; accounts = @($accounts) }
  [void](Update-ConfigV2 $c)
  return $c
}

# Until the first refresh has run (and, on a first run, discovered accounts), there may be no file yet.
function Import-UiConfig {
  if ($Demo) { return }
  try {
    $script:config = if (Test-Path $ConfigPath) { Read-Config } else { New-DefaultConfig }
    $script:configError = $null
  } catch {
    $script:configError = "config.json: $($_.Exception.Message)"
    if (-not $script:config) { $script:config = New-DefaultConfig }
  }
}

# Settings apply at once: an edit schedules one write 400 ms after the last edit (Flush-UiConfig writes now).
$script:savePending = $false
$saveTimer = New-Object Windows.Threading.DispatcherTimer
$saveTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$saveTimer.Add_Tick({ Flush-UiConfig })
function Save-UiConfig {
  if ($Demo) { return }
  $script:savePending = $true
  $saveTimer.Stop(); $saveTimer.Start()
}
function Flush-UiConfig {
  $saveTimer.Stop()
  if (-not $script:savePending) { return }
  $script:savePending = $false
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
# Also true while "Show the 5-hour window" is off, so every caller (bars, rings, tooltips, the list) drops 5h at once.
function Test-NoFiveH($res) {
  if ($script:config.show5h -eq $false) { return $true }
  return (Test-LacksFiveH $res)
}
# The account's read worked and returned no 5h number (Ultra and similar); an error or "loading" is not "no 5h".
function Test-LacksFiveH($res) {
  if (-not $res -or $res.status -notin 'ok', 'limited') { return $false }
  $w = $res.five_h
  return (-not $w -or $null -eq $w.pct)
}
# The account really has a 5h window (its read worked and returned a 5h number), whatever show5h says.
function Test-HasFiveH($res) {
  if (-not $res -or $res.status -notin 'ok', 'limited') { return $false }
  return ($res.five_h -and $null -ne $res.five_h.pct)
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

# An account is limited while its read says so and a 5h or 7d window is still at 100% (a window whose reset has passed counts as 0).
function Test-Limited($res) {
  if (-not $res -or $res.status -ne 'limited') { return $false }
  return ((Get-Win $res '5h').pct -ge 100) -or ((Get-Win $res '7d').pct -ge 100)
}
# When a limited account is back: the later reset of its windows that sit at 100% (a DateTime), else $null.
function Get-BackAt($res) {
  $best = $null
  foreach ($k in '5h', '7d') {
    $w = Get-Win $res $k
    if ($w -and $w.pct -ge 100 -and $w.reset) { $t = ConvertTo-LocalTime $w.reset; if (-not $best -or $t -gt $best) { $best = $t } }
  }
  return $best
}
function Get-AtLimitMode { $v = "$($script:config.atLimit)"; if ($v -in 'group', 'show', 'hide') { $v } else { 'group' } }

# Accounts drawn on the taskbar as normal items: the ticked ones. At limit: group (default) draws those that are full as
# ONE item instead (Get-LimitedCfgs); show keeps them as red items; hide drops them until the reset (but if that would
# hide every account they all stay, so the widget never vanishes). The list and Settings use Get-TaskbarCfgs.
function Get-ShownCfgs {
  $all = @(Get-TaskbarCfgs)
  $mode = Get-AtLimitMode
  if ($mode -eq 'show') { return $all }
  $ok = @($all | Where-Object { -not (Test-Limited (Get-Result $_.name)) })
  if ($mode -eq 'hide' -and -not $ok.Count) { return $all }
  return $ok
}
# The accounts the at-limit group stands for, soonest back first (empty unless the mode is group).
function Get-LimitedCfgs {
  if ((Get-AtLimitMode) -ne 'group') { return @() }
  $l = @(Get-TaskbarCfgs | Where-Object { Test-Limited (Get-Result $_.name) })
  return @($l | Sort-Object { $b = Get-BackAt (Get-Result $_.name); if ($b) { $b.Ticks } else { [int64]::MaxValue } })
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

function Get-SystemLight {
  try { return (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' SystemUsesLightTheme) -eq 1 } catch { return $false }
}
$isLight = $false
if ($env:CUW_THEME -in 'light', 'dark') { $isLight = $env:CUW_THEME -eq 'light' }   # for snapshots and testing
elseif (-not $Snapshot -and -not $RingCheck) { $isLight = Get-SystemLight }
$Theme = if ($isLight) {
  @{ fg = '#1A1A1A'; sub = '#5F5F5F'; ring = '#26000000'; card = '#F9F9F9'; border = '#D0D0D0'; hover = '#EAEAEA'; bar = '#E3E3E3'; field = '#FFFFFF'; widgetHover = '#1A000000'
     chip = '#0F000000'; row = '#FFFFFF'; rowline = '#12000000'; nav = '#0E000000'; win = '#F3F3F3'; tb = '#EEEEEE' }
} else {
  @{ fg = '#FFFFFF'; sub = '#A3A3A3'; ring = '#3DFFFFFF'; card = '#202020'; border = '#3A3A3A'; hover = '#2B2B2B'; bar = '#3A3A3A'; field = '#2B2B2B'; widgetHover = '#1FFFFFFF'
     chip = '#14FFFFFF'; row = '#0BFFFFFF'; rowline = '#40000000'; nav = '#0FFFFFFF'; win = '#202020'; tb = '#1C1C1C' }
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

function Get-TimeFormat { if ("$($script:config.timeFormat)" -eq '24h') { '24h' } else { '12h' } }
# Compact reset text for bars and lists ('in 37m', '11pm', 'Su 11pm'); the tooltip spells it out (Format-ResetLong).
function Get-Reset($iso) { Format-ResetShort $iso (Get-TimeFormat) }
function Get-ResetLong($iso) { Format-ResetLong $iso (Get-TimeFormat) }

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

# Generic demo accounts (docs images must never show real account names): three Ultra-style accounts with 7d + Fable,
# one with a 5h window, three at their limit (back on Sunday at 1am, 5am and 9pm).
function Set-DemoData {
  $now = [DateTime]::UtcNow
  # $when is minutes from now, or a local DateTime.
  $w = { param($p, $when) [pscustomobject]@{ pct = $p; reset = $(if ($when -is [DateTime]) { $when.ToUniversalTime().ToString('o') } elseif ($null -ne $when) { $now.AddMinutes($when).ToString('o') }) } }
  # The next given weekday after today at midnight + $h hours.
  $dow = { param([DayOfWeek]$d, [double]$h) $t = (Get-Date).Date.AddDays(1); while ($t.DayOfWeek -ne $d) { $t = $t.AddDays(1) }; $t.AddHours($h) }
  $script:config = New-DefaultConfig @(
    [pscustomobject]@{ name = 'personal'; label = 'Personal'; plan = 'Ultra'; source = 'claude-code'; taskbar = $true; limits = @('7d') }
    [pscustomobject]@{ name = 'work'; label = 'Work'; plan = 'Ultra'; source = 'env'; taskbar = $true; limits = @('7d') }
    [pscustomobject]@{ name = 'studio'; label = 'Studio'; plan = 'Ultra'; source = 'env'; taskbar = $true; limits = @('7d') }
    [pscustomobject]@{ name = 'side'; label = 'Side project'; plan = 'Max 20x'; source = 'env'; taskbar = $true; style = 'combined'; pie = '5h' }
    [pscustomobject]@{ name = 'client'; label = 'Client'; plan = 'Ultra'; source = 'env'; taskbar = $true; limits = @('7d') }
    [pscustomobject]@{ name = 'lab'; label = 'Lab'; plan = 'Ultra'; source = 'env'; taskbar = $true; limits = @('7d') }
    [pscustomobject]@{ name = 'backup'; label = 'Backup'; plan = 'Ultra'; source = 'env'; taskbar = $true; limits = @('7d') }
  )
  $ok = { param($n, $five, $seven, $fable, $status = 'ok') [pscustomobject]@{ name = $n; status = $status; error = $null; method = 'probe'; five_h = $five; seven_d = $seven; fable = $fable } }
  $none = & $w $null $null
  $script:accounts = @(
    (& $ok 'personal' $none (& $w 14 (& $dow Wednesday 12)) (& $w 0 (& $dow Wednesday 12)))
    (& $ok 'work' $none (& $w 52 (& $dow Sunday 23)) (& $w 0 (& $dow Sunday 23)))
    (& $ok 'studio' $none (& $w 34 (& $dow Sunday 18)) (& $w 0 (& $dow Sunday 18)))
    (& $ok 'side' (& $w 64 37) (& $w 52 (& $dow Tuesday 15)) (& $w 0 (& $dow Tuesday 15)))
    (& $ok 'client' $none (& $w 100 (& $dow Sunday 1)) $none 'limited')
    (& $ok 'lab' $none (& $w 100 (& $dow Sunday 5)) $none 'limited')
    (& $ok 'backup' $none (& $w 100 (& $dow Sunday 21)) $none 'limited')
  )
  $script:updated = (Get-Date).Date.AddHours(14).AddMinutes(6)
  $script:config.refreshMinutes = 15
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
  # An edit still waiting for its write is newer than the file: keep it, and pick up accounts a scan just added.
  if ($script:savePending) {
    if ($j.discover -and -not $Demo) {
      try { foreach ($a in @((Read-Config).accounts | Where-Object { $_ })) { if (-not (Get-AcctCfg $a.name)) { $script:config.accounts = @(Get-AcctCfgs) + @($a) } } } catch {}
    }
  } else { Import-UiConfig }
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
  $script:update = [pscustomobject]@{ version = '2.1.0'; notes = "Self-update check with a tray notification`nFaster refresh on wake" }
  $script:updMsg = if ($script:updManual) { 'v2.1.0 is available' }
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
  $PopupEls.UpdBtn.Content = if ($busy) { "Updating$ELL" } else { 'Update' }
  $PopupEls.UpdBtn.IsEnabled = -not $busy
  if ($script:update) {
    $PopupEls.UpdTitle.Text = if ($busy) { "$($script:updMsg)" } else { "v$($script:update.version) is ready" }
    $PopupEls.UpdBox.ToolTip = if ($script:update.notes) { "What's new in v$($script:update.version)`n$($script:update.notes)" } else { $null }
  }
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
  Flush-UiConfig
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
  compact = @{ dip = 28; thick = 3.5; inner = 17; innerThick = 2.2; inFont = 10.5; nextFont = 11; pad = 4; rows = 1 }
  normal  = @{ dip = 32; thick = 4;   inner = 19; innerThick = 2.5; inFont = 12;   nextFont = 12; pad = 4; rows = 1 }
  large   = @{ dip = 38; thick = 4.5; inner = 22; innerThick = 3;   inFont = 13;   nextFont = 13; pad = 3; rows = 2 }
}
# The Look (minimal / balanced / detailed, or custom) decides size, inside, next and names; custom reads the config's own values.
function Get-LookKey { $k = "$($script:config.look)"; if ($k -in 'minimal', 'balanced', 'detailed', 'custom') { $k } else { 'balanced' } }
function Get-LookValue([string]$key) {
  $lk = Get-LookKey
  if ($lk -ne 'custom') { return $LookPresets[$lk][$key] }
  $v = "$($script:config.$key)"
  if ($v) { return $v }
  return $LookPresets.balanced[$key]
}
function Get-SizeKey { $k = Get-LookValue 'size'; if ($SizePresets.ContainsKey($k)) { $k } else { 'normal' } }
function Set-SizePreset {
  $p = $SizePresets[(Get-SizeKey)]
  $script:RingDip = $p.dip; $script:RingThick = $p.thick; $script:RingInnerDip = $p.inner; $script:RingInnerThick = $p.innerThick
  $script:InFont = $p.inFont; $script:NextFont = $p.nextFont; $script:PadV = $p.pad; $script:TwoRows = $p.rows -eq 2
  # Combined dials have no room for a second text row, so Normal and Large put the reset time on each limit's line.
  $script:ShowReset = (Get-SizeKey) -ne 'compact'
  $sp = $SpacingPresets[(Get-SpacingKey)]
  $script:GapSide = $sp.side; $script:GapRing = $sp.ring
  if ((Get-LookKey) -eq 'minimal') { $script:GapSide = 8; $script:GapRing = 8 }
}
# Touching any individual option switches to Look: custom, keeping what the current Look shows.
function Set-LookOption([string]$key, $value) {
  if ((Get-LookKey) -ne 'custom') {
    foreach ($k in 'size', 'inside', 'next', 'names') { $script:config | Add-Member -Force -NotePropertyName $k -NotePropertyValue (Get-LookValue $k) }
    $script:config | Add-Member -Force -NotePropertyName look -NotePropertyValue 'custom'
  }
  $script:config | Add-Member -Force -NotePropertyName $key -NotePropertyValue $value
}
# Space between account groups (each side of the divider) and between the rings of one account.
$SpacingPresets = @{ tight = @{ side = 5; ring = 6 }; normal = @{ side = 14; ring = 14 }; wide = @{ side = 26; ring = 22 } }
function Get-SpacingKey { $k = "$($script:config.spacing)"; if ($SpacingPresets.ContainsKey($k)) { $k } else { 'normal' } }
Set-SizePreset

# Where the account name goes: left of its rings, right of them, or nowhere (older configs: showNames).
function Get-NamesMode { $v = Get-LookValue 'names'; if ($v -in 'left', 'right', 'hidden') { $v } else { 'hidden' } }
# Which limit is the inner ring of a combined dial: the account's own choice, else the global one, else 5h.
function Get-PieKey($cfg) {
  foreach ($v in "$($cfg.pie)", "$($script:config.innerWindow)") { if ($v -in '5h', '7d') { return $v } }
  return '5h'
}

# What goes inside a ring (none | initials | percent) and next to it (none | caption | percent). Configs from before
# these choices existed map from the old switches: percentages on = number inside + caption beside, off = initials only.
function Get-InsideMode { $v = Get-LookValue 'inside'; if ($v -in 'none', 'initials', 'percent') { $v } else { 'initials' } }
function Get-NextMode { $v = Get-LookValue 'next'; if ($v -in 'none', 'caption', 'percent', 'usage', 'resetin', 'resetat') { $v } else { 'usage' } }

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
  if ((Get-InsideMode) -eq 'initials' -and $short.Length -gt 1) { return $InFont - 1 }
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
  if ($nx -in 'none', 'usage') { return '' }   # usage: one text block per account (Get-UsageTextXaml), not one per ring
  $main = Get-NextText $nx $pct $caption $reset
  $weight = if ($nx -eq 'percent') { 'Bold' } else { 'SemiBold' }
  $opacity = if ($nx -in 'percent', 'resetin', 'resetat') { 1 } else { 0.8 }
  $r = if ($script:TwoRows -and $nx -in 'caption', 'percent') { Get-Reset $reset } else { '' }
  $second = if ($r) { "<TextBlock Text=`"$(Esc $r)`" FontSize=`"$($NextFont - 2)`" Foreground=`"$($Theme.sub)`"/>" } else { '' }
  return "<StackPanel VerticalAlignment=`"Center`" Margin=`"6,0,0,1`"><TextBlock Text=`"$(Esc $main)`" FontSize=`"$NextFont`" FontWeight=`"$weight`" Foreground=`"$($Theme.fg)`" Opacity=`"$opacity`"/>$second</StackPanel>"
}

# Hover text for one ring: which account, which limit, how full, when it resets.
function Get-RingTip($cfg, [string]$key, $w, [string]$place = '') {
  if (-not $cfg) { return '' }
  $pct = if ($w -and $null -ne $w.pct) { "$(Format-Pct $w.pct)%" } else { $DASH }
  $rs = if ($w) { Get-ResetLong $w.reset } else { '' }
  return "$(Get-Label $cfg)`n$(Get-Caption $key)  $pct$(if ($place) { "  ($place)" })$(if ($rs) { "`n$rs" })"
}

# The tightest window an account shows: highest % of its shown windows, Fable left out unless nothing else is shown.
# 'many' says the account draws more than one window, so the text beside it names the one it reports.
function Get-Tightest($cfg, $res) {
  $keys = @(Get-ShownLimits $cfg $res)
  if ($cfg.style -eq 'combined' -and -not (Test-NoFiveH $res)) { $keys = @('5h', '7d') }
  $cand = @($keys | Where-Object { $_ -ne 'fable' })
  if (-not $cand.Count) { $cand = $keys }
  $best = $null; $bk = $cand[0]
  foreach ($k in $cand) {
    $w = Get-Win $res $k
    if ($w -and $null -ne $w.pct -and (-not $best -or $w.pct -gt $best.pct)) { $best = $w; $bk = $k }
  }
  if (-not $best) { $best = Get-Win $res $bk }
  return [pscustomobject]@{ key = $bk; win = $best; many = ($keys.Count -gt 1) }
}

# Next to an account's ring(s) in the Usage look: "14%" over "W 12pm" (with the window's caption when the account has
# several: "5h 64%" over "in 37m"). With $name (the Detailed look) it reads "XNDR" over "14% . W 12pm".
function Get-UsageTextXaml($cfg, $res, [string]$name = '') {
  $t = Get-Tightest $cfg $res
  $w = $t.win
  $pct = if ($w -and $null -ne $w.pct) { "$(Format-Pct $w.pct)%" } elseif ($script:job) { $ELL } else { $DASH }
  $rs = if ($w) { Get-Reset $w.reset } else { '' }
  $soon = $false
  if ($w -and $w.reset) { $left = (ConvertTo-LocalTime $w.reset) - (Get-Date); $soon = $left.TotalMinutes -gt 0 -and $left.TotalMinutes -lt 60 }
  $f2 = $NextFont - 1
  if ($name) {
    $l1 = "<TextBlock Text=`"$(Esc $name)`" FontSize=`"$NextFont`" FontWeight=`"SemiBold`" Foreground=`"$($Theme.fg)`" TextTrimming=`"CharacterEllipsis`" MaxWidth=`"110`"/>"
    $l2 = "<TextBlock FontSize=`"$f2`" Foreground=`"$($Theme.sub)`"><Run Text=`"$(Esc $pct)`"/><Run Text=`"$(Esc $(if ($rs) { " $DOT " }))`"/><Run Text=`"$(Esc $rs)`" Foreground=`"$(if ($soon) { $Theme.fg } else { $Theme.sub })`"/></TextBlock>"
  } else {
    $cap = if ($t.many) { "<Run Text=`"$(Esc (Get-Caption $t.key)) `" FontWeight=`"Normal`" FontSize=`"$f2`" Foreground=`"$($Theme.sub)`"/>" } else { '' }
    $l1 = "<TextBlock FontSize=`"$NextFont`" FontWeight=`"SemiBold`" Foreground=`"$($Theme.fg)`">$cap<Run Text=`"$(Esc $pct)`"/></TextBlock>"
    $l2 = if ($rs) { "<TextBlock Text=`"$(Esc $rs)`" FontSize=`"$f2`" Foreground=`"$(if ($soon) { $Theme.fg } else { $Theme.sub })`"/>" } else { '' }
  }
  return [Windows.Markup.XamlReader]::Parse("<StackPanel $ns VerticalAlignment=`"Center`" Margin=`"7,0,0,1`">$l1$l2</StackPanel>")
}

# The at-limit group: one red full ring with the count, "At limit" over when the first account is back.
function New-LimitGroupElement($limited) {
  $sz = Get-RingSize
  $backs = @($limited | ForEach-Object { Get-BackAt (Get-Result $_.name) })
  $first = @($backs | Where-Object { $_ } | Sort-Object | Select-Object -First 1)
  $text = ''
  if ((Get-NextMode) -ne 'none') {
    $b = if ($first.Count) { Get-Reset $first[0] } else { '' }
    $line2 = ''
    if ($b) { $line2 = "<TextBlock Text=`"$(Esc $b)`" FontSize=`"$($NextFont - 1)`" FontWeight=`"SemiBold`" Foreground=`"$($Theme.fg)`"/>" }
    $text = "<StackPanel VerticalAlignment=`"Center`" Margin=`"7,0,0,1`"><TextBlock Text=`"At limit`" FontSize=`"$NextFont`" Foreground=`"$($Theme.sub)`"/>$line2</StackPanel>"
  }
  $el = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Orientation="Horizontal" Background="#01000000">
  <Grid Width="$sz" Height="$sz">
    <Ellipse Stroke="$($Theme.ring)" StrokeThickness="$RingThick"/>
    <Path Name="Arc" StrokeThickness="$RingThick"/>
    <TextBlock Text="$(@($limited).Count)" FontSize="$InFont" FontWeight="SemiBold" Foreground="$($Theme.fg)" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1.3"/>
  </Grid>
  $text
</StackPanel>
"@)
  Set-Ring ($el.FindName('Arc')) 100 $sz
  return $el
}

function Get-LimitGroupTip($limited) {
  $lines = @("At limit ($(@($limited).Count))")
  foreach ($c in @($limited)) {
    $b = Get-BackAt (Get-Result $c.name)
    $lines += "$(Get-Label $c)  $(if ($b) { 'back ' + (Get-Reset $b) } else { $DASH })"
  }
  return ($lines -join "`n")
}

function New-RingElement($pct, [string]$caption, [bool]$gapAfter, [string]$short, $reset, [string]$tip = '') {
  $sz = Get-RingSize
  $el = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Orientation="Horizontal" Background="#01000000" Margin="0,0,$(if ($gapAfter) { $GapRing } else { 0 }),0">
  <Grid Width="$sz" Height="$sz">
    <Ellipse Stroke="$($Theme.ring)" StrokeThickness="$RingThick"/>
    <Path Name="Arc" StrokeThickness="$RingThick"/>
    <TextBlock Text="$(Get-InsideText $pct $short)" FontSize="$(Get-InsideSize $short)" FontWeight="SemiBold" Foreground="$($Theme.fg)" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1.3"/>
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
  if ($nx -ne 'usage' -and ($nx -ne 'none' -or $script:ShowReset)) {
    $lines = '<StackPanel VerticalAlignment="Center" Margin="7,0,0,0">' + (@(foreach ($k in '5h', '7d') {
      $w = Get-Win $res $k
      $main = if ($nx -eq 'none') { '' } else { Get-NextText $nx $w.pct (Get-Caption $k) $w.reset }
      $color = Get-UsageColor $w.pct
      $mark = if ($k -eq $pieKey) { "<Ellipse Width=`"8`" Height=`"8`" Fill=`"$color`"/>" } else { "<Ellipse Width=`"8`" Height=`"8`" Stroke=`"$color`" StrokeThickness=`"1.8`"/>" }
      $r = if ($script:ShowReset -and $nx -notin 'resetin', 'resetat') { Get-Reset $w.reset } else { '' }
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
    <TextBlock Text="$(Esc $text)" FontSize="$([Math]::Max(7.5, $InFont - 3))" FontWeight="SemiBold" Foreground="$($Theme.fg)" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1.2"/>
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
      if ($w -and $null -ne $w.pct) { $tip += "$(Get-Caption $k)  $(Format-Pct $w.pct)%$(if ($places[$k]) { "  ($($places[$k]))" })$(if ($w.reset) { "  $DOT  $(Get-ResetLong $w.reset)" })" }
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
  if ($name -eq '__limit__') { return (Get-LimitGroupTip @(Get-LimitedCfgs)) }
  if (-not $name) { return $(if ($script:job) { "Looking for accounts$ELL" } else { (Get-AccountTip $null $null) + "`nNo accounts yet: right-click > Scan for accounts" }) }
  return (Get-AccountTip (Get-AcctCfg $name) (Get-Result $name))
}

# Everything that changes how the rings look. When it is the same as last time the rings are left alone
# (rebuilding them every time is what made the widget flash on click and close); only the tooltips are refreshed.
$script:widgetSig = $null
function Get-WidgetSig($cfgs, $lim = @()) {
  $dpi = 1.0
  try { $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($widget).DpiScaleX } catch {}
  $parts = @(($script:config | ConvertTo-Json -Depth 6 -Compress), "$dpi", "$([bool]$script:job)", "$($widget.IsLoaded)", "$(@($script:newAccts | ForEach-Object name) -join ',')", (Get-Shorts | ConvertTo-Json -Compress), "shown:$(@($cfgs | ForEach-Object name) -join ',')")
  $parts += "look:$(Get-LookKey)|show5h:$($script:config.show5h)|atLimit:$(Get-AtLimitMode)|time:$(Get-TimeFormat)"
  $reset = $script:TwoRows -or $script:ShowReset -or (Get-NextMode) -in 'resetin', 'resetat', 'usage'
  foreach ($cfg in $cfgs) {
    $res = Get-Result $cfg.name
    $parts += "no5h:$(Test-NoFiveH $res)"
    $parts += ($LimitKeys | ForEach-Object { "$((Get-Win $res $_).pct)" }) -join '/'
    if ($reset) { $parts += ($LimitKeys | ForEach-Object { Get-Reset (Get-Win $res $_).reset }) -join '/' }
  }
  if (@($lim).Count) {
    $parts += "limited:$(@($lim | ForEach-Object name) -join ',')"
    $parts += "back:$(@($lim | ForEach-Object { $b = Get-BackAt (Get-Result $_.name); if ($b) { Get-Reset $b } }) -join ',')"
  }
  return ($parts -join '|')
}

# Fills a StackPanel with the account items: the taskbar widget's own panel, and the Settings preview at 1:1.
function Build-WidgetGroups($panel, $cfgs, $lim) {
  $panel.Children.Clear()
  $items = @($cfgs) + $(if (@($lim).Count) { ,'__limit__' })
  if (-not $items.Count) {
    $g = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Background = '#01000000' }
    [void]$g.Children.Add((New-RingElement $null (Get-Caption '5h') $true))
    [void]$g.Children.Add((New-RingElement $null (Get-Caption '7d') $false))
    $g.ToolTip = Get-AccountTipFor $null
    [void]$panel.Children.Add($g)
  }
  $shorts = Get-Shorts
  $dividers = $script:config.showDividers -eq $true
  $nameMode = Get-NamesMode
  $usage = (Get-NextMode) -eq 'usage'
  for ($i = 0; $i -lt $items.Count; $i++) {
    $cfg = $items[$i]; $isGroup = $cfg -is [string]
    $g = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Background = '#01000000'; Tag = $(if ($isGroup) { '__limit__' } else { $cfg.name }) }
    if ($i -gt 0) {
      # Same width with or without the line, so switching it on or off moves nothing.
      [void]$g.Children.Add((New-Object Windows.Controls.Border -Property @{ Width = 1; Height = $RingDip - 8; Background = $(if ($dividers) { $Theme.ring } else { 'Transparent' }); Margin = "$GapSide,0,$GapSide,0" }))
    }
    if ($isGroup) {
      [void]$g.Children.Add((New-LimitGroupElement $lim))
      $g.ToolTip = Get-LimitGroupTip $lim
      [void]$panel.Children.Add($g)
      continue
    }
    $res = Get-Result $cfg.name
    # In the Usage look a name on the left is part of the text block ("XNDR" over "14% . W 12pm"), not a separate label.
    $inline = $usage -and $nameMode -eq 'left'
    $nameEl = $null
    if ($nameMode -ne 'hidden' -and -not $inline) {
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
    if ($usage) { [void]$g.Children.Add((Get-UsageTextXaml $cfg $res $(if ($inline) { Get-Label $cfg } else { '' }))) }
    if ($nameEl -and $nameMode -eq 'right') { [void]$g.Children.Add($nameEl) }
    $g.ToolTip = Get-AccountTipFor $cfg.name
    [void]$panel.Children.Add($g)
  }
}

function Update-Widget {
  Set-SizePreset
  $cfgs = @(Get-ShownCfgs); $lim = @(Get-LimitedCfgs)
  $sig = Get-WidgetSig $cfgs $lim
  if ($sig -eq $script:widgetSig -and $WidgetEls.Groups.Children.Count) {
    foreach ($g in $WidgetEls.Groups.Children) { if ($g -is [Windows.Controls.StackPanel]) { $g.ToolTip = Get-AccountTipFor $g.Tag } }
    if ($widget.IsLoaded) { Set-WidgetPosition }
    return
  }
  $script:widgetSig = $sig
  Build-WidgetGroups $WidgetEls.Groups $cfgs $lim
  $WidgetEls.Root.Padding = "8,$PadV"
  if ($script:newAccts.Count) {
    [void]$WidgetEls.Groups.Children.Add((New-Object Windows.Shapes.Ellipse -Property @{
      Width = 7; Height = 7; Fill = $Colors.accent; VerticalAlignment = 'Top'; Margin = '4,0,0,0'
      ToolTip = "New account found: $(($script:newAccts | ForEach-Object { Get-Label $_ }) -join ', '). Open the list to add or ignore it."
    }))
  }
  $WidgetEls.Root.Opacity = if ($script:job) { 0.6 } else { 1.0 }
  if ($widget.IsLoaded) { Set-WidgetPosition }
  Update-Preview
}

# The Settings > Taskbar preview: the same renderer, drawn at 1:1 on a taskbar-coloured box.
function Update-Preview {
  $p = $PopupEls.PrevGroups
  if (-not $p) { return }
  if (-not $settings.IsVisible -and -not $script:previewForce) { return }
  Build-WidgetGroups $p @(Get-ShownCfgs) @(Get-LimitedCfgs)
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
  <Border x:Name="Card" Background="$($Theme.card)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="8" Padding="12,6,10,10" Margin="12,12,12,12" VerticalAlignment="Bottom">
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
              <Border x:Name="Bg" Background="Transparent" CornerRadius="5" Width="32" Height="32">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" TextElement.FontSize="14" TextElement.Foreground="$($Theme.fg)"/>
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
      <Style TargetType="ScrollBar">
        <Setter Property="Width" Value="10"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Grid Background="Transparent">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                  <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                  <Track.Thumb>
                    <Thumb>
                      <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Margin="2,0" CornerRadius="3" Background="$($Theme.sub)" Opacity="0.55"/></ControlTemplate></Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                </Track>
              </Grid>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="Switch" TargetType="ToggleButton">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ToggleButton">
              <Grid Width="40" Height="20" Background="Transparent">
                <Border x:Name="Track" CornerRadius="10" Background="Transparent" BorderBrush="$($Theme.sub)" BorderThickness="1"/>
                <Ellipse x:Name="Thumb" Width="12" Height="12" Fill="$($Theme.sub)" HorizontalAlignment="Left" Margin="4,0,0,0"/>
              </Grid>
              <ControlTemplate.Triggers>
                <Trigger Property="IsChecked" Value="True">
                  <Setter TargetName="Track" Property="Background" Value="$($Colors.accent)"/>
                  <Setter TargetName="Track" Property="BorderBrush" Value="$($Colors.accent)"/>
                  <Setter TargetName="Thumb" Property="Fill" Value="White"/>
                  <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                  <Setter TargetName="Thumb" Property="Margin" Value="0,0,4,0"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="Combo" TargetType="ComboBox">
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="FontSize" Value="12.5"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ComboBox">
              <Grid MinWidth="132">
                <ToggleButton x:Name="TB" Focusable="False" ClickMode="Press" IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                  <ToggleButton.Template>
                    <ControlTemplate TargetType="ToggleButton">
                      <Border x:Name="Bd" Background="$($Theme.field)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="5">
                        <TextBlock Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="$($Theme.sub)" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="$($Theme.sub)"/></Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </ToggleButton.Template>
                </ToggleButton>
                <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" Margin="10,6,30,6" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="None">
                  <Border MinWidth="{Binding ActualWidth, ElementName=TB}" Background="$($Theme.card)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="6" Padding="3" Margin="0,3,0,0">
                    <ScrollViewer MaxHeight="280" VerticalScrollBarVisibility="Auto"><StackPanel IsItemsHost="True"/></ScrollViewer>
                  </Border>
                </Popup>
              </Grid>
              <ControlTemplate.Triggers>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
        <Style.Resources>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="$($Theme.fg)"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                  <Border x:Name="Bd" CornerRadius="4" Padding="8,5" Background="Transparent"><ContentPresenter/></Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="$($Theme.hover)"/></Trigger>
                    <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="$($Theme.nav)"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Style.Resources>
      </Style>
      <Style x:Key="NavItem" TargetType="RadioButton">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="FontSize" Value="13.5"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="RadioButton">
              <Grid Height="38" Margin="0,1" Background="Transparent">
                <Border x:Name="Bd" Background="Transparent" CornerRadius="5"/>
                <Border x:Name="Pill" Width="3" Height="16" CornerRadius="2" Background="$($Colors.accent)" HorizontalAlignment="Left" Visibility="Collapsed"/>
                <ContentPresenter Margin="14,0,0,0" VerticalAlignment="Center"/>
              </Grid>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="$($Theme.chip)"/></Trigger>
                <Trigger Property="IsChecked" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="$($Theme.nav)"/>
                  <Setter TargetName="Pill" Property="Visibility" Value="Visible"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="Tile" TargetType="RadioButton">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Foreground" Value="$($Theme.fg)"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="RadioButton">
              <Border x:Name="Bd" Background="$($Theme.row)" BorderBrush="$($Theme.rowline)" BorderThickness="1" CornerRadius="6" Padding="14,12" Margin="0,0,10,0">
                <ContentPresenter/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="$($Theme.sub)"/></Trigger>
                <Trigger Property="IsChecked" Value="True">
                  <Setter TargetName="Bd" Property="BorderBrush" Value="$($Colors.accent)"/>
                  <Setter TargetName="Bd" Property="BorderThickness" Value="2"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
      <Style x:Key="LinkBtn" TargetType="Button">
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="Button">
              <TextBlock x:Name="T" Text="{TemplateBinding Content}" FontSize="12" FontWeight="SemiBold" Foreground="$($Colors.accent)" Padding="8,4"/>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="TextDecorations" Value="Underline"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="T" Property="Opacity" Value="0.5"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </Border.Resources>
    <StackPanel>
      <DockPanel Margin="4,4,0,2">
        <Button x:Name="EditBtn" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE713;" ToolTip="Settings" VerticalAlignment="Top"/>
        <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE72C;" VerticalAlignment="Top"/>
        <StackPanel>
          <TextBlock x:Name="Title" Text="Claude usage" FontSize="14" FontWeight="SemiBold" Foreground="$($Theme.fg)"/>
          <TextBlock x:Name="Status" FontSize="11" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,1,0,0"/>
        </StackPanel>
      </DockPanel>
      <Border x:Name="UpdBox" Visibility="Collapsed" Padding="4,0,0,0" Margin="0,2,0,2">
        <DockPanel>
          <Button x:Name="UpdBtn" DockPanel.Dock="Right" Style="{StaticResource LinkBtn}" Content="Update"/>
          <TextBlock x:Name="UpdTitle" FontSize="12" Foreground="$($Theme.fg)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
      </Border>
      <StackPanel x:Name="NewAcctBox"/>
      <StackPanel x:Name="Summary" Orientation="Horizontal" Margin="4,8,4,6"/>
      <StackPanel x:Name="List"/>
      <StackPanel x:Name="LimitedBox"/>
      <TextBlock x:Name="Footer" FontSize="10.5" Foreground="$($Theme.sub)" Margin="4,8,4,2" TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
</Window>
"@
$popup = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $popupXaml))
$PopupEls = @{}
foreach ($n in 'Card', 'Slide', 'RefreshBtn', 'EditBtn', 'Title', 'Status', 'List', 'Summary', 'LimitedBox', 'Footer', 'UpdBox', 'UpdBtn', 'UpdTitle', 'NewAcctBox') { $PopupEls[$n] = $popup.FindName($n) }

# ---------------------------------------------------------------- settings window
# A Win 11 style window: a left nav (Taskbar, Usage list, Accounts, General) and one page at a time on the right. The
# window keeps its size whatever the page (pages sit in a scroll area). Every change applies at once: the config is
# written 400 ms after the last edit (Save-UiConfig), so there is no OK / Cancel / Apply.

$FontIcons = 'Segoe Fluent Icons, Segoe MDL2 Assets'

# One settings row: icon, title, a sub line (named when the code rewrites it) and controls on the right.
function New-SettingXaml([string]$icon, [string]$title, [string]$sub, [string]$right, [string]$subName = '') {
  $nm = if ($subName) { "x:Name=`"$subName`" " } else { '' }
@"
<Border Background="$($Theme.row)" BorderBrush="$($Theme.rowline)" BorderThickness="1" CornerRadius="6" Padding="16,12" Margin="0,0,0,6">
  <DockPanel>
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">$right</StackPanel>
    <TextBlock DockPanel.Dock="Left" Text="$icon" FontFamily="$FontIcons" FontSize="18" Width="40" VerticalAlignment="Center" Foreground="$($Theme.fg)"/>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="$title" FontSize="13.5" Foreground="$($Theme.fg)"/>
      <TextBlock $nm Text="$sub" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,2,0,0"/>
    </StackPanel>
  </DockPanel>
</Border>
"@
}

# A row whose choices are a segmented button strip: radio buttons named <prefix>_<value> (Set-Seg in code reads them).
function New-OptXaml([string]$title, [string]$sub, [string]$prefix, [string[]]$specs) {
  $btns = ($specs | ForEach-Object { $v, $l = $_ -split ':', 2; "<RadioButton x:Name=`"$($prefix)_$v`" Style=`"{DynamicResource Seg}`" GroupName=`"$prefix`" Content=`"$l`" FontSize=`"12.5`" Margin=`"0,0,4,4`"/>" }) -join ''
@"
<Border Background="$($Theme.row)" BorderBrush="$($Theme.rowline)" BorderThickness="1" CornerRadius="6" Padding="16,12,16,8" Margin="0,0,0,6">
  <StackPanel>
    <TextBlock Text="$title" FontSize="13.5" Foreground="$($Theme.fg)"/>
    <TextBlock Text="$sub" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,2,0,8"/>
    <WrapPanel>$btns</WrapPanel>
  </StackPanel>
</Border>
"@
}

# A folded section: a header row that opens and closes its body.
function New-FoldXaml([string]$name, [string]$icon, [string]$title, [string]$sub, [string]$body) {
@"
<Border x:Name="$($name)Head" Background="$($Theme.row)" BorderBrush="$($Theme.rowline)" BorderThickness="1" CornerRadius="6" Padding="16,12" Margin="0,0,0,6" Cursor="Hand">
  <DockPanel Background="Transparent">
    <TextBlock x:Name="$($name)Chev" DockPanel.Dock="Right" Text="&#xE70D;" FontFamily="$FontIcons" FontSize="12" VerticalAlignment="Center" Foreground="$($Theme.sub)"/>
    <TextBlock DockPanel.Dock="Left" Text="$icon" FontFamily="$FontIcons" FontSize="18" Width="40" VerticalAlignment="Center" Foreground="$($Theme.fg)"/>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="$title" FontSize="13.5" Foreground="$($Theme.fg)"/>
      <TextBlock Text="$sub" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,2,0,0"/>
    </StackPanel>
  </DockPanel>
</Border>
<StackPanel x:Name="$($name)Body" Visibility="Collapsed">$body</StackPanel>
"@
}

# The mini taskbar picture on a Look tile: bare initials rings, or one ring with two text lines.
function New-MiniRingXaml([string]$name, [string]$letter) {
  "<Grid Width=`"30`" Height=`"30`" Margin=`"0,0,8,0`"><Ellipse Stroke=`"$($Theme.ring)`" StrokeThickness=`"3.5`"/><Path x:Name=`"$name`" StrokeThickness=`"3.5`"/><TextBlock Text=`"$letter`" FontSize=`"10.5`" FontWeight=`"SemiBold`" Foreground=`"$($Theme.fg)`" HorizontalAlignment=`"Center`" VerticalAlignment=`"Center`"/></Grid>"
}
function New-TileXaml([string]$key, [string]$title, [string]$sub, [string]$mini) {
@"
<RadioButton x:Name="Lk_$key" Style="{DynamicResource Tile}" GroupName="look">
  <StackPanel>
    <StackPanel Orientation="Horizontal" Height="34" Margin="0,0,0,12">$mini</StackPanel>
    <TextBlock Text="$title" FontSize="14" FontWeight="SemiBold" Foreground="$($Theme.fg)"/>
    <TextBlock Text="$sub" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap"/>
  </StackPanel>
</RadioButton>
"@
}
function New-MiniText([string]$l1, [string]$l2) {
  "<StackPanel VerticalAlignment=`"Center`"><TextBlock Text=`"$l1`" FontSize=`"12`" FontWeight=`"SemiBold`" Foreground=`"$($Theme.fg)`"/><TextBlock Text=`"$l2`" FontSize=`"11`" Foreground=`"$($Theme.sub)`"/></StackPanel>"
}

function New-NavXaml([string]$key, [string]$icon, [string]$title) {
@"
<RadioButton x:Name="Tab_$key" Style="{DynamicResource NavItem}" GroupName="tabs">
  <StackPanel Orientation="Horizontal">
    <TextBlock Text="$icon" FontFamily="$FontIcons" FontSize="16" Width="22" VerticalAlignment="Center"/>
    <TextBlock Text="$title" Margin="12,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</RadioButton>
"@
}

$sw = { param($name) "<ToggleButton x:Name=`"$name`" Style=`"{DynamicResource Switch}`"/>" }
$cb = { param($name) "<ComboBox x:Name=`"$name`" Style=`"{DynamicResource Combo}`"/>" }
$tbx = { param($name, $w) "<TextBox x:Name=`"$name`" Width=`"$w`" FontSize=`"13`" TextAlignment=`"Center`"/>" }
$moreTaskbar = (New-OptXaml 'Size' 'The rings and the text next to them scale together.' 'Sz' @('compact:Compact', 'normal:Normal', 'large:Large')) +
  (New-OptXaml 'Inside the ring' "Each account's initials are set under Accounts." 'In' @('none:Nothing', 'initials:Initials', 'percent:Percentage')) +
  (New-OptXaml 'Beside the ring' "Usage and reset reads '14%' over 'W 12pm'. Caption is 5h / 7d (renamed under General)." 'Nx' @('none:Nothing', 'caption:Caption', 'percent:Percentage', 'usage:Usage and reset', 'resetin:Reset in', 'resetat:Reset day + time')) +
  (New-OptXaml 'Account names' 'Left puts the name in front of the usage text in the Detailed look.' 'Nm' @('left:Left', 'right:Right', 'hidden:Hidden')) +
  (New-OptXaml 'Spacing' "The gap between accounts and between an account's rings." 'Sp' @('tight:Tight', 'normal:Normal', 'wide:Wide')) +
  (New-SettingXaml '&#xE7C9;' 'Dividers' 'A thin line between the accounts on the taskbar.' (& $sw 'Sw_dividers')) +
  (New-OptXaml 'Dual ring' 'For accounts shown as one dial (set under Accounts > Rings).' 'Iw' @('5h:5h inside, 7d outside', '7d:7d inside, 5h outside'))
$moreList = (New-SettingXaml '&#xE7B3;' 'Animations' 'Fade and slide the list in and out.' (& $sw 'Sw_anim'))
$moreGeneral = (New-SettingXaml '&#xE8D2;' 'Rename the windows' 'The captions used beside the rings and in the list.' ((& $tbx 'Cap_5h' 56) + (& $tbx 'Cap_7d' 56) + (& $tbx 'Cap_fable' 70))) +
  (New-SettingXaml '&#xE8A5;' 'Open the config file' 'config.json in your user profile, in Notepad.' '<Button x:Name="OpenCfgBtn" Style="{DynamicResource TextBtn}" Content="Open"/>') +
  (New-SettingXaml '&#xE777;' 'Reset settings' 'Back to the defaults. Your accounts stay.' '<StackPanel x:Name="ResetAsk" Orientation="Horizontal" Visibility="Collapsed"><Button x:Name="ResetNo" Style="{DynamicResource TextBtn}" Content="Keep"/><Button x:Name="ResetYes" Style="{DynamicResource AccentBtn}" Content="Reset"/></StackPanel><Button x:Name="ResetBtn" Style="{DynamicResource TextBtn}" Content="Reset"/>')

[xml]$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage Widget settings" Width="780" Height="610" MinWidth="640" MinHeight="480"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize" ShowInTaskbar="True"
        Background="$($Theme.win)" UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" TextElement.Foreground="$($Theme.fg)">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="210"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <DockPanel Grid.Column="0" Margin="10,10,10,14">
      <TextBlock x:Name="SVersion" DockPanel.Dock="Bottom" FontSize="12" Foreground="$($Theme.sub)" Margin="14,0,0,0"/>
      <StackPanel>
        $(New-NavXaml 'task' '&#xE7F4;' 'Taskbar')
        $(New-NavXaml 'list' '&#xE8FD;' 'Usage list')
        $(New-NavXaml 'acct' '&#xE716;' 'Accounts')
        $(New-NavXaml 'gen' '&#xE713;' 'General')
      </StackPanel>
    </DockPanel>
    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="26,18,28,24">
        <DockPanel Margin="0,0,0,16">
          <StackPanel x:Name="PageActions" DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed">
            <Button x:Name="FindBtn" Style="{DynamicResource TextBtn}" Content="Find accounts"/>
            <Button x:Name="AddBtn" Style="{DynamicResource AccentBtn}" Content="Add account"/>
          </StackPanel>
          <TextBlock x:Name="PageTitle" FontSize="26" FontWeight="SemiBold" Foreground="$($Theme.fg)"/>
        </DockPanel>
        <StackPanel x:Name="PanTask">
          <Border Background="$($Theme.tb)" BorderBrush="$($Theme.rowline)" BorderThickness="1" CornerRadius="6" Padding="16,10,16,12" Margin="0,0,0,18">
            <StackPanel>
              <TextBlock Text="Preview" FontSize="12" Foreground="$($Theme.sub)" Margin="0,0,0,6"/>
              <WrapPanel x:Name="PrevGroups"/>
            </StackPanel>
          </Border>
          <DockPanel Margin="0,0,0,8">
            <TextBlock x:Name="LookCustom" DockPanel.Dock="Right" Text="Custom: set under More options" FontSize="12" Foreground="$($Theme.sub)" VerticalAlignment="Bottom" Visibility="Collapsed"/>
            <TextBlock Text="Look" FontSize="15" FontWeight="SemiBold" Foreground="$($Theme.fg)"/>
          </DockPanel>
          <UniformGrid Columns="3" Margin="0,0,-10,16">
            $(New-TileXaml 'minimal' 'Minimal' 'Rings and initials' ((New-MiniRingXaml 'TR_minimal_0' 'X') + (New-MiniRingXaml 'TR_minimal_1' 'Nj') + (New-MiniRingXaml 'TR_minimal_2' 'F')))
            $(New-TileXaml 'balanced' 'Balanced' 'Plus usage and reset' ((New-MiniRingXaml 'TR_balanced_0' 'X') + (New-MiniText '14%' 'W 12pm')))
            $(New-TileXaml 'detailed' 'Detailed' 'Plus names, larger' ((New-MiniRingXaml 'TR_detailed_0' 'X') + (New-MiniText 'XNDR' "14% $DOT W 12pm")))
          </UniformGrid>
          $(New-SettingXaml '&#xE916;' 'Show the 5-hour window' '' ('<TextBlock x:Name="Show5Text" FontSize="13" Foreground="' + $Theme.fg + '" VerticalAlignment="Center" Margin="0,0,10,0"/>' + (& $sw 'Sw_show5h')) 'Show5Sub')
          $(New-SettingXaml '&#xE7BA;' 'Accounts at their limit' '' (& $cb 'Cb_atLimit') 'AtLimitSub')
          $(New-FoldXaml 'More' '&#xE790;' 'More options' 'Size, text beside the ring, names, spacing, dividers' $moreTaskbar)
        </StackPanel>
        <StackPanel x:Name="PanList">
          $(New-SettingXaml '&#xE7BA;' 'Accounts at their limit' 'Group them at the bottom with their back time, or keep each in place with its bars.' (& $cb 'Cb_listLimited'))
          $(New-SettingXaml '&#xE8FD;' 'Fable rows' 'Fable is a separate weekly limit. Show a row always, only when the account has used it, or never.' (& $cb 'Cb_listFable'))
          $(New-SettingXaml '&#xE8EC;' 'Plan labels' 'The plan chip (Ultra, Max 20x) beside each account name.' (& $sw 'Sw_listPlan'))
          $(New-FoldXaml 'ListMore' '&#xE790;' 'More options' 'Animations' $moreList)
        </StackPanel>
        <StackPanel x:Name="PanAcct">
          <TextBlock x:Name="AcctMsg" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
          <StackPanel x:Name="AcctTools"/>
          <StackPanel x:Name="SNewAcctBox"/>
          <StackPanel x:Name="SList" Margin="0,2,0,0"/>
          <TextBlock Text="Drag the grip (or press Alt+Up / Alt+Down on a row) to reorder. Removing an account only removes it from the widget; your Claude login stays." FontSize="11.5" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="2,10,2,0"/>
        </StackPanel>
        <StackPanel x:Name="PanGen">
          $(New-SettingXaml '&#xE777;' 'Refresh every' 'How often the usage is read.' (& $cb 'Cb_refresh'))
          $(New-SettingXaml '&#xE916;' 'Time format' 'How reset times are written.' (& $cb 'Cb_timeFormat'))
          $(New-SettingXaml '&#xE7E8;' 'Start with Windows' 'Open the widget when you sign in.' (& $sw 'Sw_startup'))
          $(New-SettingXaml '&#xE895;' 'Check for updates daily' '' ('<Button x:Name="UpdCheckBtn" Style="{DynamicResource TextBtn}" Content="Check now"/>' + (& $sw 'Sw_updates')) 'UpdMsg')
          <Grid x:Name="UpdBar" Height="6" Visibility="Collapsed" Margin="0,0,0,10">
            <Border Background="$($Theme.bar)" CornerRadius="3"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition x:Name="UpdC1" Width="0*"/><ColumnDefinition x:Name="UpdC2" Width="100*"/></Grid.ColumnDefinitions>
              <Border Background="$($Colors.accent)" CornerRadius="3"/>
            </Grid>
          </Grid>
          <TextBlock x:Name="UpdNotesS" FontSize="12" Foreground="$($Theme.sub)" TextWrapping="Wrap" Margin="2,0,0,8" Visibility="Collapsed"/>
          <Button x:Name="UpdInstallBtn" Style="{DynamicResource AccentBtn}" Content="Install update" HorizontalAlignment="Left" Margin="0,0,0,12" Visibility="Collapsed"/>
          $(New-FoldXaml 'GenMore' '&#xE790;' 'More options' 'Rename the windows, open the config file, reset settings' $moreGeneral)
        </StackPanel>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
"@
$settings = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $settingsXaml))
$settings.Resources.MergedDictionaries.Add($PopupEls.Card.Resources)
$SettingsNames = @('SVersion', 'Tab_task', 'Tab_list', 'Tab_acct', 'Tab_gen', 'PageActions', 'FindBtn', 'AddBtn', 'PageTitle', 'PanTask', 'PanList', 'PanAcct', 'PanGen',
  'PrevGroups', 'LookCustom', 'Lk_minimal', 'Lk_balanced', 'Lk_detailed', 'Show5Text', 'Sw_show5h', 'Show5Sub', 'Cb_atLimit', 'AtLimitSub',
  'MoreHead', 'MoreBody', 'MoreChev', 'ListMoreHead', 'ListMoreBody', 'ListMoreChev', 'GenMoreHead', 'GenMoreBody', 'GenMoreChev',
  'Sz_compact', 'Sz_normal', 'Sz_large', 'In_none', 'In_initials', 'In_percent', 'Nx_none', 'Nx_caption', 'Nx_percent', 'Nx_usage', 'Nx_resetin', 'Nx_resetat',
  'Nm_left', 'Nm_right', 'Nm_hidden', 'Sp_tight', 'Sp_normal', 'Sp_wide', 'Sw_dividers', 'Iw_5h', 'Iw_7d',
  'Cb_listLimited', 'Cb_listFable', 'Sw_listPlan', 'Sw_anim', 'AcctMsg', 'AcctTools', 'SNewAcctBox', 'SList',
  'Cb_refresh', 'Cb_timeFormat', 'Sw_startup', 'Sw_updates', 'UpdCheckBtn', 'UpdMsg', 'UpdBar', 'UpdC1', 'UpdC2', 'UpdNotesS', 'UpdInstallBtn',
  'Cap_5h', 'Cap_7d', 'Cap_fable', 'OpenCfgBtn', 'ResetAsk', 'ResetNo', 'ResetYes', 'ResetBtn',
  'TR_minimal_0', 'TR_minimal_1', 'TR_minimal_2', 'TR_balanced_0', 'TR_detailed_0')
foreach ($n in $SettingsNames) {
  $el = $settings.FindName($n)
  if (-not $el) { throw "settings control missing: $n" }
  $PopupEls[$n] = $el
}
$settingsIcon = Join-Path $PSScriptRoot 'assets\icon.ico'
if (Test-Path $settingsIcon) { try { $settings.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $settingsIcon)) } catch {} }
$PopupEls.SVersion.Text = "Version $AppVersion"
$script:tab = 'task'          # Settings page: task | list | acct | gen
$script:expanded = $null      # account whose details are open in the Accounts page
$script:newAccts = @()        # accounts found on this PC that the widget doesn't have and wasn't told to ignore
$script:findAuto = $false
$script:lastFind = [DateTime]::MinValue

# One window row in the list: caption 40 | bar * (6 high) | pct 40 right | reset 78 right. The reset is left out when it
# equals the row above (Fable usually resets with 7d); a 0% row is dimmer; within an hour the reset text turns bright.
function Get-WindowRowXaml($key, $win, [string]$prevReset) {
  $pct = $win.pct
  $p = if ($null -ne $pct) { [Math]::Max(0, [Math]::Min(100, [double]$pct)) } else { 0 }
  $zero = ($null -ne $pct -and [Math]::Round([double]$pct) -eq 0)
  $pctText = if ($null -ne $pct) { "$(Format-Pct $pct)%" } else { $DASH }
  $rs = if ($win -and $win.reset) { Get-Reset $win.reset } else { '' }
  $soon = $false
  if ($win -and $win.reset) { $left = (ConvertTo-LocalTime $win.reset) - (Get-Date); $soon = $left.TotalMinutes -gt 0 -and $left.TotalMinutes -lt 60 }
  $resetXaml = ''
  if ($rs -and $rs -ne $prevReset) {
    $c = if ($soon) { $Theme.fg } else { $Theme.sub }
    $resetXaml = "<StackPanel Grid.Column=`"3`" Orientation=`"Horizontal`" HorizontalAlignment=`"Right`" VerticalAlignment=`"Center`"><TextBlock Text=`"&#xE81C;`" FontFamily=`"$FontIcons`" FontSize=`"10`" Foreground=`"$c`" VerticalAlignment=`"Center`" Margin=`"0,1,5,0`"/><TextBlock Text=`"$(Esc $rs)`" FontSize=`"11.5`" Foreground=`"$c`"/></StackPanel>"
  }
  $tip = if ($win -and $win.reset) { " ToolTip=`"$(Esc (Get-ResetLong $win.reset))`"" } else { '' }
  $row = @"
<Border Padding="4,3" Margin="0,1" CornerRadius="6" Background="Transparent"$tip>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="78"/></Grid.ColumnDefinitions>
    <TextBlock Text="$(Esc (Get-Caption $key))" FontSize="12" Foreground="$($Theme.sub)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    <Grid Grid.Column="1" Height="6" VerticalAlignment="Center" Margin="0,0,10,0">
      <Border Background="$($Theme.bar)" CornerRadius="3"/>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="$($p)*"/><ColumnDefinition Width="$(100 - $p)*"/></Grid.ColumnDefinitions>
        <Border Background="$(Get-UsageColor $pct)" CornerRadius="3"/>
      </Grid>
    </Grid>
    <TextBlock Grid.Column="2" Text="$pctText" FontSize="12.5" FontWeight="$(if ($zero) { 'Normal' } else { 'SemiBold' })" Foreground="$(if ($zero) { $Theme.sub } else { $Theme.fg })" TextAlignment="Right" VerticalAlignment="Center" FontFamily="Segoe UI Variable Text, Segoe UI"/>
    $resetXaml
  </Grid>
</Border>
"@
  return [pscustomobject]@{ xaml = $row; reset = $rs }
}

# The windows the list shows for an account: 5h when it has one (and 5h is on), 7d, and Fable per the list setting.
function Get-ListKeys($cfg, $res) {
  $keys = @()
  if (@(Get-ShownLimits $cfg $res) -contains '5h') { $keys += '5h' }
  $keys += '7d'
  $lf = "$($script:config.listFable)"
  $f = Get-Win $res 'fable'
  if ($lf -eq 'always' -or ($lf -ne 'never' -and $f -and $null -ne $f.pct)) { $keys += 'fable' }
  return $keys
}

# Problem states replace an account's rows with one line: a warning glyph and what to do.
function Get-ProblemText($res) {
  if (-not $res) { return $(if ($script:job) { "Loading$ELL" } else { '' }) }
  switch ($res.status) {
    'expired' { 'Login expired: open Claude Code to renew it' }
    'invalid' { if ($res.error) { $res.error } else { 'Token invalid' } }
    'error'   { if ($res.error) { $res.error } else { 'Could not read usage' } }
    default   { '' }
  }
}

# One account in the list: name + plan chip, then a window row per shown window (or one problem line).
function New-ListBlock($cfg) {
  $res = Get-Result $cfg.name
  $plan = Get-Plan $cfg $res
  $chip = if ($plan -and $script:config.listPlan -ne $false) { "<Border Background=`"$($Theme.chip)`" CornerRadius=`"4`" Padding=`"6,1,6,2`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"$(Esc $plan)`" FontSize=`"10.5`" Foreground=`"$($Theme.sub)`"/></Border>" } else { '' }
  $problem = Get-ProblemText $res
  $rows = ''
  if ($problem) {
    $c = if ($res) { $Colors.warn } else { $Theme.sub }
    $glyph = if ($res) { "<TextBlock Text=`"&#xE7BA;`" FontFamily=`"$FontIcons`" FontSize=`"13`" Foreground=`"$($Colors.warn)`" Margin=`"0,1,8,0`" VerticalAlignment=`"Top`"/>" } else { '' }
    $rows = "<StackPanel Orientation=`"Horizontal`" Margin=`"4,4,0,2`">$glyph<TextBlock Text=`"$(Esc $problem)`" FontSize=`"12`" Foreground=`"$($Theme.sub)`" TextWrapping=`"Wrap`" MaxWidth=`"320`"/></StackPanel>"
  } else {
    $prev = ''
    foreach ($k in (Get-ListKeys $cfg $res)) {
      $r = Get-WindowRowXaml $k (Get-Win $res $k) $prev
      $rows += $r.xaml
      if ($r.reset) { $prev = $r.reset }
    }
  }
  $block = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Margin="0,0,0,8">
  <StackPanel Orientation="Horizontal" Margin="4,4,0,3">
    <TextBlock Text="$(Esc (Get-Label $cfg))" FontSize="13" FontWeight="SemiBold" Foreground="$($Theme.fg)" TextTrimming="CharacterEllipsis" MaxWidth="240"/>
    $chip
  </StackPanel>
  <StackPanel Name="Rows">$rows</StackPanel>
</StackPanel>
"@)
  foreach ($r in $block.FindName('Rows').Children) {
    if ($r -is [Windows.Controls.Border]) {
      $r.Add_MouseEnter({ param($s) $s.Background = $Theme.hover })
      $r.Add_MouseLeave({ param($s) $s.Background = 'Transparent' })
    }
  }
  $via = switch ($res.method) { 'usage-api' { 'Read via the usage API (free)' } 'probe' { 'Read via a 1-token probe (setup-tokens cannot use the usage API)' } default { $null } }
  $planVia = if ($res.apiPlan) { 'Plan read from the API' } elseif ($res -and $cfg.plan) { "Plan set in settings (the API doesn't report it for this token)" }
  $tipLines = @($via, $planVia) | Where-Object { $_ }
  if ($tipLines) { $block.ToolTip = $tipLines -join "`n" }
  return $block
}

# An at-limit account in the group: a small red ring, the name, and "Back Su 1am".
function New-LimitedRow($cfg) {
  $res = Get-Result $cfg.name
  $b = Get-BackAt $res
  $back = if ($b) { Get-Reset $b } else { $DASH }
  [Windows.Markup.XamlReader]::Parse(@"
<Grid $ns Margin="4,3,4,3">
  <Ellipse Width="13" Height="13" Stroke="$($Colors.bad)" StrokeThickness="2.4" HorizontalAlignment="Left" VerticalAlignment="Center"/>
  <TextBlock Text="$(Esc (Get-Label $cfg))" FontSize="13" Foreground="$($Theme.fg)" Margin="24,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="200" HorizontalAlignment="Left"/>
  <TextBlock HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="12" Foreground="$($Theme.sub)"><Run Text="Back "/><Run Text="$(Esc $back)" FontWeight="SemiBold" Foreground="$($Theme.fg)"/></TextBlock>
</Grid>
"@)
}

# One account in Settings > Accounts: grip, a small ring of its tightest window, name, plan chip, what it shows, the
# taskbar switch and a chevron; the open row also has name, initials, plan, rings, shown windows and Remove.
function New-AccountSettingsRow($cfg, $shownNames) {
  $res = Get-Result $cfg.name
  $open = $script:expanded -eq $cfg.name
  $plan = Get-Plan $cfg $res
  $limited = Test-Limited $res
  $t = Get-Tightest $cfg $res
  $keys = @(Get-ShownLimits $cfg $res)
  $summary = if ($limited) {
    $b = Get-BackAt $res
    "<TextBlock Text=`"At limit$(if ($b) { ', back ' + (Get-Reset $b) })`" FontSize=`"12.5`" Foreground=`"$($Colors.bad)`" VerticalAlignment=`"Center`"/>"
  } else {
    "<TextBlock Text=`"$(Esc (($keys | ForEach-Object { Get-Caption $_ }) -join " $DOT "))`" FontSize=`"12.5`" Foreground=`"$($Theme.sub)`" VerticalAlignment=`"Center`"/>"
  }
  $chip = if ($plan) { "<Border Background=`"$($Theme.chip)`" CornerRadius=`"4`" Padding=`"7,2,7,3`" Margin=`"12,0,14,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"$(Esc $plan)`" FontSize=`"11.5`" Foreground=`"$($Theme.sub)`"/></Border>" } else { '<Border Width="14"/>' }
  # Plan list: Auto (shows what the API reports) plus the fixed choices, plus a custom plan from the config so it isn't lost.
  $planOpts = @('') + $PlanChoices
  $curPlan = "$($cfg.plan)".Trim()
  if ($curPlan -and $PlanChoices -notcontains $curPlan) { $planOpts += $curPlan }
  $lacks5 = Test-LacksFiveH $res
  $combined = $cfg.style -eq 'combined'
  $planApi = if ($res.apiPlan) { 'Plan read from the API.' } elseif ($res) { "The API doesn't report this plan: pick it here." } else { '' }
  $via = switch ($res.method) { 'usage-api' { 'Read with the usage API (free)' } 'probe' { 'Read with a 1-token probe (setup token)' } default { '' } }
  $limitChecks = ($LimitKeys | ForEach-Object {
    $dis = if ($_ -eq '5h' -and ($lacks5 -or $script:config.show5h -eq $false)) { ' IsEnabled="False"' } else { '' }
    "<CheckBox x:Name=`"L_$_`" Content=`"$(Esc (Get-Caption $_))`" Margin=`"0,0,16,0`" VerticalAlignment=`"Center`"$dis/>"
  }) -join ''
  $row = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,0">
  <Border x:Name="Head" Background="$($Theme.row)" BorderBrush="$($Theme.rowline)" BorderThickness="0,0,0,1" Padding="10,12,14,12" AllowDrop="True" Cursor="Arrow">
    <DockPanel Background="Transparent">
      <TextBlock x:Name="Chev" DockPanel.Dock="Right" Text="$(if ($open) { '&#xE70E;' } else { '&#xE70D;' })" FontFamily="$FontIcons" FontSize="12" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="14,0,0,0" Cursor="Hand"/>
      <ToggleButton x:Name="Tb" DockPanel.Dock="Right" Style="{DynamicResource Switch}" VerticalAlignment="Center" ToolTip="Show this account on the taskbar"/>
      <TextBlock x:Name="Grip" DockPanel.Dock="Left" Text="&#xE76F;" FontFamily="$FontIcons" FontSize="14" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="0,0,8,0" Cursor="SizeAll" ToolTip="Drag to reorder"/>
      <Grid DockPanel.Dock="Left" Width="18" Height="18" VerticalAlignment="Center" Margin="0,0,12,0"><Ellipse Stroke="$($Theme.ring)" StrokeThickness="2.6"/><Path x:Name="Ring" StrokeThickness="2.6"/></Grid>
      <TextBlock DockPanel.Dock="Left" Text="$(Esc (Get-Label $cfg))" FontSize="14" FontWeight="SemiBold" Foreground="$($Theme.fg)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="170"/>
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">$chip$summary</StackPanel>
      <Border/>
    </DockPanel>
  </Border>
  <Border x:Name="Det" Visibility="$(if ($open) { 'Visible' } else { 'Collapsed' })" Background="$($Theme.row)" BorderBrush="$($Theme.rowline)" BorderThickness="0,0,0,1" Padding="46,4,14,14">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="72"/><ColumnDefinition Width="*"/><ColumnDefinition Width="20"/><ColumnDefinition Width="64"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Grid.Column="0" Text="Name" FontSize="12.5" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <TextBox x:Name="Label" Grid.Row="0" Grid.Column="1" Margin="0,4,0,4" Padding="2,3"/>
      <TextBlock Grid.Row="0" Grid.Column="3" Text="Initials" FontSize="12.5" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <Grid Grid.Row="0" Grid.Column="4" Margin="0,4,0,4"><TextBox x:Name="Short" MaxLength="2" Padding="2,3"/><TextBlock x:Name="ShortHint" Foreground="$($Theme.sub)" FontSize="12.5" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/></Grid>
      <TextBlock Grid.Row="1" Grid.Column="0" Text="Plan" FontSize="12.5" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <ComboBox x:Name="Plan" Grid.Row="1" Grid.Column="1" Style="{DynamicResource Combo}" Margin="0,4,0,4" ToolTip="$(Esc $planApi)"/>
      <TextBlock Grid.Row="1" Grid.Column="3" Text="Rings" FontSize="12.5" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <ComboBox x:Name="Rings" Grid.Row="1" Grid.Column="4" Style="{DynamicResource Combo}" Margin="0,4,0,4"/>
      <TextBlock Grid.Row="2" Grid.Column="0" Text="Show" FontSize="12.5" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
      <StackPanel Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,6,0,6">$limitChecks<TextBlock x:Name="No5" FontSize="11.5" Foreground="$($Theme.sub)" VerticalAlignment="Center"/></StackPanel>
      <DockPanel Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="5" Margin="0,6,0,0">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <StackPanel x:Name="DelConfirm" Orientation="Horizontal" Visibility="Collapsed">
            <Button x:Name="DelYes" Style="{DynamicResource TextBtn}" Content="Remove"/>
            <Button x:Name="DelNo" Style="{DynamicResource TextBtn}" Content="Keep"/>
          </StackPanel>
          <Button x:Name="Dn" Style="{DynamicResource IconBtn}" Content="&#xE74B;" ToolTip="Move down"/>
          <Button x:Name="Up" Style="{DynamicResource IconBtn}" Content="&#xE74A;" ToolTip="Move up"/>
          <Button x:Name="Del" Style="{DynamicResource LinkBtn}" Content="Remove from widget" ToolTip="Removes it from the widget only; your Claude login is untouched"/>
        </StackPanel>
        <TextBlock Text="$(Esc $via)" FontSize="12" Foreground="$($Theme.sub)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Grid>
  </Border>
</StackPanel>
"@)
  $name = $cfg.name
  $shortAuto = (Get-Shorts)[$name]
  Set-Ring ($row.FindName('Ring')) $t.win.pct 18 2.6
  $tb = $row.FindName('Tb'); $tb.IsChecked = $shownNames -contains $name; $tb.Tag = $name
  $tb.Add_Click({ param($s) Set-Taskbar $s.Tag ([bool]$s.IsChecked) $s })
  $head = $row.FindName('Head'); $head.Tag = $name
  $head.Add_MouseLeftButtonUp({ param($s, $e)
    if ($e.OriginalSource -is [Windows.Controls.Primitives.ToggleButton] -or $e.Handled) { return }
    $script:expanded = if ($script:expanded -eq $s.Tag) { '' } else { $s.Tag }
    Update-Settings
  })
  # Drag the grip onto another row to reorder; Alt+Up / Alt+Down moves the row; the arrows in the open row do the same.
  $grip = $row.FindName('Grip'); $grip.Tag = $name
  $grip.Add_PreviewMouseMove({ param($s, $e) if ($e.LeftButton -eq 'Pressed' -and -not $script:dragging) { $script:dragging = $true; try { [void][Windows.DragDrop]::DoDragDrop($s, [string]$s.Tag, [Windows.DragDropEffects]::Move) } finally { $script:dragging = $false } } })
  $head.Add_Drop({ param($s, $e) $from = [string]$e.Data.GetData([string]); if ($from -and $from -ne $s.Tag) { Move-AccountTo $from $s.Tag } })
  $row.Tag = $name
  $row.Add_PreviewKeyDown({ param($s, $e)
    if (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Alt) -and $e.SystemKey -in 'Up', 'Down') {
      $e.Handled = $true; Move-Account $s.Tag $(if ($e.SystemKey -eq 'Up') { -1 } else { 1 })
    }
  })
  $vis = @(Get-Visible | ForEach-Object name)
  $at = [array]::IndexOf($vis, $name)
  $up = $row.FindName('Up'); $up.Tag = $name; $up.IsEnabled = $at -gt 0; $up.Add_Click({ param($s) Move-Account $s.Tag -1 })
  $dn = $row.FindName('Dn'); $dn.Tag = $name; $dn.IsEnabled = $at -ge 0 -and $at -lt $vis.Count - 1; $dn.Add_Click({ param($s) Move-Account $s.Tag 1 })
  $del = $row.FindName('Del'); $del.Tag = $row
  $del.Add_Click({ param($s) $s.Visibility = 'Collapsed'; $s.Tag.FindName('DelConfirm').Visibility = 'Visible' })
  $no = $row.FindName('DelNo'); $no.Tag = $row
  $no.Add_Click({ param($s) $s.Tag.FindName('DelConfirm').Visibility = 'Collapsed'; $s.Tag.FindName('Del').Visibility = 'Visible' })
  $yes = $row.FindName('DelYes'); $yes.Tag = $name; $yes.Add_Click({ param($s) Remove-Account $s.Tag })
  $lb = $row.FindName('Label'); $lb.Text = "$(Get-Label $cfg)"; $lb.Tag = $name
  $lb.Add_TextChanged({ param($s) Set-AcctProp $s.Tag 'label' $s.Text; Save-UiConfig; Update-Widget })
  $sb = $row.FindName('Short'); $sb.Text = "$($cfg.short)"; $sb.Tag = $name
  $hint = $row.FindName('ShortHint'); $hint.Text = "$shortAuto (auto)"; $hint.Visibility = if ($sb.Text) { 'Collapsed' } else { 'Visible' }; $sb.Tag = @{ name = $name; hint = $hint }
  $sb.Add_TextChanged({ param($s) $s.Tag.hint.Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' }; Set-AcctProp $s.Tag.name 'short' $s.Text.Trim(); Save-UiConfig; Update-Widget })
  $pc = $row.FindName('Plan'); $autoText = if ($res.apiPlan) { "Auto: $($res.apiPlan)" } else { 'Auto' }
  for ($i = 0; $i -lt $planOpts.Count; $i++) { [void]$pc.Items.Add((New-Object Windows.Controls.ComboBoxItem -Property @{ Content = $(if ($planOpts[$i]) { $planOpts[$i] } else { $autoText }); Tag = $planOpts[$i] })) }
  $pc.SelectedIndex = [Math]::Max(0, [array]::IndexOf($planOpts, $curPlan)); $pc.Tag = $name
  $pc.Add_SelectionChanged({ param($s) if ($s.IsLoaded -and $s.SelectedItem) { Set-AcctProp $s.Tag 'plan' $s.SelectedItem.Tag; Save-UiConfig; Update-Widget; Update-Popup -ListOnly } })
  $rc = $row.FindName('Rings')
  foreach ($o in @(@('separate', 'Separate rings'), @('5h', '5h inside 7d'), @('7d', '7d inside 5h'))) { [void]$rc.Items.Add((New-Object Windows.Controls.ComboBoxItem -Property @{ Content = $o[1]; Tag = $o[0] })) }
  $rc.SelectedIndex = if (-not $combined) { 0 } elseif ((Get-PieKey $cfg) -eq '5h') { 1 } else { 2 }
  $rc.Tag = $name
  if ($lacks5) { $rc.SelectedIndex = 0; $rc.IsEnabled = $false; $row.FindName('No5').Text = 'No 5-hour window on this account' }
  $rc.Add_SelectionChanged({ param($s)
    if (-not $s.IsLoaded -or -not $s.SelectedItem) { return }
    $v = $s.SelectedItem.Tag
    Set-AcctProp $s.Tag 'style' $(if ($v -eq 'separate') { 'rings' } else { 'combined' })
    if ($v -ne 'separate') { Set-AcctProp $s.Tag 'pie' $v }
    Save-UiConfig; Update-Widget
  })
  $limits = @(Get-TaskbarLimits $cfg)
  foreach ($k in $LimitKeys) {
    $c = $row.FindName("L_$k"); $c.IsChecked = $limits -contains $k; $c.Tag = "$name|$k"
    $c.Add_Click({ param($s) $n, $key = $s.Tag -split '\|', 2; Set-Limit $n $key ([bool]$s.IsChecked) $s })
  }
  return $row
}

function Update-RefreshButton {
  $cd = Get-Cooldown
  $PopupEls.RefreshBtn.IsEnabled = -not $script:job -and $cd -eq 0
  $PopupEls.RefreshBtn.ToolTip = if ($script:job) { "Refreshing$ELL" } elseif ($cd) { "You can refresh again in ${cd}s" } else { 'Refresh now' }
}

# "(dot) 4 available   (dot) 3 at limit" under the header (hidden with a single account).
function Update-Summary($avail, $limited, $total) {
  $s = $PopupEls.Summary
  $s.Children.Clear()
  $s.Visibility = if ($total -gt 1) { 'Visible' } else { 'Collapsed' }
  foreach ($p in @(@($avail, 'available', $Colors.ok), @($limited, 'at limit', $Colors.bad))) {
    if ($p[1] -eq 'at limit' -and -not $p[0]) { continue }
    [void]$s.Children.Add([Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Orientation="Horizontal" Margin="0,0,16,0">
  <Ellipse Width="7" Height="7" Fill="$($p[2])" Margin="0,1,7,0"/>
  <TextBlock FontSize="12" Foreground="$($Theme.sub)"><Run Text="$($p[0])" FontWeight="SemiBold" Foreground="$($Theme.fg)"/><Run Text=" $($p[1])"/></TextBlock>
</StackPanel>
"@))
  }
}

# The "At limit 3" group under the list: a hairline, the header (click to fold), one row per account with its back time.
function Update-LimitedBox($limited) {
  $box = $PopupEls.LimitedBox
  $box.Children.Clear()
  $limited = @($limited | Where-Object { $_ })
  if (-not $limited.Count) { return }
  $open = $script:state.limitedOpen -ne $false
  $head = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns BorderBrush="$($Theme.border)" BorderThickness="0,1,0,0" Margin="0,2,0,0" Padding="4,10,4,4" Background="Transparent" Cursor="Hand">
  <DockPanel>
    <TextBlock DockPanel.Dock="Right" Text="$(if ($open) { '&#xE70E;' } else { '&#xE70D;' })" FontFamily="$FontIcons" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center"/>
    <TextBlock FontSize="13"><Run Text="At limit" FontWeight="SemiBold" Foreground="$($Theme.fg)"/><Run Text="  $(@($limited).Count)" Foreground="$($Theme.sub)"/></TextBlock>
  </DockPanel>
</Border>
"@)
  $head.Add_MouseLeftButtonUp({ $script:state.limitedOpen = -not ($script:state.limitedOpen -ne $false); Save-State; Update-Popup -ListOnly })
  [void]$box.Children.Add($head)
  if ($open) { foreach ($c in @($limited)) { [void]$box.Children.Add((New-LimitedRow $c)) } }
}

# The account list (the popup). Settings is its own window: Update-Settings. Edit flows call this to refresh both;
# -ListOnly leaves an open Settings window alone (rebuilding it would take the focus from someone typing).
function Update-Popup([switch]$ListOnly) {
  Update-RefreshButton
  $PopupEls.Status.Text = if ($script:job) { if ($script:job.discover) { "Scanning for accounts$ELL" } else { "Refreshing$ELL" } }
    elseif ($script:lastError) { "Error: $($script:lastError)" }
    elseif ($script:configError) { $script:configError }
    elseif ($script:updated) { "Updated $(Format-ClockShort $script:updated (Get-TimeFormat)) $DOT every {0} min{1}" -f (Get-RefreshMinutes), $(if ($script:notice) { " $DOT $($script:notice)" }) }
    else { '' }
  $PopupEls.Status.Foreground = if (-not $script:job -and ($script:lastError -or $script:configError)) { $Colors.bad } else { $Theme.sub }

  $PopupEls.UpdBox.Visibility = if ($script:update) { 'Visible' } else { 'Collapsed' }
  Update-UpdateControls

  $PopupEls.List.Children.Clear()
  $cfgs = @(Get-Visible)
  $limitedAll = @($cfgs | Where-Object { Test-Limited (Get-Result $_.name) })
  # Grouped (default): limited accounts leave the blocks and sit under "At limit", soonest back first.
  $grouped = @()
  if ("$($script:config.listLimited)" -ne 'inline') { $grouped = @($limitedAll | Sort-Object { $b = Get-BackAt (Get-Result $_.name); if ($b) { $b.Ticks } else { [int64]::MaxValue } }) }
  $avail = @($cfgs | Where-Object { $n = $_.name; -not @($grouped | Where-Object name -eq $n).Count })
  foreach ($cfg in $avail) { [void]$PopupEls.List.Children.Add((New-ListBlock $cfg)) }
  if (-not $cfgs.Count) {
    $empty = New-Object Windows.Controls.TextBlock
    $empty.Text = if ($script:job) { "Looking for accounts$ELL" } else { 'No accounts found. Log in with Claude Code (run claude), then right-click the rings > Scan for accounts.' }
    $empty.Foreground = $Theme.sub; $empty.Margin = '4,8'; $empty.TextWrapping = 'Wrap'
    [void]$PopupEls.List.Children.Add($empty)
  }
  Update-Summary (@($cfgs).Count - $limitedAll.Count) $limitedAll.Count $cfgs.Count
  Update-LimitedBox $grouped
  Update-NewAcctBox
  # The how-to line is for newcomers: the first three times the list opens.
  $PopupEls.Footer.Text = "Ctrl+drag to move $DOT right-click for more"
  $PopupEls.Footer.Visibility = if ([int]$script:state.hintCount -lt 3) { 'Visible' } else { 'Collapsed' }
  if (-not $ListOnly -and $settings.IsVisible) { Update-Settings }
}

$PageNames = @{ task = 'PanTask'; list = 'PanList'; acct = 'PanAcct'; gen = 'PanGen' }
$PageTitles = @{ task = 'Taskbar'; list = 'Usage list'; acct = 'Accounts'; gen = 'General' }
$script:loadingSettings = $false

function Set-ComboItems($combo, $items, $selected) {
  $combo.Items.Clear()
  foreach ($it in $items) { [void]$combo.Items.Add((New-Object Windows.Controls.ComboBoxItem -Property @{ Content = $it[1]; Tag = $it[0] })) }
  $combo.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($items | ForEach-Object { "$($_[0])" }), "$selected"))
}

# The Settings window: the open page, and the value every control starts from. Handlers ignore changes made here ($script:loadingSettings).
function Update-Settings {
  $script:loadingSettings = $true
  try {
    foreach ($t in $PageNames.Keys) {
      $PopupEls[$PageNames[$t]].Visibility = if ($script:tab -eq $t) { 'Visible' } else { 'Collapsed' }
      $PopupEls["Tab_$t"].IsChecked = $script:tab -eq $t
    }
    $PopupEls.PageTitle.Text = $PageTitles[$script:tab]
    $PopupEls.PageActions.Visibility = if ($script:tab -eq 'acct') { 'Visible' } else { 'Collapsed' }

    # Taskbar
    $look = Get-LookKey
    foreach ($k in 'minimal', 'balanced', 'detailed') { $PopupEls["Lk_$k"].IsChecked = ($look -eq $k) }
    $PopupEls.LookCustom.Visibility = if ($look -eq 'custom') { 'Visible' } else { 'Collapsed' }
    $on5 = $script:config.show5h -ne $false
    $PopupEls.Sw_show5h.IsChecked = $on5
    $PopupEls.Show5Text.Text = if ($on5) { 'On' } else { 'Off' }
    $have = @(Get-Visible | Where-Object { Test-HasFiveH (Get-Result $_.name) } | ForEach-Object { Get-Label $_ })
    $PopupEls.Show5Sub.Text = if ($have.Count) { "Only accounts that have one: $($have -join ', ')" } else { 'None of your accounts has one now' }
    Set-ComboItems $PopupEls.Cb_atLimit @(@('group', 'Group'), @('show', 'Show'), @('hide', 'Hide')) (Get-AtLimitMode)
    $PopupEls.AtLimitSub.Text = switch (Get-AtLimitMode) { 'group' { 'One red ring with the count, until the first comes back' } 'show' { 'Each stays on the taskbar as a full red ring' } default { 'They leave the taskbar until their window resets' } }
    $PopupEls["Sz_$(Get-SizeKey)"].IsChecked = $true
    $PopupEls["In_$(Get-InsideMode)"].IsChecked = $true
    $PopupEls["Nx_$(Get-NextMode)"].IsChecked = $true
    $PopupEls["Nm_$(Get-NamesMode)"].IsChecked = $true
    $PopupEls["Sp_$(Get-SpacingKey)"].IsChecked = $true
    $PopupEls["Iw_$(Get-PieKey $null)"].IsChecked = $true
    $PopupEls.Sw_dividers.IsChecked = $script:config.showDividers -eq $true
    # Usage list
    Set-ComboItems $PopupEls.Cb_listLimited @(@('group', 'Group at the bottom'), @('inline', 'Keep in place')) $(if ("$($script:config.listLimited)" -eq 'inline') { 'inline' } else { 'group' })
    Set-ComboItems $PopupEls.Cb_listFable @(@('always', 'Always'), @('used', 'When used'), @('never', 'Never')) $(if ("$($script:config.listFable)" -in 'always', 'never') { "$($script:config.listFable)" } else { 'used' })
    $PopupEls.Sw_listPlan.IsChecked = $script:config.listPlan -ne $false
    $PopupEls.Sw_anim.IsChecked = Test-Option 'animations'
    # General
    $mins = @(5, 10, 15, 30, 60); $cur = Get-RefreshMinutes
    if ($mins -notcontains $cur) { $mins = @($mins + $cur | Sort-Object) }
    Set-ComboItems $PopupEls.Cb_refresh @($mins | ForEach-Object { , @($_, "$_ min") }) $cur
    Set-ComboItems $PopupEls.Cb_timeFormat @(@('12h', "12-hour (3pm)"), @('24h', '24-hour (15:00)')) (Get-TimeFormat)
    $PopupEls.Sw_startup.IsChecked = [bool](Test-Path $StartupLink)
    $PopupEls.Sw_updates.IsChecked = Test-Option 'updateCheck'
    foreach ($k in $LimitKeys) { $PopupEls["Cap_$k"].Text = Get-Caption $k }
    Update-UpdateControls
    # Accounts
    $PopupEls.SList.Children.Clear()
    $shown = @(Get-TaskbarCfgs | ForEach-Object name)
    foreach ($cfg in @(Get-Visible)) { [void]$PopupEls.SList.Children.Add((New-AccountSettingsRow $cfg $shown)) }
    Show-AcctTool
    Update-NewAcctBox
  } finally { $script:loadingSettings = $false }
  Update-Preview
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
  Save-UiConfig
  $script:lastTry = [DateTime]::MinValue; Start-Refresh
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
  Save-UiConfig
  Update-Widget
  Update-Popup
}

# Drag and drop: put $name where $target is now.
function Move-AccountTo([string]$name, [string]$target) {
  $all = @(Get-AcctCfgs)
  $mv = $all | Where-Object name -eq $name | Select-Object -First 1
  if (-not $mv -or $name -eq $target) { return }
  $rest = [System.Collections.ArrayList]@($all | Where-Object name -ne $name)
  $at = [array]::IndexOf(@($rest | ForEach-Object name), $target)
  if ($at -lt 0) { return }
  if ([array]::IndexOf(@($all | ForEach-Object name), $name) -lt [array]::IndexOf(@($all | ForEach-Object name), $target)) { $at++ }   # dragging down lands after the row it was dropped on
  $rest.Insert($at, $mv)
  $script:config.accounts = @($rest)
  Save-UiConfig
  Update-Widget
  Update-Popup
}

# ---------------------------------------------------------------- settings handlers
# Every control writes the config and refreshes the taskbar at once; Update-Settings fills them under $script:loadingSettings.

foreach ($k in $LimitKeys) {
  $PopupEls["Cap_$k"].Tag = $k
  $PopupEls["Cap_$k"].Add_TextChanged({
    param($s)
    if ($script:loadingSettings) { return }
    if (-not $script:config.captions) { $script:config | Add-Member -Force captions ([pscustomobject]$DefaultCaptions) }
    $script:config.captions | Add-Member -Force -NotePropertyName $s.Tag -NotePropertyValue $s.Text
    Save-UiConfig
    Update-Widget
  })
}

# The Look tiles.
foreach ($k in 'minimal', 'balanced', 'detailed') {
  $PopupEls["Lk_$k"].Tag = $k
  $PopupEls["Lk_$k"].Add_Checked({ param($s) if ($script:loadingSettings) { return }; $script:config | Add-Member -Force look $s.Tag; Save-UiConfig; Update-Widget; Update-Settings })
}
# More options: any of them switches the Look to custom (keeping what the old Look showed) and then changes its own key.
foreach ($choice in @(@('Sz', 'size', 'compact', 'normal', 'large'), @('In', 'inside', 'none', 'initials', 'percent'), @('Nx', 'next', 'none', 'caption', 'percent', 'usage', 'resetin', 'resetat'),
    @('Nm', 'names', 'left', 'right', 'hidden'), @('Sp', 'spacing', 'tight', 'normal', 'wide'), @('Iw', 'innerWindow', '5h', '7d'))) {
  foreach ($v in $choice[2..($choice.Count - 1)]) {
    $rb = $PopupEls["$($choice[0])_$v"]
    $rb.Tag = @{ key = $choice[1]; value = $v }
    $rb.Add_Checked({
      param($s)
      if ($script:loadingSettings) { return }
      Set-LookOption $s.Tag.key $s.Tag.value
      # A global inner-ring choice replaces any per-account one, so every dial follows it.
      if ($s.Tag.key -eq 'innerWindow') { foreach ($a in @(Get-AcctCfgs)) { if ($a.pie) { Set-AcctProp $a.name 'pie' '' } } }
      Save-UiConfig
      Update-Widget
      Update-Settings
    })
  }
}
$PopupEls.Sw_dividers.Add_Click({ param($s) Set-LookOption 'showDividers' ([bool]$s.IsChecked); Save-UiConfig; Update-Widget; Update-Settings })

# Show the 5-hour window, and what happens to accounts at their limit.
$PopupEls.Sw_show5h.Add_Click({ param($s) $script:config | Add-Member -Force show5h ([bool]$s.IsChecked); Save-UiConfig; Update-Widget; Update-Popup -ListOnly; Update-Settings })
$PopupEls.Cb_atLimit.Add_SelectionChanged({ param($s) if ($script:loadingSettings -or -not $s.SelectedItem) { return }; $script:config | Add-Member -Force atLimit $s.SelectedItem.Tag; Save-UiConfig; Update-Widget; Update-Settings })

# Usage list.
$PopupEls.Cb_listLimited.Add_SelectionChanged({ param($s) if ($script:loadingSettings -or -not $s.SelectedItem) { return }; $script:config | Add-Member -Force listLimited $s.SelectedItem.Tag; Save-UiConfig; Update-Popup -ListOnly })
$PopupEls.Cb_listFable.Add_SelectionChanged({ param($s) if ($script:loadingSettings -or -not $s.SelectedItem) { return }; $script:config | Add-Member -Force listFable $s.SelectedItem.Tag; Save-UiConfig; Update-Popup -ListOnly })
foreach ($opt in @(@('Sw_listPlan', 'listPlan'), @('Sw_anim', 'animations'), @('Sw_updates', 'updateCheck'))) {
  $PopupEls[$opt[0]].Tag = $opt[1]
  $PopupEls[$opt[0]].Add_Click({ param($s) $script:config | Add-Member -Force -NotePropertyName $s.Tag -NotePropertyValue ([bool]$s.IsChecked); Save-UiConfig; Update-Popup -ListOnly })
}

# General.
$PopupEls.Cb_refresh.Add_SelectionChanged({ param($s) if ($script:loadingSettings -or -not $s.SelectedItem) { return }; $script:config | Add-Member -Force refreshMinutes ([int]$s.SelectedItem.Tag); Save-UiConfig; Update-Popup -ListOnly })
$PopupEls.Cb_timeFormat.Add_SelectionChanged({ param($s) if ($script:loadingSettings -or -not $s.SelectedItem) { return }; $script:config | Add-Member -Force timeFormat $s.SelectedItem.Tag; Save-UiConfig; Update-Widget; Update-Popup -ListOnly })
$PopupEls.Sw_startup.Add_Click({
  param($s)
  if ($Demo) { return }
  if ($s.IsChecked) { New-LauncherShortcut $StartupLink $PSScriptRoot } elseif (Test-Path $StartupLink) { Remove-Item $StartupLink }
})
$PopupEls.OpenCfgBtn.Add_Click({
  Flush-UiConfig
  if (-not $Demo) {
    if (-not (Test-Path $ConfigPath)) { Save-Config $script:config }
    Start-Process notepad.exe -ArgumentList "`"$ConfigPath`""
  }
})
$PopupEls.ResetBtn.Add_Click({ $PopupEls.ResetBtn.Visibility = 'Collapsed'; $PopupEls.ResetAsk.Visibility = 'Visible' })
$PopupEls.ResetNo.Add_Click({ $PopupEls.ResetAsk.Visibility = 'Collapsed'; $PopupEls.ResetBtn.Visibility = 'Visible' })
# Back to the defaults (the accounts, with their own per-account choices, stay).
$PopupEls.ResetYes.Add_Click({
  $script:config = New-DefaultConfig @(Get-AcctCfgs)
  Save-UiConfig; Update-Widget; Update-Popup -ListOnly; Update-Settings
  $PopupEls.ResetAsk.Visibility = 'Collapsed'; $PopupEls.ResetBtn.Visibility = 'Visible'
})
# Folded sections: click the header to open or close.
foreach ($f in 'More', 'ListMore', 'GenMore') {
  $PopupEls["$($f)Head"].Tag = $f
  $PopupEls["$($f)Head"].Add_MouseLeftButtonUp({
    param($s)
    $body = $PopupEls["$($s.Tag)Body"]; $chev = $PopupEls["$($s.Tag)Chev"]
    $open = $body.Visibility -ne 'Visible'
    $body.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
    $chev.Text = if ($open) { [string][char]0xE70E } else { [string][char]0xE70D }
  })
}

# ---------------------------------------------------------------- account tools (Settings)
# Find / Add / Remove change the config like every other Settings edit, at once. Only references are stored
# (folder, env var name); a token is never read for display. A pasted token goes to the Windows user environment the
# moment the user approves it (to xndr-claude when installed, else a user variable); config.json keeps the variable
# NAME only.

$script:acctMode = $null      # 'find' | 'add' | 'delenv' | $null
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
  Save-UiConfig
  if (-not $Demo) { $script:lastTry = [DateTime]::MinValue; Start-Refresh }   # a new account has no numbers yet
}

function Remove-Account([string]$name) {
  $gone = Get-AcctCfg $name
  $script:config.accounts = @(Get-AcctCfgs | Where-Object { $_.name -ne $name })
  Save-UiConfig
  $script:acctNote = "Removed $(Get-Label $gone)."
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
  if ($settings.IsVisible) { Update-NewAcctBox; if ($script:tab -eq 'acct') { Show-AcctTool } }
}

# On startup and then hourly (see the minute timer): look for accounts the widget doesn't have.
# Nothing is added on its own; they show as "New account found" with Add / Ignore.
function Start-AutoFind {
  if ($Demo -or $script:findJob) { return }
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
  $host2 = $PopupEls.AcctTools
  $host2.Children.Clear()
  $PopupEls.AcctMsg.Text = "$($script:acctNote)"
  $PopupEls.AcctMsg.Visibility = if ($script:acctNote) { 'Visible' } else { 'Collapsed' }
  if (-not $script:acctMode) { return }
  # The open tool sits in a card above the account rows.
  $pan = New-Object Windows.Controls.StackPanel
  $card = New-Object Windows.Controls.Border -Property @{ Background = $Theme.row; BorderBrush = $Theme.rowline; BorderThickness = '1'; CornerRadius = '6'; Padding = '16,6,16,14'; Margin = '0,0,0,8'; Child = $pan }
  [void]$host2.Children.Add($card)
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
    $v = $script:delEnvVar
    if (-not $Demo) { try { Remove-UserEnvToken $v } catch { Write-Log "env var delete failed ($v): $($_.Exception.GetType().Name)" } }
    $script:acctNote = "Removed. $v is deleted."
    $script:acctMode = $null; $script:delEnvVar = $null
    Show-AcctTool
  })
  [void]$pan.Children.Add($bar)
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
      $script:acctNote = "Added $n account$(if ($n -ne 1) { 's' })."
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
  $script:acctNote = "Added $($o.label)."
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
  # The token is already stored, so its account goes to disk now rather than 400 ms later.
  Flush-UiConfig
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

function Show-Settings([string]$page = '') {
  if ($page) { $script:tab = $page }
  if ($settings.IsVisible) {
    if ($settings.WindowState -eq 'Minimized') { $settings.WindowState = 'Normal' }
    Update-Settings
    [void]$settings.Activate()
    return
  }
  $script:acctMode = $null; $script:acctNote = $null
  Update-Settings
  $settings.Show()
  [void]$settings.Activate()
}

# Changes were applied as they were made; closing (the close button, Esc) only hides the window, so it opens again
# at the size the user left it.
function Close-Settings {
  Flush-UiConfig
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
  $script:state.hintCount = [int]$script:state.hintCount + 1
  Save-State
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
# The update always runs where its status can be seen: Settings > General.
$PopupEls.UpdBtn.Add_Click({
  Hide-Popup
  Show-Settings 'gen'
  Invoke-UpdateNow
})
$PopupEls.UpdInstallBtn.Add_Click({ Invoke-UpdateNow })
$PopupEls.UpdCheckBtn.Add_Click({ Start-UpdateCheck -Manual })
$PopupEls.EditBtn.Add_Click({ Hide-Popup; Show-Settings })
$settings.Add_Closing({ param($s, $e) if ($script:exiting) { return }; $e.Cancel = $true; Close-Settings })
$settings.Add_SourceInitialized({ if (-not $isLight) { [CuwNative]::DarkTitleBar((New-Object Windows.Interop.WindowInteropHelper($settings)).Handle) } })
$widget.Add_Closing({ $script:exiting = $true })
$settings.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Close-Settings } })
$script:exiting = $false
foreach ($t in 'task', 'list', 'acct', 'gen') {
  $PopupEls["Tab_$t"].Tag = $t
  $PopupEls["Tab_$t"].Add_Checked({ param($s) if ($script:tab -ne $s.Tag) { $script:tab = $s.Tag; Update-Settings } })
}

# Settings, once opened, is only ever hidden. The list is rebuilt freely; Settings only when asked
# (a refresh finishing must not rebuild it under someone typing).
function Update-All {
  Update-Widget
  if ($popup.IsVisible) { Update-Popup -ListOnly }
  if ($script:forcePopup -and $settings.IsVisible -and $script:acctMode -ne 'add' -and -not ([Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Primitives.TextBoxBase] -or [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.PasswordBox])) { Update-Settings }
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
  Update-Widget
  Update-Popup -ListOnly
  if ($after) { & $after }
  foreach ($el in $WidgetEls.Root, $PopupEls.Card) {
    if ($el.Parent -is [Windows.Window]) { $el.Parent.Content = $null }
    elseif ($el.Parent) { $el.Parent.Content = $null }
  }
  $PopupEls.Card.Width = 372
  $scene = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns Width="820" CornerRadius="14" ClipToBounds="True" TextOptions.TextRenderingMode="Grayscale"
        TextElement.FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#2E3257" Offset="0"/><GradientStop Color="#5A3A5E" Offset="0.55"/><GradientStop Color="#B8664E" Offset="1"/>
    </LinearGradientBrush>
  </Border.Background>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Height="48" Background="$($Theme.tb)">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Right" Margin="0,0,16,0" VerticalAlignment="Center">
          <TextBlock Text="11:46" Foreground="$($Theme.fg)" FontSize="11.5" HorizontalAlignment="Right"/>
          <TextBlock Text="2026-09-29" Foreground="$($Theme.fg)" FontSize="11.5" HorizontalAlignment="Right"/>
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
function Save-SettingsSnapshot([string]$file, [double]$scale, [scriptblock]$after, [double]$height = 0) {
  if (-not $height) { $height = $settings.Height }
  $script:previewForce = $true
  Update-Widget
  Update-Settings
  if ($after) { & $after }
  $dpi = New-Object Windows.DpiScale($scale, $scale)
  $grid = $settings.Content
  $settings.Content = $null
  # A drawn title bar over the window content, like the real window frame.
  $frame = [Windows.Markup.XamlReader]::Parse(@"
<DockPanel $ns Background="$($Theme.win)">
  <Border DockPanel.Dock="Top" Height="32" Background="$($Theme.win)">
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="&#xE921;    &#xE922;    &#xE8BB;" FontFamily="$FontIcons" FontSize="10" Foreground="$($Theme.fg)" VerticalAlignment="Center" Margin="0,0,18,0"/>
      <Ellipse DockPanel.Dock="Left" Width="14" Height="14" Stroke="$($Colors.accent)" StrokeThickness="3" Margin="14,0,10,0"/>
      <TextBlock Text="Claude Usage Widget settings" FontSize="12" Foreground="$($Theme.fg)" VerticalAlignment="Center"/>
    </DockPanel>
  </Border>
  <ContentControl Name="Body"/>
</DockPanel>
"@)
  $frame.FindName('Body').Content = $grid
  $shot = New-Object Windows.Controls.Border -Property @{ Width = $settings.Width; Height = $height; Background = $Theme.win; Child = $frame }
  $shot.Resources.MergedDictionaries.Add($PopupEls.Card.Resources)
  $shot.SetValue([Windows.Documents.TextElement]::ForegroundProperty, (New-Object Windows.Media.BrushConverter).ConvertFromString($Theme.fg))
  $shot.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, (New-Object Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')))
  $shot.UseLayoutRounding = $true
  [Windows.Media.VisualTreeHelper]::SetRootDpi($shot, $dpi)
  $shot.Measure((New-Object Windows.Size($settings.Width, $height)))
  $shot.Arrange((New-Object Windows.Rect(0, 0, $settings.Width, $height)))
  $shot.UpdateLayout()
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][Math]::Ceiling($settings.Width * $scale), [int][Math]::Ceiling($height * $scale), (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32))
  $rtb.Render($shot)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [IO.File]::Create($file)
  try { $enc.Save($fs) } finally { $fs.Close() }
  $frame.FindName('Body').Content = $null
  $shot.Child = $null
  $settings.Content = $grid
  $script:previewForce = $false
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
  <Border Height="48" Background="$($Theme.tb)" Padding="24,0,24,0">
    <DockPanel LastChildFill="False">
      <StackPanel DockPanel.Dock="Right" Margin="40,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="11:46" Foreground="$($Theme.fg)" FontSize="11.5" HorizontalAlignment="Right"/>
        <TextBlock Text="2026-10-13" Foreground="$($Theme.fg)" FontSize="11.5" HorizontalAlignment="Right"/>
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
  $script:config | Add-Member -Force look 'custom'   # the Looks fix size / inside; custom reads the values set below
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
  # CUW_THEME=light renders the light theme; file names end in -dark / -light so both sets can share a folder.
  $tn = if ($isLight) { 'light' } else { 'dark' }
  New-Item -ItemType Directory -Force $Snapshot | Out-Null
  Set-DemoData
  Set-DemoUpdate
  $script:state.hintCount = 3
  # The list popup over a taskbar.
  Save-Snapshot (Join-Path $Snapshot "popup-$tn.png")
  # The taskbar strip in every Look, with the 5h window off, with accounts at their limit shown or hidden, and hover text;
  # at 100 / 125 / 150% display scale (checked against the mock-ups).
  $now = [DateTime]::UtcNow
  foreach ($look in 'minimal', 'balanced', 'detailed') {
    $script:config | Add-Member -Force look $look
    foreach ($scale in 1, 1.25, 1.5) { Save-BarSnapshot (Join-Path $Snapshot "bar-$look-$([int]($scale * 100))-$tn.png") $scale $null }
  }
  $script:config | Add-Member -Force look 'balanced'
  $script:config | Add-Member -Force show5h $false
  foreach ($scale in 1, 1.25, 1.5) { Save-BarSnapshot (Join-Path $Snapshot "bar-no5h-$([int]($scale * 100))-$tn.png") $scale $null }
  $script:config | Add-Member -Force show5h $true
  Save-BarSnapshot (Join-Path $Snapshot "bar-hover-group-$tn.png") 1 (Get-AccountTipFor '__limit__')
  Save-BarSnapshot (Join-Path $Snapshot "bar-hover-account-$tn.png") 1 (Get-AccountTipFor 'side')
  foreach ($al in 'show', 'hide') {
    $script:config | Add-Member -Force atLimit $al
    Save-BarSnapshot (Join-Path $Snapshot "bar-atlimit-$al-$tn.png") 1 $null
  }
  $script:config | Add-Member -Force atLimit 'group'
  $script:config | Add-Member -Force timeFormat '24h'
  Save-BarSnapshot (Join-Path $Snapshot "bar-24h-$tn.png") 1 $null
  $script:config | Add-Member -Force timeFormat '12h'
  # Legacy Beside-the-ring choices still work (custom Look).
  Set-LookOption 'next' 'resetat'
  Save-BarSnapshot (Join-Path $Snapshot "bar-custom-resetat-$tn.png") 1 $null
  $script:config | Add-Member -Force look 'balanced'
  # Settings, every page, at 100% (and Taskbar at 125 / 150% for the layout check).
  $script:newAccts = @()
  foreach ($page in 'task', 'list', 'acct', 'gen') {
    $script:tab = $page
    $script:expanded = if ($page -eq 'acct') { 'side' } else { $null }
    Save-SettingsSnapshot (Join-Path $Snapshot "settings-$page-$tn.png") 1
  }
  $script:tab = 'task'; $script:expanded = $null
  foreach ($scale in 1.25, 1.5) { Save-SettingsSnapshot (Join-Path $Snapshot "settings-task-$([int]($scale * 100))-$tn.png") $scale }
  $script:tab = 'task'
  Save-SettingsSnapshot (Join-Path $Snapshot "settings-task-more-$tn.png") 1 { $PopupEls.MoreBody.Visibility = 'Visible' } 1100
  $PopupEls.MoreBody.Visibility = 'Collapsed'
  Set-LookOption 'next' 'caption'
  Save-SettingsSnapshot (Join-Path $Snapshot "settings-task-custom-$tn.png") 1
  $script:config | Add-Member -Force look 'balanced'
  # Account tools open: find (with a new-account notice), add, and the token approval line (fake value).
  $script:tab = 'acct'; $script:expanded = $null
  Set-DemoFound
  $script:acctMode = 'find'
  Save-SettingsSnapshot (Join-Path $Snapshot "settings-find-$tn.png") 1
  $script:acctMode = 'add'
  Save-SettingsSnapshot (Join-Path $Snapshot "settings-add-$tn.png") 1
  $script:nf = @{ label = 'Side project'; src = 'token'; input = ''; plan = '' }
  Save-SettingsSnapshot (Join-Path $Snapshot "settings-add-token-$tn.png") 1 {
    $script:nfEls.token.Password = 'sk-ant-oat01-FAKEFAKEFAKE'
    $script:nfEls.label.Text = 'Side project'
    Invoke-AddAccount
  }
  $script:acctMode = $null
  # General: every update state.
  $script:tab = 'gen'
  $script:update = $null
  Save-SettingsSnapshot (Join-Path $Snapshot "update-1-idle-$tn.png") 1 { $script:updMsg = $null; Set-UpdStatus $null $null }
  Save-SettingsSnapshot (Join-Path $Snapshot "update-2-checking-$tn.png") 1 { Set-UpdStatus "Checking$ELL" $null }
  Set-DemoUpdate
  Save-SettingsSnapshot (Join-Path $Snapshot "update-3-available-$tn.png") 1 { Set-UpdStatus 'v2.1.0 is available' $null }
  $script:updatingSince = Get-Date
  Save-SettingsSnapshot (Join-Path $Snapshot "update-4-downloading-$tn.png") 1 { Set-UpdStatus "Downloading v2.1.0$ELL 62%" 62 }
  $script:updatingSince = $null
  Save-SettingsSnapshot (Join-Path $Snapshot "update-5-error-$tn.png") 1 { Set-UpdStatus 'Download failed: the remote name could not be resolved' $null }
  $script:update = $null
  # The list in its other settings: inline limited accounts, and an account with a problem.
  Set-DemoData
  $script:config | Add-Member -Force listLimited 'inline'
  (Get-Result 'work').status = 'expired'
  Save-Snapshot (Join-Path $Snapshot "popup-inline-$tn.png")
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

# The theme follows Windows. Colours are baked into the windows when they are built, so a change (light <-> dark) restarts
# the widget: a helper starts a fresh copy two seconds after this one has exited.
function Restart-Widget {
  Flush-UiConfig
  Write-Log 'theme changed: restarting'
  $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
  $script2 = Join-Path $PSScriptRoot 'ClaudeUsageWidget.ps1'
  $cmd = "Start-Sleep 2; Start-Process '$conhost' -ArgumentList '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""$script2""'"
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
  Exit-Widget
}
$themeTimer = New-Object Windows.Threading.DispatcherTimer
$themeTimer.Interval = [TimeSpan]::FromSeconds(3)
$themeTimer.Add_Tick({ if (-not $env:CUW_THEME -and (Get-SystemLight) -ne $isLight) { $themeTimer.Stop(); Restart-Widget } })

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
  if (-not $Demo) { $themeTimer.Start() }
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
  Flush-UiConfig
  if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() }
  $mutex.ReleaseMutex()
}
