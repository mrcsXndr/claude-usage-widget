#!/bin/bash
# Removes Claude Usage and its settings. Your Claude Code logins are never touched.
# Add --keep-settings to keep config.json for a later reinstall.
set -euo pipefail

APP="$HOME/Applications/Claude Usage.app"
SETTINGS="$HOME/Library/Application Support/claude-usage-widget"

pkill -x ClaudeUsageBar 2>/dev/null || true
rm -rf "$APP" "/Applications/Claude Usage.app"
defaults delete io.github.claude-usage-widget.mac >/dev/null 2>&1 || true

if [ "${1:-}" != "--keep-settings" ]; then
  rm -rf "$SETTINGS"
fi

echo "Claude Usage removed."
echo "If it still appears under System Settings > General > Login Items, remove it there."
