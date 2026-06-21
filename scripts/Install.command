#!/bin/bash
# Monitor Island one-time installer. Clears the macOS quarantine flag so the
# ad-hoc-signed (un-notarized) app launches without the Gatekeeper block.
# Double-click this file after dragging Monitor Island to Applications.

APP="MonitorIsland.app"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "Monitor Island installer"
echo "------------------------"

# If the app sits next to this command (e.g. on the mounted DMG) and is not yet
# in /Applications, offer to copy it.
if [ -d "$HERE/$APP" ] && [ ! -d "/Applications/$APP" ]; then
  echo "Copying $APP to /Applications ..."
  cp -R "$HERE/$APP" "/Applications/" 2>/dev/null
fi

# Strip quarantine wherever the app may be.
for TARGET in "/Applications/$APP" "$HERE/$APP" "$HOME/Applications/$APP"; do
  if [ -d "$TARGET" ]; then
    echo "Clearing quarantine on: $TARGET"
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
  fi
done

if [ -d "/Applications/$APP" ]; then
  echo "Launching Monitor Island ..."
  open "/Applications/$APP"
  echo "Done. Look for the 'MI' item in your menu bar and the floating island near the top of the screen."
else
  echo "Could not find $APP in /Applications. Drag it there first, then run this again."
fi

echo ""
echo "You can close this window."
