#!/bin/bash
# Assemble OpenPhoto.app from the SwiftPM release build (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

VERSION="$(tr -d '[:space:]' < VERSION)"
# VERSION feeds CFBundleShortVersionString and the DMG name, and Sparkle parses it as a version —
# reject anything that isn't a plain dotted-numeric so a stray char can't ship a broken Info.plist.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: VERSION ('$VERSION') must be dotted-numeric, e.g. 0.1.0" >&2; exit 1
fi
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"   # monotonically increasing; Sparkle compares this

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
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__BUILD__</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSPhotoLibraryUsageDescription</key><string>OpenPhoto imports photos you choose from your Apple Photos library. It only ever copies them out and never modifies your Photos library.</string>
</dict>
</plist>
PLIST

sed -i '' "s|__VERSION__|${VERSION}|; s|__BUILD__|${BUILD}|" "$APP/Contents/Info.plist"
if grep -q '__VERSION__\|__BUILD__' "$APP/Contents/Info.plist"; then
  echo "error: version tokens not substituted in Info.plist (heredoc/sed drift?)" >&2; exit 1
fi

# App icon — always build a FULL multi-resolution .icns from a 1024px source. (A single-rep .icns
# renders blank in surfaces that request a small rep, e.g. the minimized/Stage-Manager strip.)
ICON_SRC="IconKitchen-Output/macos/AppIcon1024.png"
[[ -f "$ICON_SRC" ]] || ICON_SRC="$(ls -t OpenPhoto-*-1024x1024@1x.png 2>/dev/null | grep -v -- '-old' | head -1)"
if [[ -n "${ICON_SRC:-}" && -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/OpenPhoto.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OpenPhoto.icns"
  rm -rf "$(dirname "$ICONSET")"
  echo "Built multi-size OpenPhoto.icns from $ICON_SRC"
else
  echo "warning: no 1024px icon source found — app will use the generic icon"
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
