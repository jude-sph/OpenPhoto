# Model licensing — current position

OpenPhoto's third-party licence texts live in `THIRD-PARTY-NOTICES.md`
(regenerate with `scripts/gen-notices.sh`). This document records the position on
the machine-learning models specifically, because they are the only components
whose terms have ever constrained what can be shared.

## Summary

| Component | Licence | In a public build? |
|---|---|---|
| GRDB.swift | MIT | Yes — notice required |
| Sparkle (+ bsdiff, sais-lite, Ed25519) | MIT + BSD | Yes — notices required |
| CLIP tokenizer vocabulary | MIT | Yes — notice required |
| GeoNames place data | CC BY 4.0 | Yes — attribution in Settings → About |
| OpenCLIP ViT-B/32 weights | MIT | **Yes** |
| AdaFace weights | None stated | **Yes — accepted risk** |
| MobileCLIP weights | Apple ML Research Model License | **No — removed** |

## Semantic search: MobileCLIP → OpenCLIP ViT-B/32

Semantic search previously used `mobileclip_s2` from Apple's Core ML export. That
model card is labelled `apple-ascl`, suggesting the permissive Apple Sample Code
License, but the label is misleading: its `license_link` points at
`LICENSE_weights_data` in <https://github.com/apple/ml-mobileclip>, **a file that
does not exist there**. The document actually governing the weights is
`LICENSE_MODELS` — the Apple Machine Learning Research Model License, limited to
non-commercial scientific research and academic development, explicitly excluding
product use.

Bundling those weights in a build handed to someone else is outside that licence.
So is a first-run download behind a click-to-agree screen: moving the download to
the user changes who obtains the file, not what it is used for. Sorting family
photos is not scientific research, whoever pressed Agree.

The replacement is `laion/CLIP-ViT-B-32-laion2B-s34B-b79K` — **MIT**, so the
weights are redistributable. It was chosen by measurement, not assumption:
`tools/embed-bench/` compares candidates on this Mac for both retrieval quality
and real ANE latency.

| Model | Licence | ms/image | Size | Full 19,473-photo pass |
|---|---|---|---|---|
| mobileclip_s2 | Research only | 2.48 | 68 MB | ~0.8 min |
| **openclip_b32** | **MIT** | **6.10** | **168 MB** | **~2 min** |
| openclip_l14 | MIT | 31.20 | 580 MB | ~10 min |

The permissive option costs roughly 2.5x per image — under two minutes for a full
re-embed — which is a cheap price for a redistributable build.

SigLIP (Apache-2.0) was the intended third candidate and remains worth revisiting:
its `MultiheadAttentionPoolingHead` fails Core ML conversion under both SDPA and
eager attention. Its licence is fine; only the conversion is blocked.

### Consequences of the swap

`modelID` is stored per embedding row, so changing it from `mobileclip_s2` to
`openclip_b32` invalidates every existing embedding. They are recomputed on the
next derivation pass (~2 minutes for ~19k photos); semantic search is degraded
until that completes. Nothing else is affected — embeddings are machine-derived
catalog data, never authored metadata.

The tokenizer needed no change: laion's B/32 uses the same CLIP BPE vocabulary
already shipped (49408 tokens, BOS 49406, EOS 49407, 77-token context).

## Face recognition: AdaFace stays local

AdaFace IR-101's source is MIT, but its pretrained weights carry **no stated
licence**, and were trained on MS1MV2 and related datasets with their own
restrictions — MS1MV2 derives from MS-Celeb-1M, which Microsoft withdrew in 2019.
Silence is not a grant.

These weights ship in every build. Face recognition and grouping are core to
the app, and dropping them was judged not worth it over a question of absent
rather than restrictive terms. This is a deliberate, accepted risk — recorded
here so it stays a decision rather than drifting into an assumption.

(1.5.1 briefly shipped without them. That was a unilateral call made while
resolving the MobileCLIP licence and was reverted in 1.5.2.)

Resolving this properly would need either a permissively-licensed face-embedding
model, or a first-run download from the authors' own distribution — defensible
here in a way it is not for MobileCLIP, because the terms are absent rather than
restrictive.

## Distribution status

Everything shipped is redistributable except the AdaFace weights, whose terms
are simply unstated — an accepted risk, above. Two obligations travel with any
build:

1. `THIRD-PARTY-NOTICES.md` must ship in the bundle — `make-app.sh` hard-fails
   without it.
2. GeoNames attribution must remain visible (Settings → About).

**OpenPhoto's own licence is still unset**, which by default means all rights
reserved. That is a deliberate open decision, not an oversight.

## Why this went unnoticed for so long

The Phase 4.2 plan required a decision record at
`docs/spikes/2026-06-11-mobileclip-coreml.md` capturing the chosen variant and
why. It was never written — absent from both the working tree and git history —
and `EmbedStage`'s comment still pointed readers to it.

The plan's goal line also named MobileCLIP before any evaluation, so its Task 1
compared *variants* (s0/s1/s2), never *families*. The licence question therefore
never arose at the point where it was cheap to answer.

Format changes are guarded by the documentation discipline in `CLAUDE.md`;
dependency choices with licence consequences were not. This document is the
missing half.
