# OpenPhoto Catalog Schema — Version 11

**Status:** NORMATIVE for readers of `catalog-snapshot/catalog.sqlite` and for the Mac's live catalog database. Field names are stable from schema version 4 onward; any change bumps the version in `snapshot.json`'s `catalog_schema_version` field.

**Audience:** anyone reading a `catalog-snapshot/` on a drive (e.g. server software browsing a canonical drive without the Mac present). After reading this document and `vault-format-v1.md §7` you should be able to fully interpret the snapshot with no other information.

The catalog is machine-derived and rebuildable from originals, sidecars, and the vault `manifest.jsonl`. The `catalog-snapshot/` that contains it is a disposable accelerator; the `manifest.jsonl` (§4 of `vault-format-v1.md`) is always the authoritative inventory of what a drive holds.

---

## Tables

### `vaults`

Tracks every vault the Mac has catalogued (local, drives, backups).

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT **PK** | UUID matching `vault.json`'s `vault_id`. |
| `role` | TEXT | `"local"` \| `"canonical"` \| `"backup"` (advisory). |
| `rootPath` | TEXT | Absolute filesystem path on the **source Mac** — meaningless on other machines. |
| `lastSeenMs` | INTEGER | Epoch milliseconds when the Mac last mounted this vault — informative. |

External readers MUST ignore `rootPath` and `lastSeenMs`; they are local to the Mac that wrote the snapshot.

### `assets`

One row per unique asset the Mac has ingested, keyed by content hash.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT **PK** | `sha256:` + 64 lowercase hex chars. |
| `kind` | TEXT | `"photo"` \| `"video"` \| `"live"`. |
| `takenAtMs` | INTEGER | Capture timestamp, epoch milliseconds UTC. |
| `pixelWidth` | INTEGER? | Nullable. |
| `pixelHeight` | INTEGER? | Nullable. |
| `latitude` | REAL? | Nullable decimal degrees. |
| `longitude` | REAL? | Nullable decimal degrees. |
| `cameraModel` | TEXT? | EXIF `Model`, nullable. |
| `lensModel` | TEXT? | EXIF lens description, nullable. |
| `durationSeconds` | REAL? | Video/Live Photo duration; null for stills. |
| `livePairHash` | TEXT? | Hash of the paired file for a Live Photo; null otherwise. |
| `isLivePairedVideo` | BOOL | `1` if this row is the video half of a Live Photo pair. |
| `favorite` | BOOL | Mirror of the XMP sidecar `xmp:Label = "Favorite"`. |
| `rating` | INTEGER | Mirror of `xmp:Rating` (0–5). |
| `caption` | TEXT? | Mirror of `dc:description`; nullable. |
| `tagsJSON` | TEXT | JSON array of tag strings (mirrors `dc:subject`). Empty array `[]` when none. |

The human columns `favorite`, `rating`, `caption`, and `tagsJSON` are mirrors of the XMP sidecars. **The sidecars are authoritative and win on ingest.** On any conflict between an `assets` row and the corresponding sidecar, the sidecar governs.

### `instances`

One row per physical file location on the **source Mac's local vaults**. Tracks where the Mac itself has copies of each asset.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT | References `assets.hash`. |
| `vaultID` | TEXT | References `vaults.id`. |
| `relPath` | TEXT | Vault-root-relative path on the source Mac. |
| `dirPath` | TEXT | Parent directory of `relPath` (denormalized for query efficiency). |
| `size` | INTEGER | File size in bytes. |
| `mtimeMs` | INTEGER | File modification time, epoch milliseconds. |

**Primary key:** (`vaultID`, `relPath`).

External readers MUST ignore the `instances` table entirely. Its paths are local to the source Mac and have no meaning elsewhere.

### `vault_presence`

One row per (vault, asset) pair the Mac knows about across all vaults it has ever synced — including drives and backups. This is the table external readers use to learn which hashes are present on a given drive.

| Column | Type | Notes |
|---|---|---|
| `vaultID` | TEXT | References `vaults.id`. |
| `hash` | TEXT | References `assets.hash`. |
| `relPath` | TEXT | Vault-root-relative path within that vault. |
| `dirPath` | TEXT | Parent directory of `relPath` (denormalized). |
| `size` | INTEGER | File size in bytes at last sync. |
| `driveRelPath` | TEXT | Path within the drive's top-level directory structure (used for canonical drives). |

**Primary key:** (`vaultID`, `hash`).

A snapshot reader uses only rows whose `vaultID` equals the drive's own vault id (from `vault.json`). Rows for other `vaultID`s represent assets on the source Mac's other drives or backups; external readers MUST ignore them.

### `pending_deletions`

The source Mac's internal queue of assets approved for deletion but not yet propagated to all vaults.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT **PK** | Asset to be deleted. |
| `relPath` | TEXT | Path in the source vault at the time of approval. |
| `deletedAtMs` | INTEGER | Epoch milliseconds when the deletion was approved. |

External readers MUST ignore this table. It reflects the source Mac's private delete queue and does not represent anything that has happened (or will happen) on the drive being read.

### `pending_folder_ops` (v6, Mac-internal)

The source Mac's internal queue of **folder-structure operations** to apply to an offline durable drive on its next connect — applied before the path-keyed sync so that the sync never duplicates files under stale paths.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER **PK** | Auto-incremented primary key. |
| `vaultID` | TEXT | The drive vault this op is queued for (references `vaults.id`). |
| `op` | TEXT | `"move"` \| `"create"` \| `"delete"`. |
| `srcRelPath` | TEXT? | Source vault-root-relative path. Required for `"move"` and `"delete"`; null for `"create"`. |
| `dstRelPath` | TEXT? | Destination vault-root-relative path. Required for `"move"` and `"create"`; null for `"delete"`. |
| `createdAtMs` | INTEGER | Epoch milliseconds when the op was queued. |

This table is the **source Mac's private reconcile queue**. It records structural folder rearrangements (drag-drop nesting, folder creation, folder deletion) that happened on the Mac while the target drive was offline. On the drive's next connect, `applyPendingFolderOps(forDriveID:driveVault:)` applies these ops to the drive vault before the drift scan and sync — so the path-keyed sync never sees stale paths and never creates duplicate files.

External readers **MUST ignore this table**. It reflects the source Mac's internal pending-ops state and does not describe anything that has already happened (or is guaranteed to happen) on the drive being read.

### `derivation_jobs` (v5, rebuildable)

Per-asset, per-stage completion record for the background **derivation pipeline** — the lane that derives machine-only intelligence (OCR, and in later Phase-4 slices faces / embeddings / reverse-geocoding) from an asset's bytes after it enters the library. Resumable and retry-capped: the **absence** of a `"done"` row for a (`hash`, `stage`) pair means that stage is still pending for that asset.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT | References `assets.hash`. |
| `stage` | TEXT | Pipeline stage id — `"ocr"` (later `"faces"` / `"embed"` / `"geocode"`). |
| `status` | TEXT | `"done"` \| `"failed"`. A missing row = pending. |
| `attempts` | INTEGER | Failed-attempt counter; a `"failed"` row at the attempt cap (3) is never retried. |
| `updatedAtMs` | INTEGER | Epoch milliseconds of the last update. |

**Primary key:** (`hash`, `stage`).

This is the source Mac's internal pipeline bookkeeping — it records which derivations the Mac has run, nothing about the drive's contents. External readers MUST ignore it. Rebuildable: dropping it makes the pipeline re-derive everything (the work is idempotent).

### `ocr` (v5, FTS5, rebuildable)

A SQLite **FTS5** full-text virtual table over text recognized in photos (on-device Vision, `VNRecognizeTextRequest`). One row per photo that has been OCR'd; an empty `text` means "analyzed, no text found".

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT (UNINDEXED) | References `assets.hash`. Stored and retrievable, but not tokenized. |
| `text` | TEXT (FTS5) | Recognized text, tokenized for full-text `MATCH`. |

Machine-derived and keyed by content hash, so it survives eviction and is portable in the same spirit as `assets`. A reader MAY full-text-search a drive's photos with it (`SELECT hash FROM ocr WHERE ocr MATCH ?`). It is a rebuildable cache (drop it → the pipeline re-derives), never a source of truth.

### `embeddings` (v7, rebuildable)

Per-asset CLIP-class image embedding produced by the background derivation pipeline (`"embed"` stage, `MobileCLIP-S2`). One row per photo that has been embedded.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT **PK** | References `assets.hash`. |
| `model` | TEXT | Identifier of the model that produced this vector (e.g. `"mobileclip_s2"`). Allows safe invalidation when the model changes. |
| `dim` | INTEGER | Vector dimensionality (e.g. `512`). |
| `vector` | BLOB | `dim` × `Float16` little-endian, **L2-normalized** (so cosine similarity equals the dot product). |

Machine-derived and keyed by content hash. A reader **MAY** use this table for image similarity search if it has access to the same model (embed a query → dot-product against stored vectors, descending order); it MUST verify that the `model` column matches the model it is using. It is a **droppable cache** — dropping the table causes the pipeline to re-derive embeddings from originals; no information is permanently lost. External readers MUST ignore it for anything other than read-only similarity queries.

### `people` (v8, rebuildable mirror of XMP sidecars)

Named people created by the user in the People view. A `people` row is created when a user assigns a name to a face cluster; it is a **mirror** of the human-authored person decisions whose durable, portable record is the asset's XMP sidecar (`mwg-rs:Regions` — see `vault-format-v1.md §5`). The catalog `people` table is rebuildable by re-ingesting confirmed face regions from sidecars.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER **PK** | Auto-incremented. Referenced by `faces.personID`. |
| `name` | TEXT | Person's name as entered by the user. Not nullable. |
| `createdAtMs` | INTEGER | Epoch milliseconds when the person was first named. |

External readers MAY use this table to enumerate named people and count their face appearances (join with `faces` on `personID`). **The sidecars are the durable source of truth for names and confirmed assignments; the catalog is a rebuildable mirror.**

### `faces` (v8, rebuildable machine cache)

One row per detected human face across the library, produced by the background `"faces"` derivation stage (Apple Vision `VNDetectFaceRectanglesRequest` + `VNGenerateImageFeaturePrint`). This table is the primary machine-derived/rebuildable cache. The `personID` and `source = 'confirmed'` rows also mirror human decisions recorded durably in XMP sidecars; the sidecars govern on any conflict.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER **PK** | Auto-incremented. |
| `hash` | TEXT | References `assets.hash` (indexed). |
| `rectX` | REAL | Vision normalized `boundingBox` **minX** (left edge). Bottom-left origin, range 0–1. |
| `rectY` | REAL | Vision normalized `boundingBox` **minY** (bottom edge). Bottom-left origin, range 0–1. |
| `rectW` | REAL | Vision normalized `boundingBox` width (range 0–1). |
| `rectH` | REAL | Vision normalized `boundingBox` height (range 0–1). |
| `embedding` | BLOB | `dim × Float16` little-endian feature-print vector (from `VNGenerateImageFeaturePrint`, stored as Float16 to halve disk cost; loaded as `Float32` in memory). |
| `dim` | INTEGER | Vector dimensionality — required to interpret the `embedding` blob. |
| `personID` | INTEGER? | References `people.id`; `NULL` = unassigned / not yet named (indexed). |
| `confidence` | REAL | Detection confidence reported by `VNFaceObservation` (0–1). |
| `source` | TEXT | `"auto"` — machine-detected, not yet confirmed by the user; `"confirmed"` — user has assigned this face to a person (mirrored from the XMP sidecar). |

**Coordinate convention:** `rectX`/`rectY`/`rectW`/`rectH` are stored in Vision's native frame — `boundingBox` with **bottom-left origin**, y increasing upward. This is the *opposite* of the MWG `stArea` convention (top-left origin, center point); see `vault-format-v1.md §5` for the conversion used when writing/reading sidecars.

**Sovereignty split:** `source = 'auto'` rows are machine-derived and rebuildable at any time (re-detect from the original). `source = 'confirmed'` rows and `personID`/`people.name` mirror **human decisions** — these are durably recorded in the asset's XMP sidecar as `mwg-rs:Regions` entries. On a rebuild, confirmed assignments are reconstituted by re-ingesting sidecars. The machine **never overwrites confirmed rows** — `replaceFaces` (re-detection) deletes only `source = 'auto'` rows, leaving confirmed rows intact.

### `geocode` (v9, rebuildable)

One row per geotagged asset that has been reverse-geocoded. Machine-derived from the asset's `latitude`/`longitude` in `assets` against the **bundled offline GeoNames city-level dataset** (cities15000, CC BY 4.0). 100% rebuildable: dropping this table and re-running the `"geocode"` derivation stage re-derives all rows from the stored GPS coordinates — no information is permanently lost. **Catalog-only: there is no sidecar write and no vault format change.** A place name is a deterministic function of GPS + the dataset.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT **PK** | References `assets.hash`. |
| `city` | TEXT | City or locality name (GeoNames `name` field). May be empty if the nearest city lookup produced no result within the search radius. |
| `region` | TEXT | Admin-1 region / state / province (GeoNames `admin1CodesASCII` lookup). |
| `country` | TEXT | Full country name (GeoNames `countryInfo` lookup). |
| `countryCode` | TEXT | ISO 3166-1 alpha-2 country code (indexed). |

**Data attribution:** Place data is sourced from [GeoNames](https://www.geonames.org), licensed **CC BY 4.0** — redistribution is allowed but **attribution is required**. Attribution string: *"Place data © GeoNames (https://www.geonames.org), CC BY 4.0."* This must be surfaced in the app's About / credits screen.

A reader MAY use this table for place display and filtering (e.g. filter to a country or city in a snapshot browser). It is a **droppable cache** — a reader MUST NOT rely on it being present in snapshots older than schema version 9, and MUST treat it as absent if the table is missing.

### `phash` (v10, rebuildable)

One row per photo that has been perceptually hashed. Machine-derived from the image bytes by the background `"phash"` derivation stage. 100% rebuildable: dropping this table and re-running the `"phash"` derivation stage re-derives all rows from the original images — no information is permanently lost. **Catalog-only: there is no sidecar write and no vault format change.** The hash is a deterministic function of the decoded image.

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT **PK** | References `assets.hash`. |
| `value` | INTEGER **NOT NULL** | Signed 64-bit perceptual **dHash** (difference hash) of the image, used for near-duplicate detection. |

A reader MAY use this table for near-duplicate detection (e.g. grouping visually similar photos by Hamming distance over the 64-bit `value`). It is a **droppable cache** — a reader MUST treat it as an optional cache that may be absent (e.g. in snapshots from schema versions < 10), and MUST treat it as absent if the table is missing.

### `finder_tag_sync` (v11, rebuildable Mac-local sync-state)

One row per asset that has participated in macOS Finder-tag sync. The `baseline` is the **last-synced tag set** for that asset — the common ancestor used as the baseline of the 3-way merge that reconciles OpenPhoto's tags with the Finder tags written on the asset's local files. It is **machine-derived, Mac-local sync bookkeeping**: it records what the last sync agreed on, not a source of truth. The authoritative tag record lives in the asset's XMP sidecar (mirrored into `assets.tagsJSON`); Finder tags live in the files' macOS extended attributes. 100% rebuildable: dropping this table makes the **next** Finder-tag sync purely additive for one cycle (no deletions are propagated, because there is no baseline to diff against), after which it re-seeds itself — no portable information is permanently lost. **Catalog-only: there is no sidecar write and no vault format change.**

| Column | Type | Notes |
|---|---|---|
| `hash` | TEXT **PK** | References `assets.hash`. |
| `baseline` | TEXT **NOT NULL** | JSON array of the last-synced tag strings (e.g. `["beach","2024"]`). |

A snapshot reader MAY ignore this table entirely — it is Mac-local Finder-tag sync state (which tags the source Mac's last sync settled on), not part of the portable record. It is a **droppable cache** — a reader MUST NOT rely on it being present in snapshots older than schema version 11, and MUST treat it as absent if the table is missing.

`Catalog.schemaVersion` is **11** (written into `snapshot.json`'s `catalog_schema_version` field).

---

## Portability key

> A snapshot reader uses ONLY `assets` (hash-keyed machine metadata; the human columns `favorite`/`rating`/`caption`/`tagsJSON` are mirrors of the XMP sidecars — the sidecars are authoritative and win on ingest) and this drive's `vault_presence` rows (those whose `vaultID` equals the drive's own vault id). A reader MUST ignore `vaults.rootPath`/`lastSeenMs` (the source Mac's local paths), `instances` (the source Mac's local-vault rows), `vault_presence` rows for other `vaultID`s (other drives the source Mac happens to know), and `pending_deletions` (the source Mac's delete queue), and `pending_folder_ops` (the source Mac's offline-drive folder-op queue). The drive's `manifest.jsonl` is the authoritative inventory of what the drive holds; the snapshot only accelerates browsing it. The v5 pipeline-cache tables follow the same rule: a reader MAY use `ocr` (hash-keyed machine-derived text, like `assets`) but MUST ignore `derivation_jobs` (the source Mac's internal pipeline bookkeeping). The v7 `embeddings` table is a droppable cache: a reader MAY use it for image similarity (dot-product over L2-normalized Float16 vectors) if it holds the same model as the `model` column, but MUST NOT rely on it being present — treat it as absent if the model doesn't match or the table is missing. The v8 `faces` and `people` tables: a reader MAY use `faces` for face grouping and `people` for named-person enumeration, but MUST treat `personID`/`people.name` as a mirror only — the durable, authoritative record of confirmed person assignments is the asset's XMP sidecar (`mwg-rs:Regions`). A reader MUST NOT rely on `faces` or `people` being present in older snapshots (schema versions below 8). The v9 `geocode` table is a droppable cache: a reader MAY use it for place display and filtering (city, region, country, countryCode per geotagged asset), but MUST NOT rely on it being present in snapshots older than schema version 9. Place data is sourced from GeoNames (CC BY 4.0) — attribution required: *"Place data © GeoNames (https://www.geonames.org), CC BY 4.0."* The v10 `phash` table is a droppable cache: a reader MAY use it for near-duplicate detection (Hamming distance over the signed 64-bit dHash `value` per photo), but MUST treat it as an optional cache that may be absent — it MUST NOT rely on it being present in snapshots from schema versions below 10, and MUST treat it as absent if the table is missing. The v11 `finder_tag_sync` table is Mac-local Finder-tag sync state, not part of the portable record: a reader MUST ignore it (its `baseline` JSON records which tags the source Mac's last Finder-tag sync settled on for each asset — the authoritative tags live in the XMP sidecars, mirrored into `assets.tagsJSON`). It is a droppable cache — a reader MUST NOT rely on it being present in snapshots from schema versions below 11, and MUST treat it as absent if the table is missing.

---

## Versioning

The `catalog_schema_version` field in `snapshot.json` is incremented whenever a backwards-incompatible change is made to any table (column rename, type change, removal). Additive changes (new nullable columns, new tables) increment the minor part only; readers that know an older version MUST tolerate unknown columns. A reader that encounters a `catalog_schema_version` higher than it understands MUST fall back to re-scanning from originals, sidecars, and `manifest.jsonl`, and MUST NOT rely on any snapshot data.
