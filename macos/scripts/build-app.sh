#!/bin/bash
# Builds "Claude Usage.app" into macos/build/. Needs the Xcode Command Line Tools
# (xcode-select --install) or Xcode, on macOS 13 or later.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Claude Usage.app"

echo "==> Building (release)"
# UNIVERSAL=1 builds for Apple Silicon and Intel (needs full Xcode); the default is this Mac's chip.
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeUsageBar" "$APP/Contents/MacOS/ClaudeUsageBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon from the repo's assets/icon.png (optional; the app works without it).
ICON_PNG="$ROOT/../assets/icon.png"
if [ -f "$ICON_PNG" ] && command -v iconutil >/dev/null && command -v sips >/dev/null; then
  ICON_TMP="$(mktemp -d)"
  trap 'rm -rf "$ICON_TMP"' EXIT
  ICONSET="$ICON_TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    double=$((size * 2))
    sips -z $double $double "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
    || echo "    (icon skipped)"
fi

# Ad-hoc signature: enough for an app you built yourself to run and to register as a login item.
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
