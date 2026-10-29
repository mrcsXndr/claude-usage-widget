#!/bin/bash
# Builds the app, copies it to ~/Applications and starts it.
# Running it again updates the app and keeps your settings.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="$HOME/Applications"
APP_NAME="Claude Usage.app"

if ! command -v swift >/dev/null; then
  echo "Swift isn't installed. Run: xcode-select --install  (then run this script again)" >&2
  exit 1
fi

./scripts/build-app.sh

# Quit a running copy before replacing it.
pkill -x ClaudeUsageBar 2>/dev/null && sleep 1 || true

mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME"
cp -R "build/$APP_NAME" "$DEST/"

echo "==> Installed to $DEST/$APP_NAME"
open "$DEST/$APP_NAME"
echo "==> The rings are in your menu bar. Click them for the account list."
