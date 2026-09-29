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
$Files   = 'ClaudeUsageWidget.ps1', 'lib\Usage.ps1', 'uninstall.ps1', 'assets\icon.ico', 'LICENSE'
$RegKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeUsageWidget'

function Say($msg, $color = 'Gray') { Write-Host "  $msg" -ForegroundColor $color }

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

# Stop a running copy so its files can be replaced.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*ClaudeUsageWidget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Say "Installing to $Dest"
foreach ($f in $Files) {
  $to = Join-Path $Dest $f
  New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
  Copy-Item (Join-Path $src $f) $to -Force
}
# Files from a downloaded ZIP carry the internet mark, which makes PowerShell refuse or prompt.
Get-ChildItem $Dest -Recurse -File | Unblock-File

. (Join-Path $Dest 'lib\Usage.ps1')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) "$Name.lnk"
$startup   = Join-Path ([Environment]::GetFolderPath('Startup')) "$Name.lnk"
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

if (-not $NoLaunch) { Start-Process $startMenu }

Write-Host ''
Say "Installed $Name $AppVersion." Green
Say 'Look for the usage rings on your taskbar, left of the clock. Click them for all accounts.'
Say 'Ctrl+drag moves them. Right-click for settings. Uninstall from Settings > Apps.'
if (-not $NoStartup) { Say 'It starts with Windows (untick "Start with Windows" in the right-click menu to stop that).' }
Write-Host ''
