# Headless test of the update relaunch path. In a scratch folder it installs an "old" widget (this checkout with the
# version set back to 1.0.0), starts it, then runs the same hand-over the widget's "Install update" button uses
# (Start-UpdateHelper -> lib\Updater.ps1) with a zip of this checkout, and checks that
#   1. the old process is gone and a NEW widget process is running from the install folder,
#   2. the files in the install folder are the new ones,
#   3. a broken zip is rolled back and the old version is started again (the widget must never just disappear).
# Nothing outside the scratch folder is touched: APPDATA, LOCALAPPDATA, the user profile and the shortcut folders
# are redirected. Needs no network. Exit code 1 on any failure.
#   powershell -NoProfile -File tools\Test-Update.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$T = Join-Path $env:TEMP ('cuw-test-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Local = Join-Path $T 'Local'; $Roam = Join-Path $T 'Roaming'; $Shortcuts = Join-Path $T 'Shortcuts'
$Dest = Join-Path $Local 'Programs\ClaudeUsageWidget'
$Main = Join-Path $Dest 'ClaudeUsageWidget.ps1'
New-Item -ItemType Directory -Force $Local, (Join-Path $Roam 'claude-usage-widget'), $Shortcuts | Out-Null
# An existing config with no accounts: the test widget finds nothing to read and makes no network calls.
[IO.File]::WriteAllText((Join-Path $Roam 'claude-usage-widget\config.json'), '{"refreshMinutes":30,"accounts":[]}')
$saved = @{}; foreach ($k in 'APPDATA', 'LOCALAPPDATA', 'CUW_TEST_ROOT') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
$env:APPDATA = $Roam; $env:LOCALAPPDATA = $Local; $env:CUW_TEST_ROOT = $Shortcuts
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if (-not $ok) { $script:fail++ }
  '{0}  {1}{2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { "  ($detail)" })
}
function Get-Widgets { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$Main*" }) }
function Wait-Until([scriptblock]$cond, [int]$sec) { for ($i = 0; $i -lt $sec * 2; $i++) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 500 }; return $false }

# The files an install holds, copied from this checkout; the version is set back to 1.0.0 so the update is "newer".
$files = 'ClaudeUsageWidget.ps1', 'uninstall.ps1', 'LICENSE', 'install.ps1', 'lib\Usage.ps1', 'lib\Updater.ps1', 'assets\icon.ico'
function New-OldInstall {
  Remove-Item $Dest -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    if ($f -eq 'install.ps1') { continue }
    $to = Join-Path $Dest $f; New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    Copy-Item (Join-Path $root $f) $to
  }
  $u = Join-Path $Dest 'lib\Usage.ps1'
  [IO.File]::WriteAllText($u, ((Get-Content $u -Raw) -replace "\`$AppVersion = '[\d.]+'", "`$AppVersion = '1.0.0'"))
}
function Start-OldWidget {
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$Main`""
  if (-not (Wait-Until { @(Get-Widgets).Count -gt 0 } 20)) {
    throw "the old widget did not start ($(if ($p.HasExited) { "exited with code $($p.ExitCode)" } else { 'running, but not found by its command line' }))"
  }
  Start-Sleep -Seconds 4   # past startup, like a widget that has been running for a while
  return @(Get-Widgets)[0].ProcessId
}
function New-Zip([string]$path) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  Remove-Item $path -Force -ErrorAction SilentlyContinue
  $z = [IO.Compression.ZipFile]::Open($path, 'Create')
  try { foreach ($f in $files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $root $f), ($f -replace '\\', '/')) } } finally { $z.Dispose() }
}
. (Join-Path $root 'lib\Usage.ps1')   # for Start-UpdateHelper and Get-ZipVersion, with APPDATA redirected
$expected = $AppVersion

try {
  $zip = Join-Path $T 'update.zip'; New-Zip $zip
  Check 'zip holds the new version' ((Get-ZipVersion $zip) -eq $expected) "found $(Get-ZipVersion $zip)"

  '--- case 1: update from 1.0.0'
  New-OldInstall
  $old = Start-OldWidget
  Check 'old widget running' ($old -gt 0) "pid $old"
  $log = Join-Path $Roam 'claude-usage-widget\update.log'
  $helper = Start-UpdateHelper $old $zip $Dest
  Start-Sleep -Milliseconds 800
  Stop-Process -Id $old -Force   # what the widget does itself right after starting the helper
  Check 'a new widget starts' (Wait-Until { $w = @(Get-Widgets); $w.Count -gt 0 -and $w[0].ProcessId -ne $old } 40) 'within 20 s'
  $new = @(Get-Widgets | Where-Object { $_.ProcessId -ne $old })
  Check 'exactly one widget runs' ($new.Count -eq 1 -and @(Get-Widgets).Count -eq 1) "pids $(@(Get-Widgets).ProcessId -join ',')"
  Check 'old process is gone' (-not (Get-Process -Id $old -ErrorAction SilentlyContinue))
  Check 'install folder has the new version' ((Get-Content (Join-Path $Dest 'lib\Usage.ps1') -Raw) -match "AppVersion = '$([regex]::Escape($expected))'")
  Check 'helper finished and logged "update done"' ((Wait-Until { (Test-Path $log) -and ((Get-Content $log -Raw) -match 'update done') } 30)) $log
  Check 'Start menu shortcut written (to the scratch folder)' (Test-Path (Join-Path $Shortcuts 'StartMenu\Claude Usage Widget.lnk'))
  Get-Widgets | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  Start-Sleep -Seconds 1

  '--- case 2: broken zip must roll back and leave a widget running'
  Remove-Item $log -Force -ErrorAction SilentlyContinue
  New-OldInstall
  $old = Start-OldWidget
  $bad = Join-Path $T 'bad.zip'; [IO.File]::WriteAllText($bad, 'this is not a zip')
  $helper = Start-UpdateHelper $old $bad $Dest
  Start-Sleep -Milliseconds 800
  Stop-Process -Id $old -Force
  Check 'a widget is running again' (Wait-Until { $w = @(Get-Widgets); $w.Count -gt 0 -and $w[0].ProcessId -ne $old } 40)
  Check 'old version is still installed' ((Get-Content (Join-Path $Dest 'lib\Usage.ps1') -Raw) -match "AppVersion = '1.0.0'")
  Check 'log says the update failed and was rolled back' ((Wait-Until { (Test-Path $log) -and ((Get-Content $log -Raw) -match 'rolling back') -and ((Get-Content $log -Raw) -match 'running again') } 30))
  Get-Widgets | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
} finally {
  # Stop anything started from the scratch folder, then remove it.
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$T*" -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  Start-Sleep -Seconds 1
  Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { "$fail check(s) FAILED"; exit 1 }
'update relaunch test passed'
