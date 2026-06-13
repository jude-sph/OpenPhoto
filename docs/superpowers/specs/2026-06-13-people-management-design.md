# People management improvements — design

- **Date:** 2026-06-13
- **Status:** Approved (brainstorm)
- **Area:** `OpenPhotoApp/People`, `OpenPhotoCore/Catalog+Faces`

## Problem

Three gaps in the People section, surfaced while reviewing a real library:

1. **You can't tell which face a person's collection is claiming.** The person detail grid (`PeopleView.FacePhotoTile`, the `grid` in the person detail view) shows the *whole photo* via `ThumbnailImage`. When a photo has several people — or the person isn't visibly in it at all (a mis-assignment from the known single-link clustering) — there's no way to see which detected face was assigned. This blocks meaningful correction.
2. **You can only send a selection to a *new* person.** The multi-select bar offers only *Split to new person…* and *Remove from person*. There's a per-tile "Move to person…" context menu, but no **bulk** move to an *existing* person.
3. **You can't rename a person.** There is no rename path anywhere (the person-card context menu has only *Remove person*; the detail header shows the name as static text). `Catalog` has no `renamePerson`.

A fourth, related concern — "no way to send a photo to multiple groups" — is resolved by the model rather than a feature (see below).

## Key facts from the codebase

- Each detected face stores its **normalized bounding box** (`FaceRow.rect`, Vision bottom-left origin) plus an embedding, `personID`, and `source` (`auto` | `confirmed`). So we can always crop to the exact face.
- `FaceCropView` already crops a thumbnail to a face's box; it's used today for person covers and suggested-cluster cards — just **not** in the detail grid.
- The person's **name is written into each photo's XMP sidecar** as an MWG region (`FaceRegion.name`). Human metadata lives in sidecars (hard invariant 2), so any name change must be mirrored there.
- Existing paired catalog+sidecar writers we reuse:
  - `Catalog.assignFaces(_ ids:to:)` — assign faces to a person, flip to `confirmed`.
  - `Catalog.reassignFace(_ id:to:)`, `Catalog.mergePerson`, `Catalog.deletePerson`, `Catalog.setPersonCover`.
  - `AppState.rewriteSidecarForHash(_ hash:lib:addRegions:)` (nonisolated, off-main) — rewrites an asset's sidecar to contain exactly the confirmed face regions the catalog currently knows for it (names read from the catalog), preserving all other sidecar fields. `AppState.reassignFace`/`nameCluster`/`splitFaces`/`deletePerson` all pair their catalog writes with this.

## Non-goals

- No change to the face **clustering** algorithm (the single-link chaining issue is tracked separately).
- No per-photo "assign every face in this one photo to its person from one screen" tool. With the face-centric model below, that's a possible future follow-up, not part of this.
- No on-disk **format** change (see below).

## Design

### 1. Faces ↔ Photos toggle in the detail views

The person detail view gains a segmented toggle in its toolbar — **Faces** (default) and **Photos**:

- **Faces:** each tile renders `FaceCropView` for that `FaceRow` — the exact face the cluster assigned. A wrong or empty crop is now obvious, so the user can Remove or Move it.
- **Photos:** today's behaviour — `ThumbnailImage` of the whole asset, for context.

Tapping a tile still opens the **full photo** in the viewer in both modes (`state.openViewer(item, within: photos)`). The same toggle is added to `ClusterDetailView` (reviewing a suggested cluster) for consistency.

Implementation: `FacePhotoTile` takes a `showFace: Bool`; the detail view holds `@State private var showFaces = true` and renders the toggle. Default Faces. The toggle is a view-only preference (not persisted).

### 2. Bulk "Move to person…"

The multi-select bar gains a **Move to person…** `Menu` listing existing people (each a button) plus a **New person…** item at the bottom (which is the existing *Split to new person…* flow). *Remove from person* stays.

New `AppState` method:

```
func moveFaces(_ faceIDs: [Int64], toPerson personID: Int64, fromPerson old: Int64?)
```

It runs off-main: `catalog.assignFaces(faceIDs, to: personID)`, then rewrites sidecars grouped by hash for **both** the destination person (gains regions) and the source person (loses them) — mirroring `splitFaces`. Then refreshes (`loadPeople` + the detail `reload()`). The per-tile "Move to person…" already calls `reassignFace`; the bulk path is the multi-face analogue.

### 3. Rename a person

New catalog method:

```
func renamePerson(_ id: Int64, to name: String) throws    // UPDATE people SET name = ? WHERE id = ?
```

New `AppState` method:

```
func renamePerson(_ personID: Int64, to newName: String)
```

It (off-main): trims/validates the name (non-empty), calls `catalog.renamePerson`, then **rewrites the sidecars** of every photo where the person has a confirmed face — `faces(forPerson:)` grouped by hash → `rewriteSidecarForHash(hash, lib:)` for each (which now reads the new name from the catalog). Then `loadPeople()`. This is exactly the pattern `deletePerson` already uses ("group by hash and rewrite each sidecar"). Originals are never touched; only the human-metadata sidecar's region name changes.

UI:
- **Person card** context menu gains **Rename…** (above *Remove person*).
- **Detail header**: the name becomes a rename affordance (click → inline `TextField`, commit on submit/blur; Esc cancels).

Both present a small inline text field seeded with the current name and call `state.renamePerson`.

### 4. "Multiple groups" — resolved by the model

Because a detail tile is now a **face**, not a photo, a photo containing three people contributes one face-tile to each of those three people automatically. Assigning each face to its person *is* the multi-person mechanism; there is no separate "send to multiple groups" action, and the ambiguity that motivated it (one photo, which person?) disappears once you assign faces rather than photos.

## On-disk format impact

**None.** Rename changes the *value* of an existing MWG region `name` in sidecars that already carry face regions; the bulk move uses the existing confirmed-region writer. No vault layout, manifest, catalog-snapshot, or sidecar *schema* changes — so `docs/format/` needs no update (per the documentation-discipline rule, this is recorded here deliberately: this change touches sidecar *content*, not *format*).

## Components to change

| File | Change |
|------|--------|
| `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift` | add `renamePerson(_:to:)` |
| `Sources/OpenPhotoApp/AppState.swift` | add `renamePerson(_:to:)` and `moveFaces(_:toPerson:fromPerson:)` (both paired catalog+sidecar writers, off-main; reuse `rewriteSidecarForHash`) |
| `Sources/OpenPhotoApp/People/PeopleView.swift` | detail toolbar **Faces/Photos** toggle; `FacePhotoTile.showFace`; **Move to person…** menu in the selection bar; **Rename…** in person-card menu + editable detail header; same toggle on `ClusterDetailView` |

## Testing

- **Unit (`OpenPhotoCoreTests`):** `Catalog.renamePerson` updates the row and `people()` reflects it; round-trip with a sidecar (rename → sidecar region carries the new name; other sidecar fields preserved). Use generated mock media in a temp vault (never real user data).
- **Build + manual smoke:** toggle shows crops vs photos; bulk Move to person reassigns + the faces leave the source and appear under the target; rename updates card, header, and the on-disk sidecar.

## Risks

- **Sidecar write volume on rename:** O(photos-for-this-person) sidecar rewrites. Off-main, atomic, and bounded by one person's footprint — acceptable, and identical in shape to the existing delete/merge paths.
- **Face-crop performance:** `FaceCropView` decodes from the thumbnail cache and crops; already used at scale for covers. The toggle reuses it per tile — same cost as the existing cover crops, lazily within `LazyVGrid`.
