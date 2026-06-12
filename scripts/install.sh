#!/bin/bash
# Build OpenPhoto and install it as your stable copy in /Applications, refreshing the icon caches
# so the new icon shows immediately in Dock / Launchpad / Stage Manager. No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

DEST="/Applications/OpenPhoto.app"
echo "Installing to $DEST …"
rm -rf "$DEST"
cp -R build/OpenPhoto.app "$DEST"

# Bust LaunchServices' icon cache so Dock/Launchpad/Stage-Manager pick up the new icon.
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$DEST" || true
killall Dock Finder 2>/dev/null || true

echo "Installed OpenPhoto $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")."
echo "Launch from Launchpad/Spotlight, or: open \"$DEST\""
