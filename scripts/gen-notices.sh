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
- [MobileCLIP models](#mobileclip-models) — Apple ML Research Model Licence
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

## MobileCLIP models

Image and text encoders used for semantic search.
<https://github.com/apple/ml-mobileclip> · <https://huggingface.co/apple/coreml-mobileclip>

The MobileCLIP **code** is MIT-licensed, but the **model weights** are governed
separately by the Apple Machine Learning Research Model License
(`LICENSE_MODELS` in the repository above), which limits use to non-commercial
scientific research and academic development and excludes product use.

> **Redistribution status: unresolved.** These weights are not redistributable
> under that licence as part of a general-purpose application. See
> `docs/model-licensing.md` for the current position and options.

---

## AdaFace

Face-recognition model (IR-101) used for people grouping.
<https://github.com/mk-minchul/AdaFace>

The AdaFace source is MIT-licensed, reproduced below. The **pretrained weights**
carry no stated licence in the upstream repository, and were trained on datasets
(MS1MV2 and related) with their own restrictions. Absence of stated terms is not
a grant.

```
C
cat licenses/AdaFace-LICENSE.txt; echo
cat <<'D'
```
D
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
