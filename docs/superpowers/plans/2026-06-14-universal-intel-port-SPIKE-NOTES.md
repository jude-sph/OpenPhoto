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

- **Native** Intel CoreML behavior. The real models DID load and infer correctly under Rosetta x86_64
  — the tests above exercise AdaFace IR-101 (a 512-d face vector) and MobileCLIP image+text (unit
  vectors + concept separation) and all passed. That is a strong positive signal that the x86_64
  model-load/inference code path is correct. BUT under Rosetta on Apple Silicon, CoreML runs out of
  process via the host's native CoreML daemon, so the actual compute may be serviced by the Apple
  Silicon GPU/Neural Engine — this does NOT prove the models run on a real Intel GPU with no Neural
  Engine. Confirming native-Intel load + inference (and acceptable speed/memory) is the open question
  for the i9 acceptance (Task 9).
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

All 437 x86_64 tests passed under Rosetta — including the AdaFace + MobileCLIP model tests — so the
core logic, the Float16 portability fix, and the CoreML load/inference code path are runtime-correct
on the x86_64 slice. The only remaining open question is *native* Intel CoreML behavior (real Intel
GPU, no Neural Engine, no Rosetta), which requires the i9 hardware smoke (Task 9).
