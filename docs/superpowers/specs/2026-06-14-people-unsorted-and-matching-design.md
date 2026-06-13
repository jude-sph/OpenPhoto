# People: Unsorted bucket + centroid matching — Design

**Date:** 2026-06-14
**Status:** Approved (user chose "suggest, you confirm").

## Problem

Two gaps in the v2 People screen:
1. **Unreachable faces.** Only named People + DBSCAN "Suggested" clusters are shown. DBSCAN leaves
   sparse faces as *noise*, and noise faces appear nowhere — so they can't be assigned.
2. **No person matching.** Named people are excluded from clustering; the "representative face" is
   display-only. The app never asks "is this unassigned face person X?", so growing a person does not
   improve future recognition — there is no future-recognition step to improve.

## Approach

Each person's identity becomes the **centroid** (L2-normalized mean) of its assigned faces' current-
model vectors — so 500 faces dominate 1. Every unassigned face is partitioned into exactly one of:
- a **suggested addition** to the nearest person (if within match threshold) — user confirms,
- a **suggested new cluster** (DBSCAN over the rest),
- the **Other faces** bucket (everything left — the former invisible noise).

Nothing joins a person without confirmation.

## Components

| Unit | Responsibility |
|---|---|
| `FaceMatcher` (Core) | Pure: `centroid([[Float]])`; `match(faces, centroids, threshold)` → per-person suggested faceIDs + unmatched. Unit-tested with synthetic vectors. |
| `Catalog.assignedFacesWithEmbeddings()` | `(personID, vector)` for confirmed faces with dim = 512 (centroid input). |
| `AppState.loadPeople` (extend) | centroids → match → DBSCAN(unmatched) → partition into `suggestedAdditions`, `suggestedClusters`, `otherFaceIDs`. |
| `AppState` actions | assign selected Other faces → existing/new person; confirm/dismiss a suggested addition. |
| `OtherFacesDetailView` (UI) | Drill-in grid of the bucket; multi-select; "Add to person…" / "New person…". |
| Person detail "Suggested" strip | Faces matched to this person; Add / Dismiss; person card shows a "+N" badge. |

## Data flow (loadPeople)

```
unassigned = unassignedFacesWithEmbeddings()            // dim 512, quality>0, personID NULL
centroids  = group assignedFacesWithEmbeddings() by personID → FaceMatcher.centroid
(matched, unmatched) = FaceMatcher.match(unassigned, centroids, threshold)
suggestedAdditions = matched                            // personID → [faceID]
clusters   = DBSCAN.groups(unmatched, eps, minPts)      // suggested NEW people
otherFaceIDs = unmatched not in any cluster             // the bucket (noise)
```

## Decisions

- **Match threshold:** cosine distance ≤ ~0.55 (sim ≥ ~0.45) to a person centroid. A bit looser than
  cluster `eps` because a many-face centroid is a strong anchor. Tunable constant in `AppState`.
- **Suggest, don't auto-add.** Matches surface as suggestions; the user approves.
- **Confirmed-vector freshness.** Centroids use only dim = 512 confirmed faces. People whose faces are
  still old-model (pre-Rescan) simply get no suggestions until a Rescan Faces re-embeds them (the
  rescan already re-embeds named faces). New people (from clusters) work immediately.
- **Dismiss** a suggested addition = leave the face unassigned (it falls to Other faces); no negative
  store in v1 (a dismissed face may re-suggest after more faces sharpen the centroid — acceptable).

## Out of scope (v1)

Persisted "not this person" rejections; auto-add tier; re-running match continuously in the
background (recomputed on each People load is enough).
