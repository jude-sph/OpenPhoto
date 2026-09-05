# Model licensing — current position

OpenPhoto bundles two machine-learning models. Their licences are the only thing
standing between the current build and being freely shareable, so this document
records exactly where each one stands and what the options are. Update it when
the position changes.

Licence texts and attributions for everything OpenPhoto ships live in
`THIRD-PARTY-NOTICES.md` (regenerate with `scripts/gen-notices.sh`).

## Summary

| Component | Licence | Redistributable in a shared build? |
|---|---|---|
| GRDB.swift | MIT | Yes — notice required |
| Sparkle (+ bsdiff, sais-lite, Ed25519) | MIT + BSD | Yes — notices required |
| CLIP tokenizer vocabulary | MIT | Yes — notice required |
| GeoNames place data | CC BY 4.0 | Yes — attribution required, already in Settings → About |
| **MobileCLIP weights** | Apple ML Research Model License | **No** |
| **AdaFace weights** | None stated | **Unclear** |

## MobileCLIP — the blocker

Semantic search uses `mobileclip_s2`, fetched from Apple's Core ML export at
<https://huggingface.co/apple/coreml-mobileclip>.

That model card is labelled `apple-ascl`, which reads as the permissive Apple
Sample Code License — but the label is misleading. Its `license_link` points at
`LICENSE_weights_data` in <https://github.com/apple/ml-mobileclip>, **and that
file does not exist**; the repository contains only `LICENSE`, `LICENSE_DATA`,
`LICENSE_MODELS` and `ACKNOWLEDGEMENTS`. The document that actually governs the
weights is `LICENSE_MODELS`: the Apple Machine Learning Research Model License,
which limits use to non-commercial scientific research and academic development
and explicitly excludes product development or use in any product.

Two consequences worth being precise about:

1. **Bundling the weights in a build we hand to someone is outside that licence.**
2. **So is a first-run download with a click-to-agree screen.** Moving the
   download to the user changes who obtains the file, not what it is used for.
   Sorting family photos is not scientific research, whoever pressed Agree.
   Consent to terms is not the same as conforming to them.

The only change that resolves it is a differently-licensed model.

## AdaFace — unclear rather than restricted

Face grouping uses AdaFace IR-101. The upstream source is MIT (reproduced in
`THIRD-PARTY-NOTICES.md`), but the pretrained weights carry **no stated licence**,
and were trained on MS1MV2 and related datasets that have their own restrictions —
MS1MV2 derives from MS-Celeb-1M, which Microsoft withdrew in 2019.

Silence is not a grant. But because the terms are absent rather than
restrictive, a first-run download from the authors' own distribution is far more
defensible here than for MobileCLIP: the user obtains the file from the source on
whatever terms the authors extend, and OpenPhoto redistributes nothing.

## Options

**A. First-run download instead of bundling.** Ship no weights; fetch on first
launch with the licence shown and accepted. The build already tolerates missing
models (`scripts/make-app.sh:116`, and `MLUnavailableBanner` covers the degraded
state), and it cuts the DMG from ~311 MB to roughly 10 MB. This resolves AdaFace
and GeoNames. **It does not resolve MobileCLIP** — see above.

**B. Replace MobileCLIP with a permissively-licensed encoder.** The only route to
a genuinely shareable build with semantic search intact. Costs a re-embed of the
whole library. Candidate evaluation: `tools/embed-bench/`.

**C. Keep the app private.** Bundle whatever performs best and never distribute.
Note that GitHub Releases are public: the 1.4.0 assets currently ship both models,
so "private" would mean removing those assets too.

## Why this was not caught earlier

The Phase 4.2 plan required a decision record at
`docs/spikes/2026-06-11-mobileclip-coreml.md` capturing the chosen variant and
why. That file was never written — it is absent from the working tree and from
git history — and `EmbedStage`'s `modelID` comment still points readers to it.

The plan's goal line also named MobileCLIP before any evaluation, so its Task 1
compared *variants* (s0/s1/s2), never *families*. The licence question therefore
never arose at the point where it was cheap to answer.

Format changes are guarded by the documentation discipline in `CLAUDE.md`;
dependency choices with licence consequences were not. This document is the
missing half.
