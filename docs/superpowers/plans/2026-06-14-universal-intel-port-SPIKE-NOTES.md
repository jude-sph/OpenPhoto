# Universal Intel Port — Spike Notes

**Date:** 2026-06-14
**Machine:** Apple Silicon (arm64) host; x86_64 exercised via Rosetta translation.

## What was validated automatically (x86_64 runtime, under Rosetta)

- `arch -x86_64 swift test`: **437 tests passed, 0 failures** (9.040 s total wall time).
  - Note: plain `swift test --arch x86_64` builds the x86_64 bundle but then fails to launch because
    SwiftPM's test runner process itself is arm64 and cannot dlopen an x86_64 bundle. The fix is to
    invoke the entire swift process under `arch -x86_64` so both the runner and the bundle share the
    same translated architecture.
- This proves runtime correctness on Intel of: the catalog/sync/derivation logic, and specifically the
  new `Float16Codec` (vImage) embedding pack/unpack round-trip — the portability fix that replaced the
  arm64-only `Float16(_:)` conversions. The tests `faceEmbedderLoadsAndProducesA512dVector`,
  `faceEmbedderIsDeterministic`, `embedImageProducesUnitVector`, `embedTextProducesUnitVector`, and
  `imageTextCosineSeparatesConcepts` all passed on x86_64.
- Universal app binary: `lipo -archs build/OpenPhoto.app/Contents/MacOS/OpenPhoto` → **`x86_64 arm64`**.

## What is NOT covered here (needs real Intel hardware — the i9 Tahoe Mac, Task 9)

- Actual CoreML model inference on Intel: AdaFace IR-101 (faces) and MobileCLIP image+text (semantic
  search). The unit tests deliberately do not compile/run the real models. Whether these models
  compile + load + infer with correct results on a real Intel GPU (no Neural Engine) is the open
  question for the i9 acceptance.
- Safety net already in place: the compute-units ladder (`MLLoader.load`: `.all` → `.cpuAndGPU` →
  `.cpuOnly`) gives each model three chances to load; `.cpuOnly` is the universally-compatible floor.
  If a model still can't load, the loud `MLUnavailableBanner` + People/Search unavailable states fire.
- Rosetta caveat: running the x86_64 slice under Rosetta on Apple Silicon does NOT faithfully
  reproduce native-Intel CoreML compute-unit/GPU behavior, so a Rosetta GUI run is only an early
  signal, not authoritative. The i9 native run (Task 9) is authoritative.

## Optional: how to do the Rosetta GUI smoke manually (user)

On this Apple Silicon Mac, to launch the Intel slice translated:

    arch -x86_64 build/OpenPhoto.app/Contents/MacOS/OpenPhoto

Then open a library, scroll, open People, run a text search. If the red ML-unavailable banner appears,
note the hover reason. (Again: Rosetta ≠ native Intel for CoreML.)

## Verdict

All 437 x86_64 tests passed under Rosetta — the core logic and the Float16 portability fix are
runtime-correct on Intel. The only remaining open question is native CoreML model load/inference
on a real Intel Mac (no Neural Engine), which requires the i9 hardware smoke (Task 9).
