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
    <key>NSPhotoLibraryUsageDescription</key><string>OpenPhoto imports photos you choose from your Apple Photos library. It only ever copies them out and never modifies your Photos library.</string>
</dict>
</plist>
PLIST

# App icon. Prefer a ready-made macOS .icns (IconKitchen's macos/AppIcon.icns is already the correct
# macOS sizes, margins, and shadow). Otherwise build OpenPhoto.icns from a 1024px source PNG —
# preferring IconKitchen's macos/AppIcon1024.png, then a macOS-named source, then the newest
# "OpenPhoto-*-1024x1024@1x.png" that isn't an archived "-old" copy.
PREBUILT_ICNS="IconKitchen-Output/macos/AppIcon.icns"
if [[ -f "$PREBUILT_ICNS" ]]; then
  cp "$PREBUILT_ICNS" "$APP/Contents/Resources/OpenPhoto.icns"
else
  ICON_SRC="IconKitchen-Output/macos/AppIcon1024.png"
  [[ -f "$ICON_SRC" ]] || ICON_SRC="OpenPhoto-macOS-Default-1024x1024@1x.png"
  [[ -f "$ICON_SRC" ]] || ICON_SRC="$(ls -t OpenPhoto-*-1024x1024@1x.png 2>/dev/null | grep -v -- '-old' | head -1)"
  if [[ -n "$ICON_SRC" && -f "$ICON_SRC" ]]; then
    ICONSET="$(mktemp -d)/OpenPhoto.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
      sips -z "$((s * 2))" "$((s * 2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OpenPhoto.icns"
    rm -rf "$(dirname "$ICONSET")"
  fi
fi

# On-device ML models + CLIP vocab (gitignored, fetched into .models/Resources/). EmbedStage loads
# them lazily from the app bundle's Resources at runtime; the build tolerates their absence, so this
# copy is best-effort — skip silently if the models haven't been fetched on this machine.
MODELS_SRC=".models/Resources"
if [[ -d "$MODELS_SRC" ]]; then
  for f in "$MODELS_SRC"/mobileclip_s2_image.mlpackage \
           "$MODELS_SRC"/mobileclip_s2_text.mlpackage \
           "$MODELS_SRC"/bpe_simple_vocab_16e6.txt.gz; do
    [[ -e "$f" ]] && cp -R "$f" "$APP/Contents/Resources/"
  done
  echo "Injected MobileCLIP models + vocab into $APP/Contents/Resources/"
  [[ -d "$MODELS_SRC/geonames" ]] && cp -R "$MODELS_SRC/geonames" "$APP/Contents/Resources/" \
    && echo "Injected GeoNames dataset into $APP/Contents/Resources/geonames/"
else
  echo "note: $MODELS_SRC absent — shipping without semantic-search models (search degrades)"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
