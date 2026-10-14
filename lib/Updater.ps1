# Runs as its own process (a copy in TEMP, started by the widget's "Install update"). It waits for the old widget to
# exit, replaces the install folder's files from the downloaded zip, starts the new widget and checks that it is
# running. Anything that fails is rolled back and the old version is started again. Everything is logged to update.log.
# Its command line must not contain the widget script's name: the installer stops any process that does.
param([int]$WidgetPid, [string]$Zip, [string]$Dest, [string]$LogDir)

$ErrorActionPreference = 'Stop'
$log = Join-Path $LogDir 'update.log'
function L([string]$m) {
  try { New-Item -ItemType Directory -Force $LogDir | Out-Null; Add-Content $log ('{0:yyyy-MM-dd HH:mm:ss}  updater: {1}' -f (Get-Date), $m) } catch {}
}
$Files = 'ClaudeUsageWidget.ps1', 'uninstall.ps1', 'LICENSE', 'lib\Usage.ps1', 'lib\Updater.ps1', 'assets\icon.ico'
$Main = Join-Path $Dest 'ClaudeUsageWidget.ps1'

function Get-Widgets {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$Main*" })
}

# The same command line the Start menu shortcut uses: no console window, the install folder as working directory.
function Start-Widget {
  $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
  Start-Process $conhost -WorkingDirectory $Dest -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$Main`""
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $w = @(Get-Widgets)
    if ($w.Count) { L "widget running as pid $($w[0].ProcessId)"; return $true }
  }
  return $false
}

function Restore([string]$from) {
  foreach ($f in $Files) {
    $s = Join-Path $from $f
    if (Test-Path $s) { Copy-Item $s (Join-Path $Dest $f) -Force }
  }
}

$stage = Join-Path $env:TEMP ('cuw-update-' + [guid]::NewGuid().ToString('N'))
$bak = "$stage-backup"
try {
  L "start: widget pid $WidgetPid, zip $Zip, dest $Dest"
  # 1. The old widget exits by itself right after starting us; if it is still there after 20 s, stop it.
  $p = Get-Process -Id $WidgetPid -ErrorAction SilentlyContinue
  if ($p -and -not $p.WaitForExit(20000)) { L "widget pid $WidgetPid did not exit in 20 s, stopping it"; Stop-Process -Id $WidgetPid -Force; Start-Sleep -Seconds 1 }
  foreach ($w in Get-Widgets) { L "stopping stray widget pid $($w.ProcessId)"; Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500

  # 2. Keep the current files so a failed update can be undone.
  New-Item -ItemType Directory -Force $bak | Out-Null
  foreach ($f in $Files) {
    $s = Join-Path $Dest $f
    if (Test-Path $s) { $t = Join-Path $bak $f; New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null; Copy-Item $s $t -Force }
  }
  $replaced = $false
  try {
    # 3. Replace the files.
    Expand-Archive $Zip $stage
    foreach ($f in $Files) {
      $s = Join-Path $stage $f
      if (-not (Test-Path $s)) { if ($f -eq 'lib\Updater.ps1') { continue } else { throw "the zip has no $f" } }
      $t = Join-Path $Dest $f
      New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null
      Copy-Item $s $t -Force
    }
    $replaced = $true
    Get-ChildItem $Dest -Recurse -File | Unblock-File
    L 'files replaced'
    # 4. Refresh the Start menu / Settings > Apps entries (only for the standard install folder; never fatal).
    $std = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeUsageWidget'
    $installer = Join-Path $stage 'install.ps1'
    if ((Test-Path $installer) -and ($Dest.TrimEnd('\') -eq $std.TrimEnd('\'))) {
      try {
        $startup = if ($env:CUW_TEST_ROOT) { Join-Path $env:CUW_TEST_ROOT 'Startup' } else { [Environment]::GetFolderPath('Startup') }
        $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-NoLaunch')
        if (-not (Test-Path (Join-Path $startup 'Claude Usage Widget.lnk'))) { $argl += '-NoStartup' }
        $out = & powershell.exe @argl 2>&1 | Out-String
        L "shortcuts and Apps entry refreshed (exit $LASTEXITCODE)"
      } catch { L "shortcut refresh failed (ignored): $($_.Exception.Message)" }
    }
  } catch {
    L "install failed: $($_.Exception.Message); rolling back"
    Restore $bak
    $replaced = $false
  }
  # 5. Start whatever is installed now and make sure it is running; if the new version will not start, go back.
  $ok = Start-Widget
  if (-not $ok) { L 'the widget did not start, trying once more'; $ok = Start-Widget }
  if (-not $ok -and $replaced) {
    L 'the new version would not start; rolling back'
    Restore $bak
    $ok = Start-Widget
  }
  if ($ok) { L $(if ($replaced) { 'update done' } else { 'update failed, the previous version is running again' }) }
  else { L 'FAILED: no widget is running' }
} catch {
  L "FAILED: $($_.Exception.Message)"
  try { Restore $bak; [void](Start-Widget) } catch { L "could not restart: $($_.Exception.Message)" }
} finally {
  Remove-Item $stage, $bak -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $Zip -Force -ErrorAction SilentlyContinue
}
