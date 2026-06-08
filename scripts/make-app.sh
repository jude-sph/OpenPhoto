#!/bin/bash
# Assemble OpenPhoto.app from the SwiftPM release build (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/OpenPhoto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenPhotoApp "$APP/Contents/MacOS/OpenPhoto"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>OpenPhoto</string>
    <key>CFBundleIdentifier</key><string>dev.jude.openphoto</string>
    <key>CFBundleName</key><string>OpenPhoto</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
