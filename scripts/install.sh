#!/bin/bash
# Build OpenPhoto and install it as your stable copy in /Applications, refreshing the icon caches
# so the new icon shows immediately in Dock / Launchpad / Stage Manager. No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

# The build artifact build/OpenPhoto.app is transient — it gets copied to /Applications. If left on
# disk it shows up as a SECOND "OpenPhoto" in Spotlight/Launchpad (a .metadata_never_index marker is
# unreliable — proven), so remove + unregister it on exit. /Applications/OpenPhoto.app is unaffected.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
cleanup_build_app() { rm -rf build/OpenPhoto.app; "$LSREGISTER" -u "$PWD/build/OpenPhoto.app" 2>/dev/null || true; }
trap cleanup_build_app EXIT

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
