<#
  Removes Claude Usage Widget: the app, its shortcuts, its Settings > Apps entry and its settings.
  Your Claude logins and tokens are never touched.
#>
param([switch]$Quiet, [switch]$KeepSettings)

$ErrorActionPreference = 'SilentlyContinue'
$Name   = 'Claude Usage Widget'
$Dest   = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeUsageWidget'
$Data   = Join-Path $env:APPDATA 'claude-usage-widget'
$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeUsageWidget'

Set-Location $env:TEMP
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*ClaudeUsageWidget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500

Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) "$Name.lnk")
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) "$Name.lnk")
Remove-Item $RegKey -Recurse
Remove-Item $Dest -Recurse -Force
if (-not $KeepSettings) { Remove-Item $Data -Recurse -Force }

if (-not $Quiet) {
  Write-Host ''
  Write-Host "  $Name has been removed." -ForegroundColor Green
  Write-Host ''
  Start-Sleep -Seconds 2
}
