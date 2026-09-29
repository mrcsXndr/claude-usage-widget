#Requires -Version 5.1
<#
.SYNOPSIS
  Claude 5h / 7d / Fable usage rings on the Windows taskbar, with a per-account list on click.

.DESCRIPTION
  Left click   open / close the account list; tick accounts to show them on the taskbar
  Gear         rename accounts, pick each account's rings, rename ring captions
  Ctrl + drag  move the rings along the taskbar
  Right click  refresh, settings, scan for accounts, start with Windows, exit

  Settings live in %APPDATA%\claude-usage-widget\config.json (created on first run from the
  Claude Code logins and xndr-claude accounts found on this PC).

.PARAMETER Once
  Print every account's usage as JSON and exit, without the UI. Never prints a token.
.PARAMETER Demo
  Run with made-up accounts and no network; your config isn't touched.
.PARAMETER Snapshot
  Render the demo UI to PNGs in this folder (used for the README) and exit.
#>
param([switch]$Once, [switch]$Demo, [string]$Snapshot)

$ErrorActionPreference = 'Stop'
$LibPath = Join-Path $PSScriptRoot 'lib\Usage.ps1'
. $LibPath

if ($Once) {
  Get-AllUsage (Read-Config) | ConvertTo-Json -Depth 4
  exit
}
if ($Snapshot) { $Demo = $true }

# Source stays ASCII so Windows PowerShell 5.1 reads it correctly without a BOM.
$ELL = [string][char]0x2026; $DOT = [string][char]0x00B7; $DASH = [string][char]0x2013

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

if (-not $Snapshot) {
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

$StartupLink   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$MinRefreshGap = 60  # seconds between refreshes, however they're triggered

# ---------------------------------------------------------------- UI state (position)

$script:state = @{ right = $null }
if (-not $Demo) {
  try {
    $saved = Get-Content $StatePath -Raw | ConvertFrom-Json
    if ($null -ne $saved.right) { $script:state.right = $saved.right }
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
  if ($Demo) { return }
  try { Save-Config $script:config } catch { Write-Log "save config: $_" }
}

function Get-RefreshMinutes { [Math]::Max(1, [int]$script:config.refreshMinutes) }
function Get-AcctCfgs { @($script:config.accounts | Where-Object { $_ }) }
function Get-AcctCfg($name) { Get-AcctCfgs | Where-Object name -eq $name | Select-Object -First 1 }
function Get-Visible { @(Get-AcctCfgs | Where-Object { $_.hidden -ne $true }) }
function Get-Result($name) { $script:accounts | Where-Object name -eq $name | Select-Object -First 1 }
function Get-Label($cfg) { if ("$($cfg.label)".Trim()) { "$($cfg.label)".Trim() } else { "$($cfg.name)" } }

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
if (-not $Snapshot) {
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
      [pscustomobject]@{ name = 'work'; label = 'Work'; plan = 'Max 5x'; source = 'xndr-claude'; taskbar = $true; limits = @('5h', '7d') }
      [pscustomobject]@{ name = 'side'; label = 'Side project'; plan = 'Pro'; source = 'env' }
    )
  }
  $script:accounts = @(
    [pscustomobject]@{ name = 'personal'; status = 'ok'; error = $null; method = 'usage-api'; five_h = (& $w 64 72); seven_d = (& $w 43 1574); fable = (& $w 38 1574) }
    [pscustomobject]@{ name = 'work'; status = 'ok'; error = $null; method = 'probe'; five_h = (& $w 12 282); seven_d = (& $w 30 6060); fable = (& $w 56 6060) }
    [pscustomobject]@{ name = 'side'; status = 'limited'; error = $null; method = 'probe'; five_h = (& $w 100 38); seven_d = (& $w 71 2900); fable = (& $w $null $null) }
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
  Import-UiConfig
  $script:forcePopup = $true
  Update-All
}

# ---------------------------------------------------------------- widget

[xml]$widgetXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        UseLayoutRounding="True" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Root" Background="#01000000" CornerRadius="6" Padding="8,4" Cursor="Hand">
    <Border.LayoutTransform><ScaleTransform x:Name="Scale" ScaleX="1" ScaleY="1"/></Border.LayoutTransform>
    <StackPanel x:Name="Groups" Orientation="Horizontal"/>
  </Border>
</Window>
"@
$widget = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $widgetXaml))
$WidgetEls = @{}
foreach ($n in 'Root', 'Scale', 'Groups') { $WidgetEls[$n] = $widget.FindName($n) }

function Set-Ring($path, $pct, [double]$size = 30, [double]$thick = 3.5) {
  $path.Stroke = Get-UsageColor $pct
  if ($null -eq $pct -or $pct -le 0) { $path.Data = $null; return }
  $f = [Math]::Min(99.99, [double]$pct) / 100
  $r = ($size - $thick) / 2; $c = $size / 2; $a = 2 * [Math]::PI * $f
  $end = New-Object Windows.Point(($c + $r * [Math]::Sin($a)), ($c - $r * [Math]::Cos($a)))
  $seg = New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0, ($f -gt 0.5), ([Windows.Media.SweepDirection]::Clockwise), $true)
  $fig = New-Object Windows.Media.PathFigure
  $fig.StartPoint = New-Object Windows.Point($c, ($c - $r))
  $fig.Segments.Add($seg)
  $geo = New-Object Windows.Media.PathGeometry
  $geo.Figures.Add($fig)
  $path.Data = $geo
}

function New-RingElement($pct, [string]$caption, [bool]$gapAfter) {
  $text = if ($null -ne $pct) { Format-Pct $pct } elseif ($script:job) { $ELL } else { $DASH }
  $el = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel $ns Orientation="Horizontal" Margin="0,0,$(if ($gapAfter) { 10 } else { 0 }),0">
  <Grid Width="30" Height="30">
    <Ellipse Stroke="$($Theme.ring)" StrokeThickness="3.5"/>
    <Path Name="Arc" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    <TextBlock Text="$text" FontSize="10.5" FontWeight="SemiBold" Foreground="$($Theme.fg)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Grid>
  <TextBlock Text="$(Esc $caption)" FontSize="10" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="4,0,0,0"/>
</StackPanel>
"@)
  Set-Ring ($el.FindName('Arc')) $pct
  return $el
}

function Get-AccountTip($cfg, $res) {
  $tip = @()
  if ($cfg) {
    $tip += (Get-Label $cfg) + $(if ($cfg.plan) { " $DOT $($cfg.plan)" })
    foreach ($k in $LimitKeys) {
      $w = Get-Win $res $k
      if ($w -and $null -ne $w.pct) { $tip += "$(Get-Caption $k)  $(Format-Pct $w.pct)%  $DOT  resets $(Format-Reset $w.reset)" }
    }
    if ($res.error) { $tip += $res.error }
  }
  if ($script:job) { $tip += "Refreshing$ELL" }
  elseif ($script:updated) { $tip += 'Updated {0:HH:mm}' -f $script:updated }
  if ($script:lastError) { $tip += "Error: $($script:lastError)" }
  if ($script:configError) { $tip += $script:configError }
  return ($tip -join "`n")
}

function Update-Widget {
  $WidgetEls.Groups.Children.Clear()
  $cfgs = @(Get-TaskbarCfgs)
  $multi = $cfgs.Count -gt 1
  if (-not $cfgs.Count) {
    $g = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Background = '#01000000' }
    [void]$g.Children.Add((New-RingElement $null (Get-Caption '5h') $true))
    [void]$g.Children.Add((New-RingElement $null (Get-Caption '7d') $false))
    $g.ToolTip = if ($script:job) { "Looking for accounts$ELL" } else { (Get-AccountTip $null $null) + "`nNo accounts yet: right-click > Scan for accounts" }
    [void]$WidgetEls.Groups.Children.Add($g)
  }
  for ($i = 0; $i -lt $cfgs.Count; $i++) {
    $cfg = $cfgs[$i]; $res = Get-Result $cfg.name
    $g = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Background = '#01000000' }
    if ($i -gt 0) {
      [void]$g.Children.Add((New-Object Windows.Controls.Border -Property @{ Width = 1; Height = 22; Background = $Theme.ring; Margin = '10,0,10,0' }))
    }
    if ($multi) {
      [void]$g.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
        Text = (Get-Label $cfg); FontSize = 10.5; Foreground = $Theme.fg; Opacity = 0.85; MaxWidth = 90
        TextTrimming = 'CharacterEllipsis'; VerticalAlignment = 'Center'; Margin = '0,0,8,0'
      }))
    }
    $keys = @(Get-TaskbarLimits $cfg)
    for ($k = 0; $k -lt $keys.Count; $k++) {
      $w = Get-Win $res $keys[$k]
      [void]$g.Children.Add((New-RingElement $w.pct (Get-Caption $keys[$k]) ($k -lt $keys.Count - 1)))
    }
    $g.ToolTip = Get-AccountTip $cfg $res
    [void]$WidgetEls.Groups.Children.Add($g)
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
  $s = [Math]::Min(1.0, ($tb - 6) / 38)
  $WidgetEls.Scale.ScaleX = $s; $WidgetEls.Scale.ScaleY = $s
  $widget.UpdateLayout()
  $h = $widget.ActualHeight; $w = $widget.ActualWidth
  $top = if ($atTop) { 0 } else { $sh - $tb }
  $widget.Top = $top + ($tb - $h) / 2
  $right = if ($null -ne $script:state.right) { [double]$script:state.right } else { 380 }
  $widget.Left = [Math]::Max(0, [Math]::Min($sw - $w, $sw - $w - $right))
}

# ---------------------------------------------------------------- account list

[xml]$popupXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" Width="396" SizeToContent="Height"
        UseLayoutRounding="True" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Card" Background="$($Theme.card)" BorderBrush="$($Theme.border)" BorderThickness="1" CornerRadius="10" Padding="8" Margin="8">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.35"/></Border.Effect>
    <Border.Resources>
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
      <StackPanel x:Name="List"/>
      <StackPanel x:Name="CaptionPanel" Margin="10,10,10,2" Visibility="Collapsed">
        <TextBlock Text="Ring captions" FontSize="11" Foreground="$($Theme.sub)" Margin="0,0,0,6"/>
        <UniformGrid Columns="3">
          <DockPanel Margin="0,0,6,0"><TextBlock DockPanel.Dock="Top" Text="5-hour" FontSize="10.5" Foreground="$($Theme.sub)" Margin="0,0,0,3"/><TextBox x:Name="Cap_5h"/></DockPanel>
          <DockPanel Margin="3,0,3,0"><TextBlock DockPanel.Dock="Top" Text="7-day" FontSize="10.5" Foreground="$($Theme.sub)" Margin="0,0,0,3"/><TextBox x:Name="Cap_7d"/></DockPanel>
          <DockPanel Margin="6,0,0,0"><TextBlock DockPanel.Dock="Top" Text="Fable weekly" FontSize="10.5" Foreground="$($Theme.sub)" Margin="0,0,0,3"/><TextBox x:Name="Cap_fable"/></DockPanel>
        </UniformGrid>
      </StackPanel>
      <TextBlock x:Name="Footer" FontSize="10.5" Foreground="$($Theme.sub)" Margin="10,8,10,2" TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
</Window>
"@
$popup = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $popupXaml))
$PopupEls = @{}
foreach ($n in 'Card', 'RefreshBtn', 'EditBtn', 'Title', 'Status', 'List', 'CaptionPanel', 'Cap_5h', 'Cap_7d', 'Cap_fable', 'Footer') { $PopupEls[$n] = $popup.FindName($n) }
$script:editing = $false

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

function New-AccountRow($cfg, $shownNames) {
  $res = Get-Result $cfg.name
  $label = Esc (Get-Label $cfg)
  $plan = Esc $(if ($cfg.plan) { "   $($cfg.plan)" } else { '' })
  if ($script:editing) {
    $limits = @(Get-TaskbarLimits $cfg)
    $ringBoxes = ($LimitKeys | ForEach-Object {
      "<CheckBox Name=`"L_$_`" Content=`"$(Esc (Get-Caption $_))`" Margin=`"0,0,14,0`" IsChecked=`"$(if ($limits -contains $_) { 'True' } else { 'False' })`"/>"
    }) -join ''
    $row = [Windows.Markup.XamlReader]::Parse(@"
<Border $ns CornerRadius="6" Padding="10,8" Margin="0,1" Background="$($Theme.hover)">
  <StackPanel>
    <DockPanel>
      <CheckBox Name="Tb" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,10,0" ToolTip="Show on the taskbar"/>
      <TextBlock DockPanel.Dock="Right" Text="$plan" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="6,0,0,0"/>
      <TextBox Name="Label" Text="$label" ToolTip="Account name"/>
    </DockPanel>
    <WrapPanel Margin="26,9,0,0">
      <TextBlock Text="Rings" FontSize="11" Foreground="$($Theme.sub)" VerticalAlignment="Center" Margin="0,0,10,0"/>
      $ringBoxes
      <Border Width="1" Height="14" Background="$($Theme.border)" Margin="0,0,14,0" VerticalAlignment="Center"/>
      <CheckBox Name="Vis" Content="In list" ToolTip="Untick to hide this account (e.g. a duplicate)"/>
    </WrapPanel>
  </StackPanel>
</Border>
"@)
    $tb = $row.FindName('Label')
    $tb.Tag = $cfg.name
    $tb.Add_TextChanged({ param($s) Set-AcctProp $s.Tag 'label' $s.Text; Save-UiConfig; Update-Widget })
    foreach ($k in $LimitKeys) {
      $cb = $row.FindName("L_$k")
      $cb.Tag = "$($cfg.name)|$k"
      $cb.Add_Click({ param($s) $n, $key = $s.Tag -split '\|', 2; Set-Limit $n $key ([bool]$s.IsChecked) $s })
    }
    $vis = $row.FindName('Vis')
    $vis.IsChecked = $cfg.hidden -ne $true
    $vis.Tag = $cfg.name
    $vis.Add_Click({
      param($s)
      Set-AcctProp $s.Tag 'hidden' (-not [bool]$s.IsChecked)
      if (-not $s.IsChecked) { Set-AcctProp $s.Tag 'taskbar' $false }
      Save-UiConfig; Update-Widget; Update-Popup
    })
    if ($cfg.hidden -eq $true) { $row.Opacity = 0.5 }
  } else {
    $note = Get-Note $res
    $bars = (Get-BarXaml '5h' (Get-Win $res '5h')) + (Get-BarXaml '7d' (Get-Win $res '7d'))
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
      <CheckBox Name="Tb" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,10,0" ToolTip="Show on the taskbar"/>
      <TextBlock TextTrimming="CharacterEllipsis" VerticalAlignment="Center"><Run Text="$label" FontSize="13" FontWeight="SemiBold" Foreground="$($Theme.fg)"/><Run Text="$plan" FontSize="11" Foreground="$($Theme.sub)"/></TextBlock>
    </DockPanel>
    <StackPanel Margin="26,0,0,0">$bars$noteXaml</StackPanel>
  </StackPanel>
</Border>
"@)
    $via = switch ($res.method) { 'usage-api' { 'Read via the usage API (free)' } 'probe' { 'Read via a 1-token probe (setup-tokens cannot use the usage API)' } default { $null } }
    if ($via) { $row.ToolTip = $via }
    $row.Add_MouseEnter({ param($s) $s.Background = $Theme.hover })
    $row.Add_MouseLeave({ param($s) $s.Background = 'Transparent' })
  }
  $cb = $row.FindName('Tb')
  $cb.IsChecked = $shownNames -contains $cfg.name
  $cb.Tag = $cfg.name
  $cb.Add_Click({ param($s) Set-Taskbar $s.Tag ([bool]$s.IsChecked) $s })
  return $row
}

function Update-RefreshButton {
  $cd = Get-Cooldown
  $PopupEls.RefreshBtn.IsEnabled = -not $script:job -and $cd -eq 0
  $PopupEls.RefreshBtn.ToolTip = if ($script:job) { "Refreshing$ELL" } elseif ($cd) { "You can refresh again in ${cd}s" } else { 'Refresh now' }
}

function Update-Popup {
  Update-RefreshButton
  $PopupEls.EditBtn.Content = if ($script:editing) { [string][char]0xE73E } else { [string][char]0xE713 }
  $PopupEls.EditBtn.ToolTip = if ($script:editing) { 'Done' } else { 'Settings' }
  $PopupEls.Title.Text = if ($script:editing) { 'Settings' } else { 'Claude usage' }
  $PopupEls.Status.Text = if ($script:editing) { 'Changes save as you type' }
    elseif ($script:job) { if ($script:job.discover) { "Scanning for accounts$ELL" } else { "Refreshing$ELL" } }
    elseif ($script:lastError) { "Error: $($script:lastError)" }
    elseif ($script:configError) { $script:configError }
    elseif ($script:updated) { "Updated {0:HH:mm} $DOT every {1} min{2}" -f $script:updated, (Get-RefreshMinutes), $(if ($script:notice) { " $DOT $($script:notice)" }) }
    else { '' }
  $PopupEls.Status.Foreground = if (-not $script:editing -and -not $script:job -and ($script:lastError -or $script:configError)) { $Colors.bad } else { $Theme.sub }

  $PopupEls.List.Children.Clear()
  $shown = @(Get-TaskbarCfgs | ForEach-Object name)
  $cfgs = if ($script:editing) { Get-AcctCfgs } else { Get-Visible }
  foreach ($cfg in $cfgs) { [void]$PopupEls.List.Children.Add((New-AccountRow $cfg $shown)) }
  if (-not @($cfgs).Count) {
    $empty = New-Object Windows.Controls.TextBlock
    $empty.Text = if ($script:job) { "Looking for accounts$ELL" } else { 'No accounts found. Log in with Claude Code (run claude), then right-click the rings > Scan for accounts.' }
    $empty.Foreground = $Theme.sub; $empty.Margin = '10,8'; $empty.TextWrapping = 'Wrap'
    [void]$PopupEls.List.Children.Add($empty)
  }

  $PopupEls.CaptionPanel.Visibility = if ($script:editing) { 'Visible' } else { 'Collapsed' }
  if ($script:editing) {
    $script:loadingCaptions = $true
    foreach ($k in $LimitKeys) { $PopupEls["Cap_$k"].Text = Get-Caption $k }
    $script:loadingCaptions = $false
  }
  $PopupEls.Footer.Text = if ($script:editing) {
    "Tick an account to show it on the taskbar. Rings picks which limits it shows there. The list always shows every limit."
  } else {
    "Tick accounts to show them on the taskbar $DOT Ctrl+drag the rings to move them"
  }
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

# Anchor the list above (or below, for a top taskbar) the widget, keeping it on screen.
function Set-PopupPosition {
  $wa = [Windows.SystemParameters]::WorkArea
  $x = $widget.Left + $widget.ActualWidth / 2 - $popup.ActualWidth / 2
  $popup.Left = [Math]::Max($wa.Left, [Math]::Min($wa.Right - $popup.ActualWidth, $x))
  $popup.Top = if ($wa.Top -gt 0) { $wa.Top } else { $wa.Bottom - $popup.ActualHeight }
}

function Show-Popup([bool]$editing) {
  $script:editing = $editing
  Update-Popup
  $popup.Show()
  [void]$popup.Activate()
  Set-PopupPosition
}

function Hide-Popup {
  $popup.Hide()
  $script:editing = $false
}

$script:popupClosedAt = [DateTime]::MinValue
$popup.Add_Deactivated({ Hide-Popup; $script:popupClosedAt = Get-Date })
$popup.Add_SizeChanged({ Set-PopupPosition })
$popup.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Hide-Popup } })
$PopupEls.RefreshBtn.Add_Click({ Start-Refresh })
$PopupEls.EditBtn.Add_Click({ $script:editing = -not $script:editing; Update-Popup })

# Rebuilding the list while someone types in it would steal their focus, so edits wait.
function Update-All {
  Update-Widget
  if ($popup.IsVisible -and (-not $script:editing -or $script:forcePopup)) { Update-Popup }
  elseif ($popup.IsVisible) { Update-RefreshButton }
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
  if ($script:dragged) { return }
  if ($popup.IsVisible) { Hide-Popup; return }
  # Clicking the widget first deactivates (and hides) an open list; don't reopen it straight away.
  if (((Get-Date) - $script:popupClosedAt).TotalMilliseconds -lt 300) { return }
  Show-Popup $false
})

function New-MenuItem($header, $action) {
  $mi = New-Object Windows.Controls.MenuItem
  $mi.Header = $header
  $mi.Add_Click($action)
  return $mi
}
$menu = New-Object Windows.Controls.ContextMenu
$refreshItem = New-MenuItem 'Refresh now' { Start-Refresh }
$scanItem = New-MenuItem 'Scan for accounts' { Start-Refresh -Discover; Show-Popup $false }
[void]$menu.Items.Add($refreshItem)
[void]$menu.Items.Add((New-MenuItem "Settings$ELL" { Show-Popup $true }))
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
[void]$menu.Items.Add((New-MenuItem 'Exit' { $popup.Close(); $widget.Close() }))
$menu.Add_Opened({
  $startupItem.IsChecked = Test-Path $StartupLink
  $ok = -not $script:job -and (Get-Cooldown) -eq 0
  $refreshItem.IsEnabled = $ok; $scanItem.IsEnabled = $ok
  $refreshItem.Header = if ($ok -or $script:job) { 'Refresh now' } else { "Refresh now (in $(Get-Cooldown)s)" }
})
$widget.ContextMenu = $menu

# ---------------------------------------------------------------- snapshot (README images)

function Save-Snapshot([bool]$editing, [string]$file) {
  $script:editing = $editing
  Update-Widget
  Update-Popup
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

if ($Snapshot) {
  New-Item -ItemType Directory -Force $Snapshot | Out-Null
  Set-DemoData
  Save-Snapshot $false (Join-Path $Snapshot 'widget.png')
  Save-Snapshot $true (Join-Path $Snapshot 'settings.png')
  exit
}

# ---------------------------------------------------------------- timers & run

$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$pollTimer.Add_Tick({ if ($script:job) { Complete-Refresh } else { $pollTimer.Stop() } })

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
  $mutex.ReleaseMutex()
}
