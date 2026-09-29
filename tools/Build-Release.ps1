# Builds dist\ClaudeUsageWidget.zip from HEAD: the file a release ships and install.ps1 downloads.
# git archive applies .gitattributes, so .ps1 and .cmd files get Windows line endings.
#   powershell -NoProfile -File tools\Build-Release.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$out = Join-Path $root 'dist\ClaudeUsageWidget.zip'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
git -C $root archive --format=zip -o $out HEAD `
  ClaudeUsageWidget.ps1 lib uninstall.ps1 install.ps1 Install.cmd assets/icon.ico LICENSE README.md
if ($LASTEXITCODE) { throw 'git archive failed' }
"wrote $out ($([int]((Get-Item $out).Length / 1KB)) KB)"
