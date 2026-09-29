#Requires -Version 5.1
<#
.SYNOPSIS
  Claude 5h / 7d usage rings on the Windows taskbar, with a per-account list on click.

.DESCRIPTION
  Left click   open / close the account list (click an account to show it on the taskbar)
  Ctrl + drag  move the rings along the taskbar
  Right click  refresh, edit accounts, reset position, start with Windows, exit

  Accounts live in %APPDATA%\claude-usage-widget\config.json (created on first run).

.PARAMETER Once
  Print every account's usage as JSON and exit, without the UI. Never prints a token.
#>
param([switch]$Once)

$ErrorActionPreference = 'Stop'
$LibPath = Join-Path $PSScriptRoot 'lib\Usage.ps1'
. $LibPath

if ($Once) {
  Get-AllUsage (Read-Config) | ConvertTo-Json -Depth 4
  exit
}

# Source stays ASCII so Windows PowerShell 5.1 reads it correctly without a BOM.
$ELL = [string][char]0x2026; $DOT = [string][char]0x00B7; $DASH = [string][char]0x2013

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\claude-usage-widget', [ref]$createdNew)
if (-not $createdNew) { exit }

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

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude usage widget.lnk'
$Launcher    = Join-Path $PSScriptRoot 'launch.vbs'

# ---------------------------------------------------------------- UI state (position, pinned account)

$script:state = @{ left = $null; pinned = $null }
try {
  $saved = Get-Content $StatePath -Raw | ConvertFrom-Json
  foreach ($k in 'left', 'pinned') { if ($null -ne $saved.$k) { $script:state[$k] = $saved.$k } }
} catch {}

function Save-State {
  try {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    $script:state | ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
  } catch { Write-Log "save state: $_" }
}

function Get-RefreshMinutes {
  try { return [Math]::Max(5, [int](Read-Config).refreshMinutes) } catch { return 30 }
}

# ---------------------------------------------------------------- theme

$isLight = $false
try { $isLight = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' SystemUsesLightTheme) -eq 1 } catch {}
$T = if ($isLight) {
  @{ fg = '#1A1A1A'; sub = '#5F5F5F'; ring = '#26000000'; card = '#F9F9F9'; border = '#D0D0D0'; hover = '#EAEAEA'; bar = '#E0E0E0'; widgetHover = '#1A000000' }
} else {
  @{ fg = '#FFFFFF'; sub = '#A3A3A3'; ring = '#3DFFFFFF'; card = '#202020'; border = '#3A3A3A'; hover = '#2E2E2E'; bar = '#3A3A3A'; widgetHover = '#1FFFFFFF' }
}
$C = @{ ok = '#4CC38A'; warn = '#F2B84B'; bad = '#F0625D'; none = '#8A8A8A' }

function Get-UsageColor($pct) {
  if ($null -eq $pct) { return $C.none }
  if ($pct -ge 90) { return $C.bad }
  if ($pct -ge 70) { return $C.warn }
  return $C.ok
}

function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }

# ---------------------------------------------------------------- data

$script:accounts    = @()
$script:updated     = $null
$script:lastTry     = [DateTime]::MinValue
$script:lastError   = $null
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
  if ($span.TotalMinutes -le 0) { return 'reset now' }
  if ($span.TotalHours -lt 1) { return 'in {0}m' -f [int][Math]::Ceiling($span.TotalMinutes) }
  if ($span.TotalHours -lt 24) { return 'in {0}h {1:00}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
  return $dt.ToString('ddd HH:mm')
}

function Get-LastUsed {
  try { return (Get-Content (Join-Path (Get-XndrClaudeHome) 'state.json') -Raw | ConvertFrom-Json).last } catch { return $null }
}

# The account on the taskbar: the one picked in the list, else xndr-claude's last-used one, else the first.
function Get-ShownAccount {
  if (-not $script:accounts.Count) { return $null }
  foreach ($want in @($script:state.pinned, (Get-LastUsed))) {
    if ($want) { $hit = $script:accounts | Where-Object name -eq $want | Select-Object -First 1; if ($hit) { return $hit } }
  }
  return $script:accounts[0]
}

# Reads run in a background runspace so token commands and HTTP never block the UI.
function Start-Refresh {
  if ($script:job) { return }
  $script:lastTry = Get-Date
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({
    param($lib, $cache)
    $ErrorActionPreference = 'Stop'
    . $lib
    Get-AllUsage (Read-Config) $cache
  }).AddArgument($LibPath).AddArgument($script:methodCache)
  $script:job = @{ ps = $ps; handle = $ps.BeginInvoke(); started = Get-Date }
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
    $rows = @($j.ps.EndInvoke($j.handle))
    $script:accounts = $rows
    $script:updated = Get-Date
    $script:lastError = $null
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $script:lastError = $e.Message
    Write-Log "refresh: $($script:lastError)"
  } finally {
    $j.ps.Dispose()
  }
  Update-All
}

# ---------------------------------------------------------------- widget

[xml]$widgetXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        UseLayoutRounding="True" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Root" Background="#01000000" CornerRadius="6" Padding="6,4">
    <Border.LayoutTransform><ScaleTransform x:Name="Scale" ScaleX="1" ScaleY="1"/></Border.LayoutTransform>
    <StackPanel Orientation="Horizontal">
      <Grid Width="30" Height="30">
        <Ellipse Stroke="$($T.ring)" StrokeThickness="3.5"/>
        <Path x:Name="Arc5" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <TextBlock x:Name="Pct5" FontSize="10.5" FontWeight="SemiBold" Foreground="$($T.fg)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
      <TextBlock Text="5h" FontSize="10" Foreground="$($T.sub)" VerticalAlignment="Center" Margin="4,0,10,0"/>
      <Grid Width="30" Height="30">
        <Ellipse Stroke="$($T.ring)" StrokeThickness="3.5"/>
        <Path x:Name="Arc7" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <TextBlock x:Name="Pct7" FontSize="10.5" FontWeight="SemiBold" Foreground="$($T.fg)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
      <TextBlock Text="7d" FontSize="10" Foreground="$($T.sub)" VerticalAlignment="Center" Margin="4,0,2,0"/>
    </StackPanel>
  </Border>
</Window>
"@
$widget = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $widgetXaml))
$W = @{}
foreach ($n in 'Root', 'Scale', 'Arc5', 'Arc7', 'Pct5', 'Pct7') { $W[$n] = $widget.FindName($n) }

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

function Update-Widget {
  $a = Get-ShownAccount
  $p5 = if ($a) { $a.five_h.pct } else { $null }
  $p7 = if ($a) { $a.seven_d.pct } else { $null }
  $empty = if ($script:job) { $ELL } else { $DASH }
  Set-Ring $W.Arc5 $p5
  Set-Ring $W.Arc7 $p7
  $W.Pct5.Text = if ($null -ne $p5) { Format-Pct $p5 } else { $empty }
  $W.Pct7.Text = if ($null -ne $p7) { Format-Pct $p7 } else { $empty }
  $W.Root.Opacity = if ($script:job) { 0.6 } else { 1.0 }

  $tip = @()
  if ($a) {
    $tip += $a.label + $(if ($a.plan) { " $DOT $($a.plan)" })
    if ($null -ne $p5) { $tip += "5h  $(Format-Pct $p5)%  $DOT  resets $(Format-Reset $a.five_h.reset)" }
    if ($null -ne $p7) { $tip += "7d  $(Format-Pct $p7)%  $DOT  resets $(Format-Reset $a.seven_d.reset)" }
    if ($a.error) { $tip += $a.error }
  }
  if ($script:job) { $tip += "Refreshing$ELL" }
  elseif ($script:updated) { $tip += 'Updated {0:HH:mm}' -f $script:updated }
  if ($script:lastError) { $tip += "Error: $($script:lastError)" }
  $widget.ToolTip = ($tip -join "`n")
}

# Sit on the primary screen's taskbar, vertically centred in it.
function Set-WidgetPosition {
  $wa = [Windows.SystemParameters]::WorkArea
  $sh = [Windows.SystemParameters]::PrimaryScreenHeight
  $sw = [Windows.SystemParameters]::PrimaryScreenWidth
  $atTop = $wa.Top -gt 0
  $tb = if ($atTop) { $wa.Top } else { $sh - $wa.Bottom }
  if ($tb -lt 20) { $tb = 48 }  # auto-hidden taskbar: assume the default height
  $s = [Math]::Min(1.0, ($tb - 6) / 38)
  $W.Scale.ScaleX = $s; $W.Scale.ScaleY = $s
  $widget.UpdateLayout()
  $h = $widget.ActualHeight; $w = $widget.ActualWidth
  $top = if ($atTop) { 0 } else { $sh - $tb }
  $widget.Top = $top + ($tb - $h) / 2
  $left = if ($null -ne $script:state.left) { [double]$script:state.left } else { $sw - $w - 380 }
  $widget.Left = [Math]::Max(0, [Math]::Min($sw - $w, $left))
}

# ---------------------------------------------------------------- account list

[xml]$popupXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude accounts" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" Width="380" SizeToContent="Height"
        UseLayoutRounding="True" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border Background="$($T.card)" BorderBrush="$($T.border)" BorderThickness="1" CornerRadius="8" Padding="8" Margin="8">
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35"/></Border.Effect>
    <StackPanel>
      <DockPanel Margin="8,4,4,6">
        <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Cursor="Hand" ToolTip="Refresh now" Focusable="False" VerticalAlignment="Top">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bg" Background="Transparent" CornerRadius="4" Padding="8,5">
                <TextBlock Text="&#xE72C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Foreground="$($T.fg)"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="$($T.hover)"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bg" Property="Opacity" Value="0.4"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
        <StackPanel>
          <TextBlock Text="Claude usage" FontSize="14" FontWeight="SemiBold" Foreground="$($T.fg)"/>
          <TextBlock x:Name="Status" FontSize="11" Foreground="$($T.sub)" TextWrapping="Wrap"/>
        </StackPanel>
      </DockPanel>
      <StackPanel x:Name="List"/>
      <TextBlock x:Name="Footer" FontSize="10.5" Foreground="$($T.sub)" Margin="8,6,8,2" TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
</Window>
"@
$popup = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $popupXaml))
$P = @{}
foreach ($n in 'RefreshBtn', 'Status', 'List', 'Footer') { $P[$n] = $popup.FindName($n) }
$P.Footer.Text = "Click an account to show it on the taskbar $DOT Ctrl+drag the rings to move them $DOT Right-click them for options"
$ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'

function Get-BarXaml($label, $win) {
  $pct = $win.pct
  $p = if ($null -ne $pct) { [Math]::Max(0, [Math]::Min(100, [double]$pct)) } else { 0 }
  $pctText = if ($null -ne $pct) { "$(Format-Pct $pct)%" } else { $DASH }
@"
<Grid $ns Margin="0,6,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="96"/></Grid.ColumnDefinitions>
  <TextBlock Text="$label" FontSize="11" Foreground="$($T.sub)" VerticalAlignment="Center"/>
  <Grid Grid.Column="1" Height="6" VerticalAlignment="Center">
    <Border Background="$($T.bar)" CornerRadius="3"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="$($p)*"/><ColumnDefinition Width="$(100 - $p)*"/></Grid.ColumnDefinitions>
      <Border Background="$(Get-UsageColor $pct)" CornerRadius="3"/>
    </Grid>
  </Grid>
  <TextBlock Grid.Column="2" Text="$pctText" FontSize="12" FontWeight="SemiBold" Foreground="$($T.fg)" TextAlignment="Right" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="3" Text="$(Esc (Format-Reset $win.reset))" FontSize="11" Foreground="$($T.sub)" TextAlignment="Right" VerticalAlignment="Center"/>
</Grid>
"@
}

function Update-Popup {
  $P.RefreshBtn.IsEnabled = -not $script:job
  $P.Status.Text = if ($script:job) { "Refreshing$ELL" }
    elseif ($script:lastError) { "Error: $($script:lastError)" }
    elseif ($script:updated) { "Updated {0:HH:mm} $DOT every {1} min" -f $script:updated, (Get-RefreshMinutes) }
    else { '' }
  $P.Status.Foreground = if ($script:lastError -and -not $script:job) { $C.bad } else { $T.sub }

  $P.List.Children.Clear()
  $shown = Get-ShownAccount
  $last = Get-LastUsed
  foreach ($a in $script:accounts) {
    $badges = @()
    if ($shown -and $a.name -eq $shown.name) { $badges += 'on taskbar' }
    if ($last -and $a.name -eq $last) { $badges += 'last used' }
    $note = if ($a.status -eq 'limited') { 'rate limited' } elseif ($a.error) { $a.error } else { '' }
    $noteXaml = if ($note) { "<TextBlock Text=`"$(Esc $note)`" FontSize=`"11`" Foreground=`"$($C.bad)`" Margin=`"0,6,0,0`" TextWrapping=`"Wrap`"/>" } else { '' }
    $via = switch ($a.method) { 'usage-api' { 'Read via the usage API (free)' } 'probe' { 'Read via a 1-token Haiku probe (setup-tokens cannot use the usage API)' } default { '' } }
    $planText = if ($a.plan) { "   $($a.plan)" } else { '' }
    $rowXaml = @"
<Border $ns CornerRadius="6" Padding="10,8" Margin="0,1" Background="Transparent" Cursor="Hand">
  <StackPanel>
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="$(Esc ($badges -join " $DOT "))" FontSize="11" Foreground="$($C.ok)" VerticalAlignment="Center"/>
      <TextBlock TextTrimming="CharacterEllipsis"><Run Text="$(Esc $a.label)" FontSize="13" FontWeight="SemiBold" Foreground="$($T.fg)"/><Run Text="$(Esc $planText)" FontSize="11" Foreground="$($T.sub)"/></TextBlock>
    </DockPanel>
    $(Get-BarXaml '5h' $a.five_h)
    $(Get-BarXaml '7d' $a.seven_d)
    $noteXaml
  </StackPanel>
</Border>
"@
    $row = [Windows.Markup.XamlReader]::Parse($rowXaml)
    $row.Tag = $a.name
    if ($via) { $row.ToolTip = $via }
    $row.Add_MouseEnter({ param($s) $s.Background = $T.hover })
    $row.Add_MouseLeave({ param($s) $s.Background = 'Transparent' })
    $row.Add_MouseLeftButtonUp({
      param($s)
      $script:state.pinned = $s.Tag
      Save-State
      Update-All
    })
    [void]$P.List.Children.Add($row)
  }
  if (-not $script:accounts.Count) {
    $empty = New-Object Windows.Controls.TextBlock
    $empty.Text = if ($script:job) { "Loading$ELL" } else { 'No accounts yet. Right-click the rings > Edit accounts.' }
    $empty.Foreground = $T.sub; $empty.Margin = '10,8'; $empty.TextWrapping = 'Wrap'
    [void]$P.List.Children.Add($empty)
  }
}

# Anchor the list above (or below, for a top taskbar) the widget, keeping it on screen.
function Set-PopupPosition {
  $wa = [Windows.SystemParameters]::WorkArea
  $x = $widget.Left + $widget.ActualWidth / 2 - $popup.ActualWidth / 2
  $popup.Left = [Math]::Max($wa.Left, [Math]::Min($wa.Right - $popup.ActualWidth, $x))
  $popup.Top = if ($wa.Top -gt 0) { $wa.Top } else { $wa.Bottom - $popup.ActualHeight }
}

$script:popupClosedAt = [DateTime]::MinValue
$popup.Add_Deactivated({ $popup.Hide(); $script:popupClosedAt = Get-Date })
$popup.Add_SizeChanged({ Set-PopupPosition })
$popup.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $popup.Hide() } })
$P.RefreshBtn.Add_Click({ Start-Refresh })

function Update-All {
  Update-Widget
  if ($popup.IsVisible) { Update-Popup }
}

# ---------------------------------------------------------------- widget interaction

$script:dragged = $false
$W.Root.Add_MouseEnter({ $W.Root.Background = $T.widgetHover })
$W.Root.Add_MouseLeave({ $W.Root.Background = '#01000000' })
$widget.Add_MouseLeftButtonDown({
  $script:dragged = $false
  if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
    $before = $widget.Left
    $widget.DragMove()
    $script:dragged = $true
    if ($widget.Left -ne $before) { $script:state.left = [Math]::Round($widget.Left); Save-State }
    Set-WidgetPosition
  }
})
$widget.Add_MouseLeftButtonUp({
  if ($script:dragged) { return }
  if ($popup.IsVisible) { $popup.Hide(); return }
  # Clicking the widget first deactivates (and hides) an open list; don't reopen it straight away.
  if (((Get-Date) - $script:popupClosedAt).TotalMilliseconds -lt 300) { return }
  Update-Popup
  $popup.Show()
  [void]$popup.Activate()
  Set-PopupPosition
})

function New-MenuItem($header, $action) {
  $mi = New-Object Windows.Controls.MenuItem
  $mi.Header = $header
  $mi.Add_Click($action)
  return $mi
}
$menu = New-Object Windows.Controls.ContextMenu
[void]$menu.Items.Add((New-MenuItem 'Refresh now' { Start-Refresh }))
[void]$menu.Items.Add((New-MenuItem "Edit accounts$ELL" {
  if (-not (Test-Path $ConfigPath)) { [void](Read-Config) }
  Start-Process notepad.exe -ArgumentList "`"$ConfigPath`""
}))
[void]$menu.Items.Add((New-MenuItem 'Show last-used account' { $script:state.pinned = $null; Save-State; Update-All }))
[void]$menu.Items.Add((New-MenuItem 'Reset position' { $script:state.left = $null; Save-State; Set-WidgetPosition }))
$startupItem = New-MenuItem 'Start with Windows' {
  if (Test-Path $StartupLink) {
    Remove-Item $StartupLink
  } else {
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLink)
    $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $sc.Arguments = "`"$Launcher`""
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.Description = 'Claude usage taskbar widget'
    $sc.Save()
  }
}
$startupItem.IsCheckable = $true
[void]$menu.Items.Add($startupItem)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void]$menu.Items.Add((New-MenuItem 'Exit' { $popup.Close(); $widget.Close() }))
$menu.Add_Opened({ $startupItem.IsChecked = Test-Path $StartupLink })
$widget.ContextMenu = $menu

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
})

# Once a minute: refresh when due (this also catches up after sleep), keep countdowns and position current.
$minuteTimer = New-Object Windows.Threading.DispatcherTimer
$minuteTimer.Interval = [TimeSpan]::FromMinutes(1)
$minuteTimer.Add_Tick({
  if (-not $script:job -and ((Get-Date) - $script:lastTry).TotalMinutes -ge (Get-RefreshMinutes)) { Start-Refresh }
  else { Update-All }
  Set-WidgetPosition
})

$widget.Add_SourceInitialized({
  $script:hwnd = (New-Object Windows.Interop.WindowInteropHelper($widget)).Handle
  [CuwNative]::MakeToolWindow($script:hwnd)
})
$widget.Add_Loaded({
  Set-WidgetPosition
  Update-Widget
  $topTimer.Start()
  $minuteTimer.Start()
  Start-Refresh
})

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
