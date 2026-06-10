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
    <key>CFBundleIconFile</key><string>OpenPhoto</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon — build OpenPhoto.icns from the 1024px source PNG if present.
ICON_SRC="OpenPhoto-macOS-Default-1024x1024@1x.png"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/OpenPhoto.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OpenPhoto.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
