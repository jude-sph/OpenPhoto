#!/bin/bash
# Cut and publish a new OpenPhoto release: build the app + DMG, zip it, sign + regenerate the
# Sparkle appcast, create a GitHub Release with the artifacts, and publish the appcast to GitHub
# Pages. Requires: `gh` (authenticated), Sparkle's generate_appcast (in .build — run `swift build`
# first), and the EdDSA private key in your login Keychain (generated once via generate_keys).
# See docs/RELEASING.md for one-time setup.
#
# Usage:
#   scripts/release.sh
#
# Prerequisites (see docs/RELEASING.md):
#   1. gh installed and authenticated (`gh auth login`)
#   2. swift build run at least once so Sparkle's tools are present in .build
#   3. scripts/sparkle_public_key.txt populated (the public key, committed)
#   4. EdDSA private key in your login Keychain (stored there by generate_keys in one-time setup)
#   5. GitHub Pages enabled on the gh-pages branch for jude-sph/OpenPhoto
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
echo "Releasing ${TAG} …"

# 1. Build artifacts.
./scripts/make-dmg.sh                       # build/OpenPhoto-<v>.dmg (also builds the .app)
RELDIR="build/release-archives"
rm -rf "$RELDIR"; mkdir -p "$RELDIR"
ditto -c -k --keepParent build/OpenPhoto.app "$RELDIR/OpenPhoto-${VERSION}.zip"

# 2. Sign + (re)generate the appcast from the ZIP ONLY. The DMG is a human download, not a Sparkle
#    update channel — keeping it out of the scanned dir gives the feed one clean enclosure.
#    generate_appcast reads the private key from your login Keychain (expect a one-time Keychain
#    access prompt — click "Always Allow") and writes appcast.xml into RELDIR.
GENAPPCAST="$(find .build -path '*/Sparkle/bin/generate_appcast' -o -name generate_appcast -type f 2>/dev/null | head -1)"
if [[ -z "$GENAPPCAST" ]]; then
  echo "error: generate_appcast not found in .build — run 'swift build' first" >&2
  exit 1
fi
echo "Using generate_appcast: $GENAPPCAST"
"$GENAPPCAST" \
  --download-url-prefix "https://github.com/jude-sph/OpenPhoto/releases/download/${TAG}/" \
  "$RELDIR"

# 3. Create the GitHub Release with the zip + dmg.
gh release create "$TAG" \
  "$RELDIR/OpenPhoto-${VERSION}.zip" "build/OpenPhoto-${VERSION}.dmg" \
  --title "OpenPhoto ${VERSION}" --notes "OpenPhoto ${VERSION}"

# 4. Publish appcast.xml to the gh-pages branch (served at the SUFeedURL). Done in a throwaway clone
#    so it's portable across git versions (avoids `git worktree add --orphan`, which needs git ≥ 2.42)
#    and never disturbs the current checkout. Handles both first-creation and updates.
PUB="$(mktemp -d)"
REMOTE_URL="$(git remote get-url origin)"
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
  git clone -q --branch gh-pages --single-branch "$REMOTE_URL" "$PUB"
else
  git init -q "$PUB"
  git -C "$PUB" checkout -q -b gh-pages
  git -C "$PUB" remote add origin "$REMOTE_URL"
fi
cp "$RELDIR/appcast.xml" "$PUB/appcast.xml"
git -C "$PUB" add appcast.xml
git -C "$PUB" -c user.email="$(git config user.email)" -c user.name="$(git config user.name)" \
  commit -qm "appcast: OpenPhoto ${VERSION}"
git -C "$PUB" push -q origin gh-pages
rm -rf "$PUB"

echo ""
echo "Released ${TAG}. GitHub Pages takes ~1 minute to publish."
echo "Verify the live appcast:"
echo "  curl -s https://jude-sph.github.io/OpenPhoto/appcast.xml | head"
