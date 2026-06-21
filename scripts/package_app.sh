#!/bin/bash
# Build a Release .app bundle for Monitor Island (SwiftPM + hand-assembled bundle),
# ad-hoc sign it, and print the path. No Xcode required (CLT only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MonitorIsland"
BUNDLE_ID="com.seisenstein.monitorisland"
VERSION="1.0.0"

echo "[package] building Release..."
swift build -c release >/dev/null

BIN="$ROOT/.build/release/$APP_NAME"
[ -x "$BIN" ] || { echo "build product missing: $BIN"; exit 1; }

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp -R "$ROOT/Sources/MonitorIsland/Resources/fonts" "$APP/Contents/Resources/fonts"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Monitor Island</string>
  <key>CFBundleDisplayName</key><string>Monitor Island</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

echo "[package] ad-hoc signing..."
codesign -s - --force --deep "$APP" >/dev/null 2>&1

echo "[package] verifying signature..."
codesign --verify --strict --verbose=2 "$APP"

echo "[package] app at: $APP"
echo "$APP"
