$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Backup-InstallConfig' }, $true)
Invoke-Expression $definition.Extent.Text
$scratch = Join-Path $PSScriptRoot ('.install-config-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  if ($null -ne (Backup-InstallConfig $scratch)) { throw 'Fresh install created a backup' }
  $configFile = Join-Path $scratch 'config.json'
  $content = '{"accounts":[{"name":"existing","source":"codex"}],"look":"custom"}'
  [IO.File]::WriteAllText($configFile, $content)
  $first = Backup-InstallConfig $scratch
  $second = Backup-InstallConfig $scratch
  if ($first -eq $second) { throw 'Repeated installation overwrote a backup' }
  foreach ($file in $configFile, $first, $second) {
    if ([IO.File]::ReadAllText($file) -cne $content) { throw 'Settings were changed or not preserved' }
  }
  [IO.File]::WriteAllText($configFile, '{invalid-json')
  $invalidBackup = Backup-InstallConfig $scratch
  if ([IO.File]::ReadAllText($invalidBackup) -cne '{invalid-json') { throw 'Damaged config was not preserved for recovery' }
  'PASS fresh installation, exact settings preservation, unique backups, damaged-config recovery'
} finally {
  $resolved = [IO.Path]::GetFullPath($scratch)
  $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
  if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like '.install-config-*') {
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
