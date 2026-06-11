# Near-duplicate / burst culling — design

**Date:** 2026-06-11
**Branch:** `phase5-near-dup-culling`
**Status:** Approved in brainstorming (2026-06-11); ready for the implementation plan.
**Phase:** Phase 5 (Extras & integrations) — the marquee item; see master design spec §10.5.

> A dedicated **Tidy Up** surface that finds redundant photos in two modes and lets the user keep the
> best and bin the rest:
> - **Bursts** — *different* near-identical shots taken together (8 frames of one moment), grouped by
>   **CLIP cosine + a time window** (reuses the existing `embeddings`; no new model).
> - **Duplicates** — the *same* image as separate files (an original + a re-saved/re-compressed copy),
>   grouped by a **perceptual hash** within the **same folder** (cross-folder look-alikes are assumed
>   intentional). pHash is a deterministic transform, *not* a model.
>
> Distinct from the exact-hash dedup-on-import that already exists. Deletion reuses the existing
> `delete`→bin path (recoverable; queued for drive-review). Catalog-only; the one on-disk touch is a
> rebuildable `phash` table.

---

## 1. Goal & scope

Let the user reclaim space and reduce clutter by reviewing **groups** of redundant photos, with a
**suggested keeper** pre-chosen and the rest pre-selected for deletion — adjustable via the shared
multi-select before a recoverable, bin-backed delete.

### Key decisions (the non-obvious ones)

1. **Two modes, two algorithms, two keeper heuristics:**
   - **Bursts** = visually near-identical (CLIP cosine ≥ ~0.93) **and** temporally close (≤ ~60 s,
     same chain). Keeper = **sharpest** frame (resolution is identical across a burst, so sharpness is
     the only meaningful discriminator).
   - **Duplicates** = perceptual-hash Hamming ≤ ~6/64 **within the same `dirPath`**. Keeper = **highest
     resolution, then largest file** (the original beats a downscaled/recompressed re-save).
2. **Same-folder rule for Duplicates (precision over recall).** A near-identical image in a *different*
   folder is assumed an intentional copy and is **not** surfaced as cullable. This targets exactly the
   "original + a compressed re-save dumped in one folder" clutter and never nags about deliberately-filed
   copies. (Bursts are unaffected — frames taken together land in one folder anyway.)
3. **Favorites & rated are protected** — never placed in the auto-delete suggestion (the user can still
   delete them manually). The keeper highlight is the heuristic best; favorites are additionally kept.
4. **One small new derivation + migration; everything else reuses existing data.** A `PHashStage`
   (registry alongside OCR/Embed/Faces/Geocode) writes a 64-bit perceptual hash per photo into a new
   rebuildable `phash` table (**catalog migration v10**). Bursts need **no** new storage — grouped
   on-demand from `embeddings` + `assets.takenAtMs`.
5. **On-demand grouping (no persistent groups table).** Groups are computed when the surface opens,
   off-main, via pure unit-tested functions (the `FaceClusterer` pattern). Sharpness is computed
   on-demand for the handful of photos in a viewed group, from cached thumbnails (milliseconds).
6. **Deletion is the existing recoverable path.** `delete([items])` → local bin + `pending_deletions`
   for drive-review propagation; nothing hard-deleted (invariant #3).

### Non-goals (v1)

- The exact byte-identical-copies case (same hash, multiple instance paths). pHash never groups these
  (dedup-on-import already collapses them to one asset), and multi-folder placement is usually
  intentional — so it's **not** a feature here (at most a passive "N copies on disk" note, out of scope
  for v1).
- A **cross-folder** "similar photos" lane for Duplicates (could be a future opt-in, clearly flagged).
- Auto-deletion without review. Every delete is user-confirmed; suggestions are pre-selections only.
- Video bursts (this is photo-only — `eligibleKind == "photo"`, matching the other stages).

---

## 2. Architecture

### Core (`OpenPhotoCore`, TDD)

**`PerceptualHash` (`Sources/OpenPhotoCore/Cull/PerceptualHash.swift`)** — pure: `compute(imageAt: URL)
-> Int64?`. A **difference-hash (dHash)**: decode (ImageIO, downsampled), convert to 9×8 grayscale,
emit a bit per adjacent-pixel comparison → a 64-bit value (stored as `Int64`). Deterministic, no model;
robust to re-compression/resize. `static func hamming(_ a: Int64, _ b: Int64) -> Int` = `(a ^ b)`'s
`nonzeroBitCount`. Returns nil only on decode failure.

**`PHashStage` (`Sources/OpenPhotoCore/Derivation/PHashStage.swift`)** — `DerivationStage`
(`id = "phash"`, `eligibleKind = "photo"`, default `needsFile = true`, `isAvailable = true`):
`run(hash:url:catalog:)` computes `PerceptualHash.compute(imageAt: url)` and `catalog.upsertPHash(...)`;
returns `false` only on decode failure (retry-capped like the other stages).

**`Catalog+PHash.swift`** — the `phash` table (migration **v10**) + queries:
- `upsertPHash(hash: String, value: Int64)`
- `phashRowsWithDirPath() -> [(hash: String, dirPath: String, value: Int64)]` — JOINs `phash` to the
  timeline union (`Self.timelineSQL`), so `dirPath` is per-instance and covers local ∪ drive-only.
- `embeddingsWithTakenAt(model: String) -> [(hash: String, takenAtMs: Int64, vector: [Float])]` — JOINs
  `embeddings` to `assets` (lives in `Catalog+Embeddings.swift`; feeds the burst grouper).

**`BurstGrouper` (`Sources/OpenPhotoCore/Cull/BurstGrouper.swift`)** — pure:
```swift
static func group(_ items: [(hash: String, takenAtMs: Int64, vector: [Float])],
                  windowMs: Int64, cosineThreshold: Float) -> [[String]]
```
Sort by `takenAtMs`; chain consecutive photos into a burst while the time gap to the previous ≤ `windowMs`
**and** cosine(prev, next) ≥ `cosineThreshold` (vectors are L2-normalized, so cosine = dot). Emit only
groups of size ≥ 2 (singletons dropped). O(N) after the sort.

**`DuplicateGrouper` (`Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift`)** — pure:
```swift
static func group(_ items: [(hash: String, dirPath: String, value: Int64)],
                  hammingThreshold: Int) -> [[String]]
```
Bucket by `dirPath`; within each folder, union items whose `PerceptualHash.hamming ≤ threshold`; emit
groups with ≥ 2 **distinct** hashes. Cross-folder matches are never grouped (the same-folder rule).

**`FocusMeasure` (`Sources/OpenPhotoCore/Cull/FocusMeasure.swift`)** — pure: `varianceOfLaplacian(_
image: CGImage) -> Double` (a 3×3 Laplacian convolution over grayscale, then variance; vImage/Accelerate).
Higher = sharper. Used on-demand for the burst keeper.

**`KeeperSelector` (`Sources/OpenPhotoCore/Cull/KeeperSelector.swift`)** — pure:
```swift
enum CullMode { case bursts, duplicates }
struct Candidate { let hash: String; let pixelCount: Int; let fileSize: Int64
                   let favorite: Bool; let rating: Int; let sharpness: Double? }
static func suggestion(_ c: [Candidate], mode: CullMode) -> (keep: String, evict: [String])
```
`keep` = best by mode (**bursts:** sharpness desc, then pixelCount; **duplicates:** pixelCount desc, then
fileSize), deterministic tiebreak by `hash`. `evict` = every candidate **except** `keep` **and except any
favorite or rated** (those are protected — kept, never auto-evicted).

### App (`OpenPhotoApp`, build-verified)

**`AppState` cull orchestration** — `var cullMode: CullMode = .bursts`; `var cullGroups: [CullGroup] =
[]` (`CullGroup { items: [TimelineItem]; keep: String; suggestedEvict: Set<String> }`); `loadCullGroups()`
mirrors `loadPeople()`: off-main, builds the grouper input from the catalog, runs the grouper, fetches
`TimelineItem`s (`items(forHashes:)`), computes sharpness (bursts) from cached thumbnails, runs
`KeeperSelector`, publishes on main. Delete reuses `delete([items])` (already on `AppState`/`LibraryService`).

**`SidebarItem.tidyUp`** (symbol `sparkles`/`square.on.square`, label "Tidy Up") under the Library group;
`RootView.detail` gains a `case .tidyUp: CleanupView(state:)` arm.

**`CleanupView` (`Sources/OpenPhotoApp/Cleanup/CleanupView.swift`)** — toolbar with a **Bursts/Duplicates**
segmented toggle + counts; a vertically-scrolling list where each **group is a row** of `MediaTile`s
(existing tile code) with the **keeper ringed** and the `suggestedEvict` tiles pre-selected; shared
`SelectionModel` + rubber-band/shift for multi-select; a selection action bar with **"Delete selected"**
(→ `delete`, recoverable) and **"Apply all suggestions"** (delete every group's `suggestedEvict`). Empty
state when no groups. Reloads on appear and after a delete.

**Registry:** add `PHashStage()` to `derivationStages`; add `case "phash": return "photo"` to
`Catalog.eligibleKind(forStage:)`.

---

## 3. Data flow

```
Tidy Up opens / mode changes → AppState.loadCullGroups()  (off-main)
  bursts:     catalog.embeddingsWithTakenAt(model) → BurstGrouper.group(window, cosine) → [[hash]]
  duplicates: catalog.phashRowsWithDirPath()       → DuplicateGrouper.group(hamming)    → [[hash]]
  → for each group: items(forHashes:) ; (bursts) FocusMeasure on cached thumbnails
  → KeeperSelector.suggestion(candidates, mode) → CullGroup{items, keep, suggestedEvict}
  → publish cullGroups on main
user adjusts selection (SelectionModel) → "Delete selected" / "Apply all suggestions"
  → AppState.delete(items)  → bin + pending_deletions (drive-review) → reload
PHashStage runs in the background drain (like OCR/Embed/Faces/Geocode), writing the phash table.
```

---

## 4. Error handling / edge cases

| Case | Behaviour |
|---|---|
| No embeddings yet (model absent / not backfilled) | Bursts shows an empty state ("analysis still running"); no crash. |
| No `phash` rows yet (stage not yet drained) | Duplicates empty until the stage backfills; nothing fails. |
| A photo on an unplugged drive | Still groupable (grouping reads catalog `phash`/`embeddings`, not bytes); sharpness falls back to pixelCount if no thumbnail is reachable. |
| A whole group is favorites/rated | `suggestedEvict` is empty (all protected) — the group shows but pre-selects nothing to delete. |
| Decode failure in `PHashStage` | Returns false → retry-capped (3 attempts) like other stages; that photo simply never appears in Duplicates. |
| Group of size 1 | Not a group — grouper drops singletons. |
| Sibling folder `2025` vs `2025x` | Irrelevant — Duplicates buckets by exact `dirPath` equality, never prefix. |
| Delete removes a keeper by user choice | Allowed (it's their selection); the bin makes it recoverable. |

---

## 5. Testing

**Core (TDD, Swift Testing — generated data only, never `~/Pictures`):**
1. `PerceptualHash` — `compute` on a generated CGImage written to a temp file returns a stable value;
   a re-encoded/slightly-rescaled copy lands within the Hamming threshold; a clearly different image is
   outside it. `hamming` correctness (XOR popcount).
2. `BurstGrouper` — three near-identical vectors within the window group; one outside the window (same
   look) does NOT; one inside the window but dissimilar does NOT; singletons dropped; vectors L2-normalized.
3. `DuplicateGrouper` — two near-hash photos in the same folder group; the same pair split across two
   folders does NOT; a third dissimilar photo in the folder excluded; ≥2-distinct-hash rule.
4. `FocusMeasure` — a synthetic sharp (high-contrast edges) image scores higher than a blurred one.
5. `KeeperSelector` — duplicates pick highest pixelCount then fileSize; bursts pick highest sharpness;
   favorites/rated never appear in `evict`; deterministic hash tiebreak.
6. `PHashStage` + `Catalog+PHash` — stage writes a row; `phashRowsWithDirPath` returns hash+dirPath+value
   over the union (incl. a drive-only asset); `pendingDerivation(stage:"phash")` reflects photos; migration
   v10 round-trips.

**App:** build-verified + manual — the Tidy Up surface, the Bursts/Duplicates toggle, suggested-keeper
ring + pre-selected rejects, multi-select adjust, Delete selected / Apply all → bin (recoverable). Rebuild
the bundle via `./scripts/make-app.sh`.

---

## 6. Documentation

`docs/format/catalog-schema.md` gains the **`phash`** table (v10, rebuildable/machine-derived, droppable
cache — a deterministic dHash of the image; external readers MAY ignore it), bumped to **Version 10**, with
a note in the Portability key + Versioning. **No `vault-format-v1.md` change** (no new on-disk artifact in
the vault; the `phash` table is Mac-catalog-only). Master spec §10.5 marks near-dup culling **DONE** with a
2026-06-11 changelog entry at merge.

---

## 7. Task decomposition (for the plan)

1. **Core (TDD)** — `PerceptualHash` (dHash + hamming) + `FocusMeasure` (variance-of-Laplacian). Tests §5.1, §5.4.
2. **Core (TDD)** — `phash` table (migration **v10**, bump `Catalog.schemaVersion` 9→10) + `Catalog+PHash`
   (`upsertPHash`, `phashRowsWithDirPath`) + `embeddingsWithTakenAt` + `PHashStage` + the `eligibleKind`
   `"phash"` case. Tests §5.6.
3. **Core (TDD)** — `BurstGrouper`, `DuplicateGrouper`, `KeeperSelector` (+ `CullMode`/`Candidate`). Tests §5.2, §5.3, §5.5.
4. **App** — `AppState` cull state + `loadCullGroups()` + `PHashStage` in the registry; the
   `SidebarItem.tidyUp` case + detail arm.
5. **App** — `CleanupView` (toggle, grouped `MediaTile` rows, `SelectionModel` multi-select, keeper ring,
   Delete selected / Apply all suggestions). Rebuild the bundle.
6. **Docs** — `catalog-schema.md` v10 (`phash` table); master spec §10.5 DONE + changelog. No `vault-format` change.

`Scanner`/`MetadataExtractor`/`ThumbnailStore`/`SyncEngine`/`SemanticIndex`/`FaceClusterer` are **used, not
modified**. Deletion reuses the existing `delete` path unchanged.
