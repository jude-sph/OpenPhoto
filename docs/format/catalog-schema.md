# OpenPhoto Catalog Schema — Version 5

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

---

## Portability key

> A snapshot reader uses ONLY `assets` (hash-keyed machine metadata; the human columns `favorite`/`rating`/`caption`/`tagsJSON` are mirrors of the XMP sidecars — the sidecars are authoritative and win on ingest) and this drive's `vault_presence` rows (those whose `vaultID` equals the drive's own vault id). A reader MUST ignore `vaults.rootPath`/`lastSeenMs` (the source Mac's local paths), `instances` (the source Mac's local-vault rows), `vault_presence` rows for other `vaultID`s (other drives the source Mac happens to know), and `pending_deletions` (the source Mac's delete queue). The drive's `manifest.jsonl` is the authoritative inventory of what the drive holds; the snapshot only accelerates browsing it. The v5 pipeline-cache tables follow the same rule: a reader MAY use `ocr` (hash-keyed machine-derived text, like `assets`) but MUST ignore `derivation_jobs` (the source Mac's internal pipeline bookkeeping).

---

## Versioning

The `catalog_schema_version` field in `snapshot.json` is incremented whenever a backwards-incompatible change is made to any table (column rename, type change, removal). Additive changes (new nullable columns, new tables) increment the minor part only; readers that know an older version MUST tolerate unknown columns. A reader that encounters a `catalog_schema_version` higher than it understands MUST fall back to re-scanning from originals, sidecars, and `manifest.jsonl`, and MUST NOT rely on any snapshot data.
