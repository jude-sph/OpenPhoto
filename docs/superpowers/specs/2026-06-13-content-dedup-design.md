# Content identity & dedup — design

- **Date:** 2026-06-13
- **Status:** Approved (brainstorm)
- **Area:** `OpenPhotoCore/Catalog` (queries), `OpenPhotoApp` (Timeline, Search, Folders, Inspector, Cleanup)

## Problem

OpenPhoto identifies a photo by content hash (sha256) but currently browses by **instance** (one
`instances` row per file). Consequences the user hit:

1. **"Duplicates" (Tidy Up) shows non-duplicates.** It uses perceptual hashing (pHash) which groups
   different-but-similar burst frames as duplicates.
2. **A photo in two folders appears twice in the timeline** (same hash, two instances → two rows;
   `TimelineItem.instanceID` documents this as intentional v1).
3. There's no way to see that a photo lives in multiple folders, and no folder-vs-global scope for
   the Duplicates finder.

## Model

- **Content** = a sha256 hash = one photo. **Instances** = the files that content has across folders
  and drives. Human metadata (favorite, rating, caption, tags, rotation) is already keyed by content,
  so it is unaffected.
- **Timeline & Search browse by content** (one tile per hash). **Folders browse by instance** (a file
  shows in each folder it lives in). The Inspector shows *all* instances of the opened content.

## Decisions (locked)

- **Literal duplicate = exact content (same sha256).** No pHash for Duplicates; *Similar* keeps pHash.
- **Timeline delete = delete the photo (all its instances → bin).** Folder/Duplicates delete acts on a
  single instance (file).

## Design

### A. Two query shapes (the core change)

`Catalog/Queries.swift` currently exposes one `timelineSQL` (local instances ∪ drive-only) reused by
timeline, folder, and search queries. Split into two:

- **`browseSQL` (deduped, by content)** — one row per asset hash. Local branch picks a single
  representative instance per hash; drive-only branch already dedupes via `MIN(rowid)`. Representative
  instance = a **local** instance preferred (full-res), canonical pick = lowest `rowid` (stable);
  falls back to the drive-only row when no local instance exists. Used by **`timelineItems`** and the
  **search** fetch (`Catalog+Search.swift`).
- **`instanceSQL` (per-instance)** — today's behaviour, one row per instance. Used by
  **`items(inDir:recursive:)`** and **`folderCounts`** so a file still appears in every folder it
  lives in (folders are location-scoped). This is essentially the current `timelineSQL`.

Implementation note: the local branch of `browseSQL` adds
`AND i.rowid = (SELECT MIN(rowid) FROM instances i2 WHERE i2.hash = a.hash)` so exactly one local
instance represents each hash. `folderCounts`/`items(inDir:)` keep using the per-instance form.

### B. Grid identity → hash (timeline & search only)

With the deduped query, the timeline/search grids use the **content hash** as the `ForEach` id (the
representative `TimelineItem` per hash). Folder grids keep using `instanceID`. (`TimelineItem` already
carries both `hash` and `instanceID`; this is a call-site change in `TimelineView`/`SearchView`, not a
struct change.)

### C. Inspector — all locations

The Inspector's file-location row lists **every** instance of the opened content: for each
`Catalog.instances(forHash:)` row show its vault + relPath (folder + filename); also surface drive
copies from `vault_presence`. Replaces the single-location display. Read-only list.

### D. Duplicates tab — exact content, scoped

Replace the pHash path for `CullMode.duplicates`:

- A **duplicate group** = a content hash with **2+ instances in the same folder** (default scope) or
  **2+ instances anywhere** (global scope). New catalog query:
  - *Within folder:* `SELECT hash, dirPath, COUNT(*) FROM instances GROUP BY hash, dirPath HAVING COUNT(*) >= 2`, then fetch those instances.
  - *Anywhere:* `... GROUP BY hash HAVING COUNT(*) >= 2`.
- The cull group's **tiles are the duplicate *instances*** (same hash, different relPath), not distinct
  hashes. Selection is already keyed by `instanceID`.
- **Keeper** = a deterministic instance (lowest `rowid` / shortest relPath); the other *files* are
  evicted. Eviction/delete here is **instance-scoped** (bins the specific file, leaving the kept copy
  and any copies in other folders for within-folder scope).
- UI: a **scope toggle** ("Within folder" / "Anywhere") in the Tidy-Up Duplicates view (only shown in
  Duplicates mode). *Similar* and *Bursts* are unchanged (still pHash / embeddings).

### E. Deletion semantics

- **Timeline tile delete** → delete the content: bin **every** instance of that hash. (`AppState.delete`
  for a timeline item resolves `instances(forHash:)` and bins each.)
- **Folder grid / Duplicates tile delete** → bin the **single** instance (that relPath) only; other
  instances of the same hash remain. Requires the delete path to support an instance-scoped bin (bin
  one file by relPath) in addition to the content-scoped one.
- Drive propagation / bin behaviour otherwise unchanged.

**Bin & name collisions (no new handling needed).** `BinStore.moveToBin` bins to `bin/<original
relPath>` (mirrors the folder tree). Two instances of the same content always have **distinct
relPaths** — same-folder copies must have different filenames (the filesystem forbids identical names
in one folder), and different-folder copies keep their folder path — so deleting all copies of a photo
produces distinct bin entries with no collision. The only collision is the *pre-existing* edge of
re-binning the **exact same relPath** later (e.g. a new file reappears at a path whose prior binned
item wasn't restored/emptied); today `moveItem` throws there rather than overwriting, so it surfaces as
a delete error, not data loss. Hardening that (unique-suffix on bin-path collision) is a separate
small fix, out of scope for this change but noted.

## On-disk format impact

**None.** This is a query + display + delete-scope change. No vault layout, manifest, catalog schema,
or sidecar changes. (Recorded here deliberately per the documentation-discipline rule.)

## Components to change

| File | Change |
|------|--------|
| `Catalog/Queries.swift` | split `timelineSQL` → `browseSQL` (deduped) + `instanceSQL`; `timelineItems` uses `browseSQL`; `items(inDir:)`/`folderCounts` use `instanceSQL`; add `duplicateInstanceGroups(scope:)` query |
| `Search/Catalog+Search.swift` | structured/text/semantic fetch uses `browseSQL` |
| `Catalog/Catalog+Faces.swift`-style new query | `instances(forHash:)` already exists; add drive-presence lookup for the inspector if needed |
| `Timeline/TimelineView.swift`, `Search/SearchView.swift` | grid `id` = hash |
| `Folders/FolderGridView.swift` | unchanged (still per-instance) |
| `Inspector/InspectorView.swift` | location row → list all instances + drive copies |
| `Cleanup/CleanupView.swift` | Duplicates scope toggle (Within folder / Anywhere) |
| `AppState.swift` | `loadCullGroups` `.duplicates` → exact-content groups; instance-scoped delete; timeline delete bins all instances |

## Testing

- **Unit (`OpenPhotoCoreTests`):** `browseSQL` returns one row per hash for a hash with 2 local
  instances; `instanceSQL` returns both; `duplicateInstanceGroups(.withinFolder)` groups same-hash
  files in one folder and excludes same-hash files in different folders; `.anywhere` includes them.
- **Build + manual smoke:** timeline shows a 2-folder photo once; both folders still show it; inspector
  lists both locations; Duplicates shows only exact dups with a working scope toggle; timeline delete
  bins all copies, folder delete bins one.

## Risks

- **`browseSQL`/`instanceSQL` split is central** — every browse path must use the right one (timeline/
  search deduped; folders per-instance). Covered by unit tests on both shapes.
- **Delete-scope correctness** — timeline-delete-all vs instance-delete-one must be wired to the right
  call sites; a mistake risks deleting too much. The instance-scoped bin needs a hash+relPath path.
- **Representative-instance stability** — lowest-rowid keeps the timeline tile stable across rescans
  (rowids are assigned on first insert); acceptable.
