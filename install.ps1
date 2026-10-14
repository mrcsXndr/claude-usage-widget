<#
  Installs Claude Usage Widget for the current user. No admin rights, no git, no Node.

    irm https://github.com/mrcsXndr/claude-usage-widget/releases/latest/download/install.ps1 | iex

  Or download ClaudeUsageWidget.zip from the latest release, unzip it and double-click Install.cmd.
  Running it again updates in place and keeps your settings.
#>
param([switch]$NoStartup, [switch]$NoLaunch)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo    = 'mrcsXndr/claude-usage-widget'
$Name    = 'Claude Usage Widget'
$Dest    = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeUsageWidget'
$Files   = 'ClaudeUsageWidget.ps1', 'lib\Usage.ps1', 'lib\Updater.ps1', 'uninstall.ps1', 'assets\icon.ico', 'LICENSE'
# CUW_TEST_ROOT redirects the shortcuts and the Apps entry to a scratch folder (used by tools\Test-Update.ps1 only).
$RegKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeUsageWidget' + $(if ($env:CUW_TEST_ROOT) { 'Test' })
$LogFile = Join-Path $env:APPDATA 'claude-usage-widget\update.log'

function Say($msg, $color = 'Gray') { Write-Host "  $msg" -ForegroundColor $color }
function Log($msg) { try { New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null; Add-Content $LogFile ('{0:yyyy-MM-dd HH:mm:ss}  installer: {1}' -f (Get-Date), $msg) } catch {} }

Write-Host ''
Write-Host "  $Name" -ForegroundColor White
Write-Host ''

# Use this folder when run from an unzipped release or a checkout, else fetch the latest release.
$src = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'ClaudeUsageWidget.ps1'))) {
  $src = $PSScriptRoot
} else {
  Say 'Downloading...'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path $env:TEMP ("cuw-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $tmp | Out-Null
  $zip = Join-Path $tmp 'src.zip'
  Invoke-WebRequest -UseBasicParsing "https://github.com/$Repo/releases/latest/download/ClaudeUsageWidget.zip" -OutFile $zip
  $src = Join-Path $tmp 'src'
  Expand-Archive $zip $src
}

Log "start (from $src)"
# Stop a running copy so its files can be replaced, and wait until it is really gone (a new widget that starts while
# the old one still holds its single-instance lock quits at once, which looked like the widget vanishing).
$old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*ClaudeUsageWidget.ps1*' })
foreach ($o in $old) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue }
foreach ($o in $old) { try { (Get-Process -Id $o.ProcessId -ErrorAction Stop).WaitForExit(10000) | Out-Null } catch {} }

Say "Installing to $Dest"
foreach ($f in $Files) {
  $to = Join-Path $Dest $f
  New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
  $from = Join-Path $src $f
  if (-not (Test-Path $from) -and $f -eq 'lib\Updater.ps1') { continue }
  Copy-Item $from $to -Force
}
# Files from a downloaded ZIP carry the internet mark, which makes PowerShell refuse or prompt.
Get-ChildItem $Dest -Recurse -File | Unblock-File

. (Join-Path $Dest 'lib\Usage.ps1')
$startMenu = Join-Path $(if ($env:CUW_TEST_ROOT) { Join-Path $env:CUW_TEST_ROOT 'StartMenu' } else { [Environment]::GetFolderPath('Programs') }) "$Name.lnk"
$startup   = Join-Path $(if ($env:CUW_TEST_ROOT) { Join-Path $env:CUW_TEST_ROOT 'Startup' } else { [Environment]::GetFolderPath('Startup') }) "$Name.lnk"
New-Item -ItemType Directory -Force (Split-Path $startMenu), (Split-Path $startup) | Out-Null
New-LauncherShortcut $startMenu $Dest
if ($NoStartup) { Remove-Item $startup -ErrorAction SilentlyContinue } else { New-LauncherShortcut $startup $Dest }

# Show up in Settings > Apps, with a working Uninstall button.
$uninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dest 'uninstall.ps1')`""
New-Item -Force $RegKey | Out-Null
$props = @{
  DisplayName = $Name; DisplayVersion = $AppVersion; Publisher = 'mrcsXndr'
  DisplayIcon = (Join-Path $Dest 'assets\icon.ico'); InstallLocation = $Dest
  UninstallString = $uninstall; QuietUninstallString = "$uninstall -Quiet"
  URLInfoAbout = "https://github.com/$Repo"; HelpLink = "https://github.com/$Repo/issues"
}
foreach ($k in $props.Keys) { Set-ItemProperty $RegKey $k $props[$k] }
foreach ($k in 'NoModify', 'NoRepair') { Set-ItemProperty $RegKey $k 1 -Type DWord }
$kb = [int]((Get-ChildItem $Dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
Set-ItemProperty $RegKey EstimatedSize $kb -Type DWord

if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if (-not $NoLaunch) {
  # Start it directly (the shortcut's own command line) and check that it is up; opening the .lnk through the shell
  # gave no way to tell whether anything had started.
  $main = Join-Path $Dest 'ClaudeUsageWidget.ps1'
  $up = $false
  for ($try = 1; $try -le 2 -and -not $up; $try++) {
    Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') -WorkingDirectory $Dest -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$main`""
    for ($i = 0; $i -lt 20 -and -not $up; $i++) {
      Start-Sleep -Milliseconds 500
      $up = [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$main*" })
    }
  }
  Log "widget $(if ($up) { 'started' } else { 'did NOT start' })"
  if (-not $up) { Say 'The widget did not start. Open "Claude Usage Widget" from the Start menu.' Yellow }
}

Write-Host ''
Say "Installed $Name $AppVersion." Green
Say 'Look for the usage rings on your taskbar, left of the clock. Click them for all accounts.'
Say 'Ctrl+drag moves them. Right-click for settings. Uninstall from Settings > Apps.'
if (-not $NoStartup) { Say 'It starts with Windows (untick "Start with Windows" in the right-click menu to stop that).' }
Write-Host ''
