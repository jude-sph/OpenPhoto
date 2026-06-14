# Universal binary: Intel + Apple Silicon — Design

**Date:** 2026-06-14
**Status:** Approved (floor = macOS 14; Monterey out of scope; zero logic/UI rewrite).

## Problem

OpenPhoto ships as an **arm64-only** binary (`swift build -c release` builds for the host arch only),
so it does not run on Intel Macs. Two target machines motivated this:

- **i9 Mac on macOS Tahoe (26.5.1)** — modern, strong Intel hardware. In scope.
- **A Mac pinned to Monterey (12.7.6)** — ~2015 hardware, hardware-locked to macOS 12. **Out of scope**
  (see "Decisions"). Supporting it would force a broad view-layer compatibility sweep for a machine
  that would also be weak at the app's ML features.

The requirement: **one codebase, one `.app`, one update feed** — not a fork.

## Approach

Ship a **universal binary** (arm64 + x86_64). A universal binary is a single codebase, a single
`.app` bundle, and a single Sparkle appcast; macOS selects the native slice per machine. The only
moving parts are: the deployment floor (one number in `Package.swift`), the release packaging
(build both arches + fix output paths), and **verification that the CoreML models run on Intel**.

No engine, vault, sync, catalog, or UI logic changes. The dependencies already cooperate:
GRDB 7 supports macOS 10.15, and **Sparkle is vended as a universal xcframework** (its `.framework`
already carries both `x86_64` and `arm64` slices).

### The one real risk — CoreML on Intel

Three CoreML models are loaded at runtime and compiled on demand via `MLModel.compileModel`, both with
`computeUnits = .all`:

| Model | Loader | Feature |
|---|---|---|
| AdaFace IR-101 (`AdaFaceIR101.mlpackage`) | `OpenPhotoCore/Faces/FaceEmbedder.swift` | Face recognition |
| MobileCLIP image (`mobileclip_s2_image.mlpackage`) | `OpenPhotoCore/Derivation/EmbedStage.swift` | Semantic search |
| MobileCLIP text (`mobileclip_s2_text.mlpackage`) | `OpenPhotoCore/Derivation/EmbedStage.swift` | Semantic search |

On Intel there is **no Neural Engine**, so `.all` auto-resolves to CPU + GPU (Metal). Whether these
specific models **compile, load, and infer with correct results** on Intel is the only genuine
unknown. It is settled by a spike before any other work proceeds.

## Components / changes

| Unit | Change |
|---|---|
| `Package.swift` | `.macOS(.v15)` → `.macOS(.v14)`. Fix any macOS-15-only API the compiler flags (sweep found none expected; if one appears, guard it with `#available` or keep the floor at 15). |
| `EmbedStage.swift`, `FaceEmbedder.swift` | **Loud ML-unavailable handling:** never crash, but **never silently degrade either**. If a model fails to initialize, capture the reason and surface it prominently (see "ML availability surfacing"). If the spike shows `.all` is flaky on Intel, add an arch-aware compute-units fallback (`.cpuAndGPU` → `.cpuOnly`) *before* declaring a model unavailable. |
| **ML availability surfacing** (App) | A single observable signal on `AppState` (e.g. `mlUnavailable: [model: reason]`) drives a **persistent, prominent banner** ("Face recognition is unavailable on this Mac — the model couldn't be loaded. Details…") plus an explicit unavailable state on the affected feature surfaces (People view, Search) — not an empty/blank screen. Also logged loudly (`os_log` `.fault`/`.error`). The user must never be left guessing why faces or search are missing. |
| `scripts/make-app.sh` | Build with `swift build -c release --arch arm64 --arch x86_64`. Update the binary path (`.build/release/OpenPhotoApp` → `.build/apple/Products/Release/OpenPhotoApp`) and the `Sparkle.framework` discovery path to the universal products dir. Add a `lipo -archs` assertion that both slices are present (refuse to package an accidentally single-arch binary, mirroring the existing Sparkle-key refusal). `LSMinimumSystemVersion` 15.0 → 14.0. |
| Dev loop | Plain `swift build` stays **host-only** for fast iteration; only release packaging (`make-app.sh`) goes universal. |
| CI release workflow | Update the build invocation to the universal `--arch arm64 --arch x86_64` command. |
| `docs/RELEASING.md` | Document the universal build command + the `lipo` verification step. |
| `README.md` | Requirements: **Intel + Apple Silicon, macOS 14+**. |
| `docs/format/` | **No change** — the on-disk vault format is unaffected. (SHA-256 hashing is arch-independent; both arches are little-endian, so catalog/embedding blobs are byte-identical cross-arch.) Recording this explicitly satisfies the documentation-discipline rule. |

## Spike (gating — first, before everything else)

1. Build universal: `swift build -c release --arch arm64 --arch x86_64`. Confirm the products land in
   `.build/apple/Products/Release/` and `lipo -archs` shows `x86_64 arm64`.
2. **Rosetta pre-smoke (AS Mac, cheap):** `arch -x86_64 …/OpenPhoto.app/Contents/MacOS/OpenPhoto`.
   Confirms the x86_64 slice launches and runs. Caveat: Rosetta does **not** faithfully reproduce
   native-Intel CoreML compute-unit/GPU behavior, so it is an early warning, not the acceptance test.
3. **Authoritative (i9 Tahoe Mac):** run the native x86_64 slice and confirm each of the three models
   compiles, loads, and infers with **sane results** (face embeddings cluster correctly; a known
   text query returns the expected photo). Record load time + memory.
4. **Decision point:** if a model fails or `.all` misbehaves on Intel → first try the compute-units
   fallback. If a model still cannot run, the feature ships **disabled but loudly surfaced** (banner +
   explicit unavailable state), never silently blank — everything non-ML ships regardless.

## Acceptance (Jude's hardware — tested at the end)

On the **i9 Tahoe Mac**, native:
- Launches; library browse; import a batch.
- **Face recognition** produces correct clusters; **semantic search** returns expected results.
- **Sparkle self-update** downloads and installs the universal archive (one feed, both arches).

The Rosetta pre-smoke on the Apple Silicon Mac is the early-warning gate before the i9 run.

## Decisions (resolved during brainstorming)

- **Floor = macOS 14, not 12.** The Monterey Mac is hardware-locked to 12 and would force backporting
  the Observation framework (`@Observable` ×3, `@Bindable` ×36) plus `Grid`/`GridRow` (×24),
  `onChange` signatures (×13), `ContentUnavailableView` (×10), `Layout` (×3), `scrollPosition` (×1) —
  a broad view-layer sweep with regression risk (zero `#available` guards exist today), to satisfy a
  ~10-year-old machine that would also be slow/memory-hungry at the ML features. Poor cost-to-value;
  Jude chose to skip it.
- **14 vs 15.** Lowering 15→14 is effectively free (everything used is macOS-14-safe) and widens reach
  to any Intel Mac on Sonoma. Kept at 14 unless a macOS-15-only API surfaces at compile time.
- **One codebase, always.** No path here involves a second codebase or a fork. The universal binary is
  the whole mechanism.

## Out of scope

- The Monterey (macOS 12) Mac and the view-layer backport it would require.
- Intel-specific ML performance optimization (beyond a compute-units fallback if the spike demands it).
- Notarization / Developer ID signing (the app remains ad-hoc signed, unchanged by this work).
