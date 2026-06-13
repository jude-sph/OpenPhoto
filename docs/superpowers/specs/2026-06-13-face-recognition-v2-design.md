# Face Recognition v2 — Design

**Date:** 2026-06-13
**Status:** Approved (spike validated). Replaces the v1 face pipeline.

## Problem

v1 produced <5 groups, one with 1700+ photos of unrelated people. Two compounding root causes:

1. **Wrong embedding (dominant).** `FaceStage` embedded each face with `VNGenerateImageFeaturePrint`
   on a padded bbox crop. That is a *generic image-similarity* descriptor (scene/texture/lighting),
   **not** a face-identity embedding. Same person under different light/pose lands far apart;
   different people in similar framing land close. The vector space never encoded identity.
2. **Single-link chaining.** `FaceClusterer` joins a face to a cluster if it is near *any* member, so
   one bridging face transitively fuses two identities → one mega-blob.

Also missing: landmark **alignment** (raw bbox crop) and **quality gating**.

## Approach (spike-validated)

- **Embedding model:** AdaFace **IR-101 (WebFace12M)** — strongest open-source face-recognition model,
  best on the mixed-quality images a real library contains. Converted to Core ML (125 MB, FP16),
  torch↔CoreML parity **cosine 0.99995**. Licensing is irrelevant — personal use, no distribution.
- **Alignment:** Vision face landmarks → similarity transform to the canonical 5-point 112×112
  template → aligned crop. The model expects this; a raw bbox would waste it.
- **Clustering:** **DBSCAN** (cosine distance) replaces single-link. Density requirement (≥ minPts
  within eps) means a lone bridge can't fuse identities; sparse faces become *noise*, not a blob.
  Validated: on bridge data where single-link makes one cluster, DBSCAN keeps two (`DBSCANTests`).
- **Quality gating:** drop tiny / low-capture-quality / extreme-pose faces from clustering (kept for
  display + manual assignment).

## Components

| Unit | Responsibility |
|---|---|
| `Resources/AdaFaceIR101.mlpackage` | Bundled Core ML model (compiled at first use, cached). |
| `FaceEmbedder` (Core) | Load/compile model once; `embed(CVPixelBuffer)->[Float]` 512-d. Thread-safe. |
| `FaceAligner` (Core) | `VNFaceObservation` landmarks → similarity warp → aligned 112×112 buffer. |
| `SimilarityTransform` (Core) | Pure least-squares 2D similarity (Procrustes); unit-tested. |
| `FaceStage` (rewrite) | detect+landmarks → quality gate → align → AdaFace embed. |
| `DBSCAN` (Core) | Done. Replaces `FaceClusterer` in `loadPeople`. |
| Catalog v14 | `faces.quality` column; `catalog_meta` KV for `faceModelVersion`. |
| Rescan Faces | Catalog reset + auto-migrate on open + Settings→Library button. |

## Data model & migration

- `faces.quality REAL NOT NULL DEFAULT 1`: capture quality if clusterable, else `0` (gated out).
  `unassignedFacesWithEmbeddings` filters `dim = 512 AND quality > 0`.
- `catalog_meta(key TEXT PRIMARY KEY, value TEXT)`: stores `faceModelVersion = "adaface-ir101-v1"`.
- **Stale v1 vectors self-exclude:** old embeddings have dim ≠ 512, so the dim filter already drops
  them; the rescan clears + re-derives.
- **Named people survive.** Identity = `personID` + the XMP sidecar region name, never the vector.
  Rescan re-derives **auto** faces only (`replaceFaces` keeps `confirmed`); `replaceFaces` also skips
  a new auto face that overlaps an existing confirmed face (no duplicate over a named person).

## Rescan flow

- **Auto (on library open):** if stored `faceModelVersion` ≠ current → delete auto faces + clear the
  `faces` derivation jobs, set version, `pokeDerivation()`. One-time after the update; runs in the
  existing low-priority background drainer with its progress line.
- **Manual:** Settings → Library → "Rescan Faces" does the same reset on demand.
- **Memory safety:** per-image work wrapped in `autoreleasepool` (Vision + Core ML + CG allocate
  autoreleased buffers; the app has an OOM history during bulk derivation — see indexing memory work).

## Out of scope (v1)

Re-embedding confirmed faces' vectors (they keep stale vectors, excluded from clustering anyway);
cross-cluster "suggest existing person" matching; tunable eps/minPts UI (constants for now).
