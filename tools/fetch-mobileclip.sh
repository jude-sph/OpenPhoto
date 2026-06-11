#!/usr/bin/env bash
# Fetch Apple's official Core ML MobileCLIP image + text encoders + the CLIP BPE vocab for the
# Phase 4.2 semantic-search embedding stage. Downloads into .models/Resources/ (gitignored — run
# once at dev setup). No coremltools / PyTorch needed — the .mlpackages are pre-converted.
# EmbedStage loads these lazily from the app bundle's Resources at runtime (make-app.sh injects
# .models/Resources/ into OpenPhoto.app); the build tolerates their absence (search degrades).
# Sources: https://huggingface.co/apple/coreml-mobileclip  +  https://github.com/openai/CLIP
#
# Usage: tools/fetch-mobileclip.sh [variant]   # variant: s0 (~108MB) | s1 | s2 (~198MB, default) | blt
set -euo pipefail
VARIANT="${1:-s2}"
BASE="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
DEST="$(cd "$(dirname "$0")/.." && pwd)/.models/Resources"
mkdir -p "${DEST}"

# Image + text encoders (each .mlpackage = Manifest.json + Data/com.apple.CoreML/{model.mlmodel,weights/weight.bin})
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

# CLIP BPE tokenizer vocab (the text encoder needs this to embed query strings)
echo "Fetching bpe_simple_vocab_16e6.txt.gz ..."
curl -fL --retry 3 -o "${DEST}/bpe_simple_vocab_16e6.txt.gz" \
  "https://github.com/openai/CLIP/raw/main/clip/bpe_simple_vocab_16e6.txt.gz"

echo "Done -> ${DEST}"
