#!/bin/bash
# Build OpenPhoto and package it as a shareable, drag-to-Applications DMG. Uses only system tools.
set -euo pipefail
cd "$(dirname "$0")/.."

# Remove the transient build/OpenPhoto.app on exit so it can't show up as a 2nd "OpenPhoto" in
# Spotlight/Launchpad. release.sh sets OPENPHOTO_KEEP_BUILD_APP=1 because it still needs the .app
# (to zip it for the Sparkle update) after this script returns; it does its own cleanup at its end.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
cleanup_build_app() { rm -rf build/OpenPhoto.app; "$LSREGISTER" -u "$PWD/build/OpenPhoto.app" 2>/dev/null || true; }
trap '[[ -n "${OPENPHOTO_KEEP_BUILD_APP:-}" ]] || cleanup_build_app' EXIT

./scripts/make-app.sh
VERSION="$(tr -d '[:space:]' < VERSION)"

STAGE="$(mktemp -d)/OpenPhoto"
mkdir -p "$STAGE"
cp -R build/OpenPhoto.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Installing OpenPhoto
--------------------
1. Drag OpenPhoto onto the Applications folder shown here.
2. The FIRST time you open it, macOS may say it "cannot verify" the app (because it isn't
   signed with a paid Apple Developer ID). This is expected.
   - Right-click (or Control-click) OpenPhoto in Applications and choose "Open", then "Open" again,
     OR open System Settings > Privacy & Security, scroll down, and click "Open Anyway".
   - You only do this once. Future updates install silently.
3. On first launch, choose your photo folder (e.g. your Pictures folder).

Your photos are never modified or moved. Delete OpenPhoto anytime — your files are untouched.
TXT

DMG="build/OpenPhoto-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "OpenPhoto ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"
echo "Built $DMG"
