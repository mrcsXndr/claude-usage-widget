# Builds the two release assets from HEAD:
#   dist\ClaudeUsageWidget.zip  what Install.cmd users unzip and install.ps1 downloads
#   dist\install.ps1            the one-line installer (irm .../releases/latest/download/install.ps1 | iex)
# git archive applies .gitattributes, so .ps1 and .cmd files get Windows line endings.
#   powershell -NoProfile -File tools\Build-Release.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dist = Join-Path $root 'dist'
$out = Join-Path $dist 'ClaudeUsageWidget.zip'
New-Item -ItemType Directory -Force $dist | Out-Null
git -C $root archive --format=zip -o $out HEAD `
  ClaudeUsageWidget.ps1 lib uninstall.ps1 install.ps1 Install.cmd assets/icon.ico LICENSE README.md CHANGELOG.md
if ($LASTEXITCODE) { throw 'git archive failed' }
$installer = @(git -C $root show HEAD:install.ps1)
if ($LASTEXITCODE) { throw 'git show failed' }
[IO.File]::WriteAllText((Join-Path $dist 'install.ps1'), (($installer -join "`r`n") + "`r`n"))
"wrote $out ($([int]((Get-Item $out).Length / 1KB)) KB) and $(Join-Path $dist 'install.ps1')"
