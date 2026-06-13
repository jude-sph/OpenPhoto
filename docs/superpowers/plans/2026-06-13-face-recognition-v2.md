# Face Recognition v2 — Implementation Plan

**Goal:** Replace the v1 face pipeline (generic image-print + single-link) with AdaFace IR-101
embeddings + landmark alignment + DBSCAN, plus a rescan/migration path. Named people preserved.

**Spec:** `docs/superpowers/specs/2026-06-13-face-recognition-v2-design.md`

Phases land as separate commits; build + test after each.

### Phase 1 — Model resource + `FaceEmbedder`
- `Package.swift`: add `resources: [.copy("Resources/AdaFaceIR101.mlpackage")]` to `OpenPhotoCore`.
- `FaceEmbedder.swift`: lazy compile (`MLModel.compileModel`) cached to Caches dir keyed by version;
  `embed(_ CVPixelBuffer) -> [Float]?` (512-d). Thread-safe (`NSLock`), `@unchecked Sendable` shared.
- Test: load + run on a synthetic 112×112 buffer → 512 finite floats.

### Phase 2 — `SimilarityTransform` + `FaceAligner`
- `SimilarityTransform.swift`: pure closed-form least-squares 2D similarity (a,b,tx,ty) → `CGAffineTransform`.
- Tests: recover a known rotation+scale+translation from synthetic point pairs (no real faces).
- `FaceAligner.swift`: 5 landmarks (eyes/nose/mouth-corners) from `VNFaceObservation` → transform to
  the canonical template → render aligned 112×112 `CVPixelBuffer` (32BGRA) via CIContext.

### Phase 3 — Catalog v14 + face quality + confirmed-overlap guard
- Migration v14: `faces.quality REAL NOT NULL DEFAULT 1`; create `catalog_meta(key,value)`.
- `FaceRow.quality`; `insertFaces`/`replaceFaces`/`faceRow(from:)` carry it.
- `replaceFaces`: skip a new auto face that IoU-overlaps an existing confirmed face for the hash.
- `unassignedFacesWithEmbeddings`: filter `dim = 512 AND quality > 0`.
- `catalog_meta` get/set; `faceModelVersion` constant `"adaface-ir101-v1"`.
- Tests: quality round-trips; confirmed-overlap skip; unassigned filter excludes dim≠512 & quality 0.

### Phase 4 — Rewrite `FaceStage`
- `DetectedFace.quality: Float`.
- `detect`: `VNDetectFaceLandmarksRequest` (faces+landmarks+roll/yaw) + `VNDetectFaceCaptureQualityRequest`.
  Per face: gate (size, capture quality, |roll|/|yaw|). Pass → align → embed (512-d, quality=score).
  Fail → store rect only (empty embedding, quality 0). Wrap per-image + per-face in `autoreleasepool`.
- `FaceDerivationStage.run`: store quality.

### Phase 5 — DBSCAN in People
- `AppState`: replace `faceClusterThreshold` with `faceClusterEps` / `faceClusterMinPts`.
- `loadPeople`: `DBSCAN.groups(unassigned, eps:, minPts:)` instead of `FaceClusterer.cluster`.
- Defaults: eps 0.55, minPts 3 (tune on smoke).

### Phase 6 — Rescan Faces (migration + UI)
- Catalog: `resetAutoFaces()` (delete source='auto' faces) + `clearDerivationJobs(stage:)`.
- `AppState.rescanFaces()`: reset + clear faces jobs + bump version + `pokeDerivation()`; reload People.
- On library open: if `catalog_meta.faceModelVersion` ≠ current → run the reset once (auto-migrate).
- `SettingsView` (Library section): "Rescan Faces" button → confirm → `rescanFaces()`.

### Phase 7 — Docs, memory, release
- Update memory `openphoto-face-recognition-rebuild` (shipped). Format docs unchanged (catalog-only,
  rebuildable — note in spec). Bump VERSION, run `scripts/release.sh`.

### Also (separate, user-requested): Map arrow-key navigation
- `MapView`: arrow keys pan, +/- or ⌘±/arrows zoom, alongside existing mouse controls.
