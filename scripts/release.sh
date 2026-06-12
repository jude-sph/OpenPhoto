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
cp "build/OpenPhoto-${VERSION}.dmg" "$RELDIR/"

# 2. Sign + (re)generate the appcast. generate_appcast reads the private key from the Keychain and
#    writes appcast.xml into RELDIR, pointing downloads at the GitHub Releases asset URLs.
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
  "$RELDIR/OpenPhoto-${VERSION}.zip" "$RELDIR/OpenPhoto-${VERSION}.dmg" \
  --title "OpenPhoto ${VERSION}" --notes "OpenPhoto ${VERSION}"

# 4. Publish appcast.xml to the gh-pages branch (served at the SUFeedURL).
#    Use a temporary worktree so this doesn't disturb the current checkout.
git fetch origin gh-pages 2>/dev/null || true
WORKTREE="$(mktemp -d)"
if git worktree add "$WORKTREE" gh-pages 2>/dev/null; then
  :
else
  # gh-pages doesn't exist locally yet — create it tracking origin
  git worktree add "$WORKTREE" -b gh-pages origin/gh-pages 2>/dev/null \
    || git worktree add --orphan -b gh-pages "$WORKTREE"
fi
cp "$RELDIR/appcast.xml" "$WORKTREE/appcast.xml"
( cd "$WORKTREE" && git add appcast.xml \
    && git commit -m "appcast: OpenPhoto ${VERSION}" && git push origin gh-pages )
git worktree remove "$WORKTREE"

echo ""
echo "Released ${TAG}. GitHub Pages takes ~1 minute to publish."
echo "Verify the live appcast:"
echo "  curl -s https://jude-sph.github.io/OpenPhoto/appcast.xml | head"
