# Face Map — design

**Status:** approved design, pending implementation plan
**Date:** 2026-06-20
**Author:** Jude + Claude

## Overview

A new read-only **Face Map** view: every detected face is a dot on a 2D plane,
positioned by a neighbor-embedding projection of its 512-d AdaFace vector, colored
by person. The user pans and zooms around the "galaxy"; clean people form tight
islands, messy/mixed people (e.g. Sally) smear through the middle. It is primarily
a *fun* visualization that doubles as an at-a-glance diagnostic for face-recognition
quality.

This came directly out of debugging why "Sally" attracted 362 bad face suggestions:
her confirmed faces are unusually spread out, which a 2D projection makes obvious.

### Goals

- A delightful, performant pan/zoom map of the whole face library.
- Reuse existing infrastructure (embeddings, thumbnail cache, gesture patterns).
- Three "wow" layers on top of the map, in increasing cost/risk:
  - **Lookalikes** (cheap, high value)
  - **Most/least-typical faces**, with a reassign action on outliers (cheap, real utility)
  - **Resemblance-path morph** (conditional — ships only if it looks beautiful)

### Non-goals (explicitly cut — YAGNI)

- General editing on the map (lasso/multi-select/merge/split) — that stays in People view.
- Thumbnail "blooming" (dots becoming face crops on zoom). Dots only; thumbnails appear
  solely in the hover/tap popover and the (optional) morph caption.
- Live/interactive recomputation of the projection.
- Attribute axes (hair color, glasses, smiling). AdaFace is an identity embedding and
  suppresses these; they would be noise. (A coarse "baby" cluster is real but was dropped.)
- Fine-grained age slider.

The map is read-only **except** for one deliberate, narrowly-scoped action: reassigning a
single outlier face from the Most/least-typical overlay (see below). This is the curation
hook that catches mislabels.

## Architecture

Five isolated units, each understandable and testable on its own:

| Unit | Layer | Responsibility | Depends on |
|------|-------|----------------|------------|
| `FaceProjection` | Core | Pure math: `[[Float]] → [(x,y)]`. No I/O. | Accelerate only |
| `face_layout` table + `Catalog+FaceLayout` | Core | Persist/read 2D coords per face. | GRDB |
| `FaceLayoutJob` | Core | Orchestrate compute + persist + staleness. | FaceProjection, Catalog |
| `FaceMapView` (+ `FaceMapCanvas`, camera) | App | Render dots, pan/zoom, popover. | AppState, ThumbnailStore |
| Extras overlay (Lookalikes / Typicality / Morph) | App | In-memory analyses drawn over the map. | centroids/embeddings in AppState |

### Data flow

```
faceLayout job ──> face_layout table ──> AppState.loadFaceMap() ──> [FaceMapPoint]
                                                                       │
                       centroids + embeddings (already loaded) ──┐     ▼
                                                                 ├─> FaceMapCanvas (camera transform)
                       Lookalikes / Typicality / Morph (in-mem) ─┘     │
                                                                       ▼
                                                            hit-test ─> popover / reassign
```

## Projection engine (`FaceProjection`)

**Approach A — UMAP-lite / LargeVis-style** (chosen over Barnes-Hut t-SNE for the smallest
correct surface area that still produces crisp islands; chosen over exact t-SNE/UMAP because
those are O(n²) and the library will grow):

1. **kNN graph** — cosine k-nearest-neighbors (k ≈ 15) over the unit embeddings. Exact,
   computed with chunked GEMM via Accelerate. Good to ~20k faces; see Scaling.
2. **Init** — PCA(2) seed (Accelerate SVD) for a stable, deterministic starting layout.
3. **Optimization** — SGD: attractive force pulls each face toward its kNN neighbors;
   repulsive force via random **negative sampling** (a handful of random non-neighbors per
   step). ~200–500 epochs, learning-rate decay.
4. **Output** — 2D coords, centered and scaled to a normalized unit box.

**Properties:** pure function `project(vectors: [[Float]], seed: UInt64) -> [(x: Float, y: Float)]`,
deterministic for a fixed seed, no I/O, no global state. This is the single most testable unit.

### Reference fidelity note

The Python proof-of-concept used sklearn t-SNE. Approach A is a *different* algorithm that
produces the same *kind* of result (islands), not pixel-identical output. Acceptance is
"clean people form visibly separate islands; high-variance people smear" — verified by the
trustworthiness metric (below), not by matching the POC image.

## Storage (`face_layout`)

New catalog table. Machine-derived and fully rebuildable, so it lives in the **catalog, not
the vault** (no vault-format change). Per the project's documentation discipline, the new
table is documented in `docs/format/catalog-schema.md` in the same commit.

```sql
CREATE TABLE face_layout (
    faceID        INTEGER PRIMARY KEY,   -- → faces.id
    x             REAL NOT NULL,
    y             REAL NOT NULL,
    layoutVersion INTEGER NOT NULL       -- bumps when the algorithm/params change
);
```

Added as the next catalog migration (the latest registered migration is v18).
`Catalog+FaceLayout.swift` provides `writeLayout([(faceID,x,y)], version:)` and
`readLayout() -> [(faceID,x,y)]`.

## Layout job (`FaceLayoutJob`)

- Runs as a derivation job after face embedding/clustering completes.
- Reads **all** `dim = 512` faces (assigned + unassigned), calls `FaceProjection.project`,
  writes coords in one transaction. This is a **whole-library** pass, not per-face — the
  layout is global and only meaningful computed together.
- **Staleness:** store a fingerprint of the contributing face-set (count + max faceID, or a
  hash of sorted IDs) in `catalog_meta`. Recompute when it changes — notably after **Rescan
  Faces** and after reassignments (`facesDirty`). Until a fresh layout exists, the view shows
  a "Building face map…" state with progress.
- A reassignment from the map (below) sets `facesDirty`, which marks the layout stale; the
  moved dot is **recolored immediately** to the new person but keeps its old position until
  the next recompute (full recompute is too expensive to run per single move).

## Map UI (`FaceMapView`)

- New top-level **`SidebarItem.faceMap`** ("Face Map") + a router case in `OpenPhotoApp.swift`,
  alongside `people` and `map`.
- **Rendering:** a SwiftUI **`Canvas`** draws all points in a single culled pass (off-screen
  points skipped; each point a small rect/circle sized by zoom). This scales far past a view-tree.
- **Camera / gestures:** pan (drag), zoom (scroll/pinch), keyboard pan/zoom — modeled on
  `MapView.swift`'s instant, state-authoritative handling (no fighting animations).
- **Color:** stable hue per `personID` (deterministic hash → HSB). **Unassigned faces render
  as a faint grey cloud.** A small legend (top people) + a total point count overlay.
- **Hit-testing:** nearest-dot lookup via a screen-space bucket grid rebuilt on camera change.
- **Popover (hover/tap):** the person's name + one `FaceCropView` thumbnail (reuses the
  existing `"face-{id}@{size}"` cache). This is the only thumbnail surface in the base view.

`AppState.loadFaceMap()` returns `[FaceMapPoint]` `(faceID, x, y, personID, colorSeed)`,
loaded async like `loadPeople()`.

## Extras

All three derive from per-person centroids and the in-memory embeddings already loaded by
`loadPeople()` (AppState ~350–389). **No new persisted storage.**

### 1. Lookalikes

- Precompute (in memory) the person×person centroid cosine-similarity matrix (O(P²); P≈30 now,
  trivially fine into the hundreds).
- Selecting a person draws lines from their island to their **top-3 nearest other people**.
- **Mutual-nearest** pairs (A's nearest is B and B's nearest is A — e.g. Rachael↔Hannah,
  Jude↔Bo, Nina↔Gran Gran in the current library) get a "resemblance buddies" badge.

### 2. Most / least typical (+ outlier reassign)

- Per person: **medoid** = the confirmed face nearest the centroid (most-them, "most
  quintessential photo"); **outliers** = faces farthest from the centroid (least-them).
- Selecting a person highlights its medoid (e.g. a star) and its top-N outlier points (e.g.
  rings).
- **Reassign action (the one editing exception):** an outlier's popover offers
  *"Not [Person]?"* → move to another person, or remove from this person. This reuses
  `AppState.reassignFace(_ id:to:fromPerson:)` (AppState.swift:774) verbatim — it already
  rewrites sidecars, sets `facesDirty`, and refreshes. The map recolors the moved dot
  immediately; position corrects on the next layout recompute.

### 3. Resemblance-path morph (CONDITIONAL)

Emergent from the map — **no picker, no strip panel.** Shift-click two people; if a *good
path* exists, it lights up as an animated line through the islands with the hop names in a
caption ("Jude › Bo › Sky › Nina › Gran Gran").

- **Path:** Dijkstra over the person kNN graph (k≈5, edge weight = 1 − cosineSim), reusing the
  Lookalikes similarity matrix.
- **"Good path" gate** — the morph is offered for a pair only if ALL hold:
  - a path exists,
  - hop count is in `[3, 6]` (a single hop is boring; longer is a tenuous bridge),
  - **every edge** on the path has cosineSim ≥ ~0.18 (a genuine resemblance chain, not a noise
    bridge — Sally's nearest is only 0.135, so weak links are excluded).
  - All thresholds are tunable constants.
  - If the gate fails, shift-click does nothing visible (or a subtle "no clear resemblance
    path" toast). We do **not** draw weak/ugly paths.
- **Ship gate (kill switch):** this entire sub-feature ships **only if** the animated lit
  path meets a genuine visual-quality bar during implementation review — a path that truly
  *lights up* (eased glow travelling along the line, crisp caption). If it can't be made to
  look beautiful, the morph is **cut entirely** with zero residual UI. Lookalikes +
  Most/least-typical do not depend on it.

## Error handling

- No layout yet → "Building face map…" with job progress; never an empty/broken canvas.
- Projection job failure → logged, retried on next trigger; stale layout remains usable.
- Reassign failure → logged (existing `reassignFace` behavior); optimistic UI reverts on reload.
- Empty/tiny libraries (< a few hundred faces) → map still renders; islands just won't be
  dramatic. No special-casing.

## Testing

- **`FaceProjection`** (the priority): deterministic seed; **trustworthiness** check — for a
  synthetic set with known clusters, same-cluster points must remain k-NN-neighbors in 2D;
  separate clusters must not overlap. Guards the whole visual promise without pixel-matching.
- **`Catalog+FaceLayout`:** round-trip write/read; layoutVersion handling; staleness fingerprint.
- **Lookalikes / typicality:** pure functions over fixture centroids — assert known
  nearest-pairs and medoid/outlier selection.
- **Morph path:** Dijkstra correctness + the "good path" gate on fixture graphs (accept a
  valid mid-length strong chain; reject single-hop, over-long, and weak-link paths).

## Performance & scaling

- **Render:** O(visible points) per frame via Canvas + culling — fine into 100k+ dots.
- **Projection:** exact kNN is O(n²) in the worst case. Acceptable now (POC: 7,360 faces in
  ~16 s in Python; native + Accelerate will be faster) and runs off the main thread as a job.
  **Scaling follow-up (deferred, matching the project's existing "defer perf" pattern):**
  approximate-NN (random-projection / HNSW-lite) for libraries beyond ~20k faces. Flagged, not
  built, for v1.

## Open risks

1. **Approach A tuning** — getting crisp islands depends on k, epochs, negative-sample count,
   and learning rate. Mitigation: the trustworthiness test + a tuning pass on Jude's real
   library (which has clear ground-truth clusters).
2. **Morph beauty** — explicitly gated; cut if it isn't beautiful. Low risk because it's
   isolated and optional.
3. **Stale dot positions after reassign** — accepted; recolor-now, reposition-on-recompute.

## Reuse map (real anchors)

| Need | Reuse |
|------|-------|
| Face embeddings (assigned/unassigned) | `Catalog+Faces.swift:138, :192` |
| Per-person centroid logic | `AppState.swift:~350` |
| Face crop rendering + cache | `PeopleView.swift` `FaceCropView` (~993–1112) |
| Pan/zoom/gesture pattern | `MapView.swift:70–135` |
| Sidebar item + router | `SidebarView.swift` enum, `OpenPhotoApp.swift:119` |
| Reassign a face | `AppState.swift:774` `reassignFace(_:to:fromPerson:)` |
| Thumbnail cache | `ThumbnailImage.swift:11` |
