set -e
OUT="THIRD-PARTY-NOTICES.md"
{
cat <<'HDR'
# Third-party notices

OpenPhoto bundles the components below. Each retains its own licence; the full
text of every licence requiring reproduction is included verbatim in this file.

Generated from the licence files shipped with each dependency — see
`scripts/gen-notices.sh` to regenerate after a dependency change.

## Contents

- [GRDB.swift](#grdbswift) — MIT
- [Sparkle](#sparkle) — MIT, plus external BSD-licensed components
- [CLIP tokenizer vocabulary](#clip-tokenizer-vocabulary) — MIT
- [GeoNames place data](#geonames-place-data) — CC BY 4.0
- [OpenCLIP ViT-B/32](#openclip-vit-b32) — MIT
- [AdaFace](#adaface) — MIT (code); weights carry no stated terms

---

## GRDB.swift

SQLite persistence layer. <https://github.com/groue/GRDB.swift>

```
HDR
cat .build/checkouts/GRDB.swift/LICENSE; echo
cat <<'A'
```

---

## Sparkle

Self-update framework, embedded in the app bundle as `Sparkle.framework`.
<https://github.com/sparkle-project/Sparkle>

```
A
cat .build/checkouts/Sparkle/LICENSE; echo
cat <<'B'
```

---

## CLIP tokenizer vocabulary

`bpe_simple_vocab_16e6.txt` — the byte-pair-encoding vocabulary used by the text
encoder. <https://github.com/openai/CLIP>

```
B
cat licenses/openai-CLIP-LICENSE.txt; echo
cat <<'C'
```

---

## GeoNames place data

Reverse-geocoding dataset bundled in `Resources/geonames/`.
<https://www.geonames.org>

Licensed under Creative Commons Attribution 4.0
(<https://creativecommons.org/licenses/by/4.0/>). Attribution is required and is
surfaced in the app under Settings → About.

> Place data © GeoNames (geonames.org), CC BY 4.0.

---

## OpenCLIP ViT-B/32

Image and text encoders used for semantic search.
<https://huggingface.co/laion/CLIP-ViT-B-32-laion2B-s34B-b79K>

Released under the MIT licence, which permits redistribution of the weights as
part of this application. Trained by LAION on the LAION-2B dataset; the
architecture and training code originate from OpenCLIP
(<https://github.com/mlfoundations/open_clip>).

The model files shipped in `Resources/` are Core ML conversions of those
weights, produced by `tools/embed-bench/export_app_model.py` and numerically
verified against the PyTorch reference. They are unmodified in substance.

---

## AdaFace

Face-recognition model (IR-101) used for people grouping.
<https://github.com/mk-minchul/AdaFace>

The AdaFace source is MIT-licensed, reproduced below. The **pretrained weights**
carry no stated licence in the upstream repository, and were trained on datasets
(MS1MV2 and related) with their own restrictions. Absence of stated terms is not
a grant.

> These weights ship in every build. Face recognition and grouping depend on
> them, and the absent-terms question is a known, accepted risk rather than an
> oversight. See `docs/model-licensing.md`.

```
C
cat licenses/AdaFace-LICENSE.txt; echo
cat <<'D'
```
D
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
