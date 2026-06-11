#!/usr/bin/env bash
# Fetch Apple's official Core ML MobileCLIP image + text encoders for the Phase 4.2 embedding stage.
# Downloads into Sources/OpenPhotoCore/Resources/ (gitignored — run once at dev setup; the build
# bundles whatever is there). No coremltools / PyTorch needed — these are pre-converted .mlpackages.
# Source: https://huggingface.co/apple/coreml-mobileclip
#
# Usage: tools/fetch-mobileclip.sh [variant]   # variant: s0 (~108MB) | s1 | s2 (~198MB, default) | blt
set -euo pipefail
VARIANT="${1:-s2}"
BASE="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Sources/OpenPhotoCore/Resources"
for kind in image text; do
  pkg="mobileclip_${VARIANT}_${kind}.mlpackage"
  echo "Fetching ${pkg} ..."
  mkdir -p "${DEST}/${pkg}/Data/com.apple.CoreML/weights"
  curl -fL --retry 3 -o "${DEST}/${pkg}/Manifest.json" \
    "${BASE}/${pkg}/Manifest.json"
  curl -fL --retry 3 -o "${DEST}/${pkg}/Data/com.apple.CoreML/model.mlmodel" \
    "${BASE}/${pkg}/Data/com.apple.CoreML/model.mlmodel"
  curl -fL --retry 3 -o "${DEST}/${pkg}/Data/com.apple.CoreML/weights/weight.bin" \
    "${BASE}/${pkg}/Data/com.apple.CoreML/weights/weight.bin"
done
echo "Done -> ${DEST}"
