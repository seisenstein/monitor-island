#!/bin/bash
# Build an ad-hoc-signed DMG containing the app, an /Applications alias, and the
# Install.command. Verifies with hdiutil and prints the path and size.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/MonitorIsland.app"
[ -d "$APP" ] || { echo "app missing; run scripts/package_app.sh first"; exit 1; }

STAGE="$ROOT/dist/dmg_stage"
DMG="$ROOT/dist/MonitorIsland.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/Install.command" "$STAGE/Install.command"
chmod +x "$STAGE/Install.command"
# Ensure the executable bit survives inside the DMG.
xattr -cr "$STAGE" 2>/dev/null || true

echo "[dmg] creating..."
hdiutil create -volname "Monitor Island" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "[dmg] ad-hoc signing the dmg..."
codesign -s - --force "$DMG" >/dev/null 2>&1 || true

echo "[dmg] verifying..."
hdiutil verify "$DMG"

SIZE=$(du -h "$DMG" | cut -f1)
echo "[dmg] path: $DMG"
echo "[dmg] size: $SIZE"
rm -rf "$STAGE"
