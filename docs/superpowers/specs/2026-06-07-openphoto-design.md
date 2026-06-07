# OpenPhoto — Design Spec

**Date:** 2026-06-07
**Status:** Approved by Jude (brainstorming session)
**Repo:** https://github.com/jude-sph/OpenPhoto.git
**Raw requirements:** [docs/SPECS.md](../../SPECS.md)

## 1. What this is

A native macOS photo manager built on one promise: **the library is just files**. Photos and videos live in the user's existing folders (`~/Pictures`, `~/Movies` — arbitrary, nestable folders like `rome2022` or `mac-screenshots`), exactly as they are. The app indexes, views, imports, syncs, and analyzes — but the library remains fully usable and browsable with the app deleted. The Obsidian philosophy applied to photos: forward compatibility, plain files, no lock-in.

**Hard invariant:** originals are never modified or moved without explicit user action. All app-generated data lives in sidecars or a rebuildable index.

## 2. Decisions log

| Decision | Choice |
|---|---|
| Stack | Native Swift + SwiftUI (Vision, Core ML, ImageCaptureCore, MapKit); SQLite via GRDB |
| Architecture | Vault + Catalog (option A): self-describing vaults everywhere, rebuildable live catalog on the Mac, catalog snapshot on drives |
| Mac ↔ drive topology | Mac = working subset + full catalog of everything; canonical drive = everything |
| Working set control | Per-folder pinning; explicit evict, never automatic |
| Delete vs evict | Strictly separate operations. Delete → vault bin, propagates to drive bin only after explicit review. Evict → releases verified-synced local copy, propagates nothing |
| Folder semantics | Folders are arbitrary and nestable; folder ≠ event; videos mixed with photos in folders |
| Sidecar format | Per-file XMP, full-name convention: `IMG_4123.heic.xmp` |
| Sidecar location | Hidden subfolder per folder: `rome2022/.openphoto/IMG_4123.heic.xmp` (folder stays self-contained; Finder stays clean; convertible to beside-file layout by a one-click export) |
| Asset identity | BLAKE3 content hash; `(path, size, mtime)` fast-path on rescan |
| Intelligence | 100% local (M4 Pro); derived at import time so offline photos stay searchable |
| Scale target | ~200–250 GB now (≲100k items); design incremental so 10× doesn't break |
| First milestone | Browse (index + timeline + folders + viewer) |

## 3. Core concepts

### Vault
A folder tree that is a library location. Mac library = two vaults (`~/Pictures`, `~/Movies`). A drive carries one vault whose top level mirrors the Mac vault roots by name (`Pictures/`, `Movies/`). Each vault root has a `.openphoto/` directory:

- `manifest.jsonl` — one line per asset: content hash, vault-relative path, size, mtime. Plain text: greppable, diffable, rebuildable from the filesystem.
- `sync-log.jsonl` — append-only journal of import/sync sessions.
- `bin/` — deleted items with original relative paths preserved.

A vault is self-describing: any Mac running OpenPhoto opens it as a library.

### Asset identity = content hash
The BLAKE3 hash of file bytes is the asset ID. Renames and moves (even in Finder) preserve identity — rescan matches the hash and updates the path; metadata, faces, and history follow. Originals are immutable by invariant, so hashes are permanent. Dedup is structural: same hash in two places = one asset, two instances. A Live Photo is one logical asset of two files (HEIC + MOV paired via Apple's content identifier metadata), each hashed individually.

If a file's bytes ever change in place (an outside app edited it), the new hash is treated as a **new asset** and the event is flagged for review; archived copies of the old asset are never silently overwritten.

### Catalog
Live SQLite database at `~/Library/Application Support/OpenPhoto/` plus a content-addressed thumbnail cache. Knows every asset across all vaults, online or offline. **Strictly rebuildable** from vaults (slowly — ML re-runs). Core tables:

```
assets:      hash PK, kind (photo/video/live), taken_at, gps, dims, camera, live_pair_hash, …
instances:   hash → (vault_id, rel_path, size, mtime)      ← the presence map
vaults:      id, role (local/canonical/backup), root path or volume ID, last_seen
folders:     materialized tree across vaults (incl. offline)
faces:       asset hash, bbox, embedding, cluster_id, confidence
persons:     named clusters; user merge/split state (human anchors)
ocr:         FTS5 full-text per asset
embeddings:  CLIP vector per asset
jobs:        per-asset per-stage pipeline completion (resumable)
queues:      pending sidecar writes for offline assets; pending delete propagations
```

The presence map answers at any moment: *what exists only on the Mac and isn't backed up anywhere?* The sync screen leads with that number. Drive vaults remain browsable while unplugged via their last-known manifest + catalog data (thumbnails, metadata, search all work; full-res asks for the drive).

Each sync refreshes a **catalog snapshot** (`<drive vault>/.openphoto/catalog-snapshot/`: catalog + thumbnails) onto the drive, making the drive a complete library *with intelligence included* — plug into a fresh Mac and browse/search immediately, no ML re-run. The Mac catalog is the only live copy; the snapshot is write-only at sync end (never merged back — except during migration adoption, §5.5).

### Metadata rule
Anything a **human authored** — tags, ratings, captions, people names (as MWG face regions) — is written to standard XMP sidecars in the per-folder `.openphoto/` subfolder. Anything a **machine derived** — thumbnails, embeddings, face vectors, OCR, clusters — lives only in the catalog. Sidecar edits to offline assets are queued in the catalog and applied to the drive's sidecar files at next sync. The app self-heals sidecar associations via content hash after outside renames/moves.

## 4. Deletion model

- **Delete** = move file + sidecar into the vault's `.openphoto/bin/` (original path preserved), record the event, queue for propagation. One-click restore. Emptying the bin moves files to macOS Trash — still recoverable. Nothing in the system ever hard-deletes.
- **Propagation**: at next drive sync, a review screen lists deletions since the last sync; on confirmation, drive copies move to the *drive's* bin.
- **Evict** = an unrelated operation: release a folder's local full-res copies (to macOS Trash) once every item is hash-verified on the canonical drive. Catalog keeps the folder browsable/searchable. Reversed by **rehydrate**.

## 5. Sync engine

**Design resolution: drives are passive; every flow is one-way; there is no merge logic in the system.** Human gates exist in exactly three places: import selection, delete propagation, drift review.

### 5.1 Import (phone via ImageCaptureCore / SD via mounted DCIM → Mac)
Big grid of large thumbnails; already-imported items badged (pre-download heuristic: name+size+date; hash-certain after copy). User selects items and a destination folder (existing or new). Pipeline per item: **copy → hash → dedup-check → place → manifest + catalog update → verify**. Only verified items are offered for device deletion. Live Photo pairs import as one asset. Import sessions are recorded in `sync-log.jsonl`.

### 5.2 Sync (Mac → canonical drive)
On plug-in: read drive manifest → reconcile → present a **plan** before touching anything: new files (with sizes), sidecar updates, folder renames, deletions to review. Properties:

- Folder renames/moves propagate as renames (hash matching) — no recopying.
- Every copy: temp file → fsync → re-hash verify → rename into place → then record in both manifests. Interrupted sync leaves only temp files; re-run is idempotent and resumes.
- Disk space pre-checked in the plan; failure happens before copying, not during.
- Catalog snapshot refreshed last, after all verification.

### 5.3 Evict / Rehydrate
Per-folder. Evict requires full hash-verification on canonical. Rehydrate copies a folder back from the drive, verified the same way.

### 5.4 Clone (canonical → backup)
The Mac cannot populate backups alone (it lacks evicted originals), so backups are made by cloning canonical → backup with **both drives plugged in** — manifest-driven, hash-verified. Any number of backup drives; the catalog tracks per-drive presence.

### 5.5 Migration
Clone + flag flip: clone canonical onto the new location (drive or the Mac itself), verify completely, then designate the new location canonical. When adopting a drive on a fresh Mac, the app imports the drive's catalog snapshot as the starting live catalog, then verifies against the manifest.

### 5.6 Drift & integrity
Every plug-in runs fast reconciliation (manifest vs. filesystem, size/mtime). Outside changes to a drive surface as a **drift review** — repair options, never auto-resolution. On-demand **Verify Integrity** re-hashes a vault against its manifest (bit-rot detection). Local vaults are watched live via FSEvents plus a verifying scan at launch.

## 6. Intelligence pipeline (all local)

One derivation pipeline, run as resumable background jobs when an asset enters the library (so derived data outlives eviction):

1. EXIF/dates/GPS/camera extraction → catalog
2. Thumbnails (content-addressed, multiple sizes)
3. Face detection + feature-print embedding (Vision)
4. OCR (`VNRecognizeTextRequest`) → FTS5
5. Semantic image embedding (CLIP-class Core ML model, e.g. MobileCLIP)
6. Reverse geocoding via a **bundled offline dataset** (no network calls; CLGeocoder rejected as online)

Backfill estimate for current library on M4 Pro: hashing minutes; thumbnails ~1–2 h; ML overnight; all interruptible/incremental.

**Faces & people:** embeddings clustered with an adjustable threshold. People view: name a cluster → Person; merge/split; per-face confidence shown; reassign individual faces. Named/confirmed assignments are written to sidecars as MWG face regions and act as fixed anchors on re-cluster — the machine never undoes a human decision. Unnamed clusters stay catalog-only.

**Search:** one box fanning out to (a) structured filters — date, folder, person, place, camera, rating, tags; (b) OCR full-text; (c) semantic vector similarity (brute-force at this scale). "Me and my girlfriend at a restaurant in Taipei" = person filters + geocoded place + semantic match. V1 uses a deterministic query parser; an on-device LLM query-rewriter is a phase-5 add-on that slots in front without changing the indexes.

**Map:** MapKit, clustered pins from the GPS index; region-select → grid.

## 7. App structure

- **`OpenPhotoCore`** — headless Swift package: vaults, manifests, hashing, catalog (GRDB), scanner/watcher, sync engine, pipeline, search. No UI imports; fully testable headless. A future `openphoto` CLI wraps this.
- **`OpenPhoto.app`** — SwiftUI. Views call Core's API; never the filesystem.

**UI surfaces** (structure; visual design comes from a separate Claude Design pass): sidebar (Timeline · Folders tree · People · Map · Bin · Devices-when-connected · pipeline status) · virtualized timeline grouped day/month/year with video/Live/offline badges · folder tree mirroring disk exactly · inspector (EXIF read-only; tags/rating/caption/people editable; presence per drive) · import grid · sync plan review · dedup review (identical-hash groups) · viewer (zoom, Live Photo playback, video).

**UI reference:** the authoritative visual design is the Claude Design handoff in `UI-Design/design_handoff_openphoto/` (interactive prototype: `OpenPhoto.html`; tokens/screens documented in its `README.md`). Recreate natively in SwiftUI — never embed the HTML. Deltas where this spec overrides the mockup: (a) bin holds items indefinitely until manually emptied — the mockup's "30 days" copy is wrong (auto-empty may become an opt-in setting later); (b) the "Albums" sidebar section is out of scope — folders, People, and Map are the organizational surfaces; (c) the sync screen's "Schedule for later" button is dropped.

## Changelog

- **2026-06-07** — Initial approved design. Added UI reference section after Claude Design handoff landed in `UI-Design/`, with three mockup-vs-spec deltas resolved in the spec's favor.

## 8. Error-handling doctrine

1. Originals never written; every mutation is a new file in a `.openphoto/` dir
2. All writes atomic (temp → fsync → rename); all copies hash-verified before being recorded
3. Ambiguity becomes a human review, never an auto-resolution
4. Every long job resumable; sync re-runs idempotent
5. Catalog rebuildable from vaults; manifests rebuildable from filesystem + catalog — no single point of data death
6. Plans pre-check resources and fail before acting

Permissions: Full Disk Access for `~/Pictures`/`~/Movies` if sandboxed-out; security-scoped bookmarks for drive vaults.

## 9. Testing

- **Core unit tests:** hashing, manifest round-trip, sidecar emit/parse, Live Photo pairing, dedup.
- **Sync scenario tests** on throwaway temp-dir vaults: kill-mid-copy resume, double-run idempotency, drift injection, rename storms, evict-safety (refusal without verified canonical copy).
- **Pipeline golden tests:** fixture images with known faces, OCR text, GPS.
- UI: manual for v1.

## 10. Phases

Each phase is its own implementation plan and ends with a usable app:

1. **Browse** — Core foundation (vault/manifest/hash/catalog/scanner), timeline, folder tree, viewer, inspector, local bin. *Includes the ImageCaptureCore deletion spike to de-risk phase 2.*
2. **Import** — iPhone/SD grid, verify-then-delete, dedup-on-import.
3. **Drives** — canonical sync, evict/rehydrate, clone/migrate, drift review, integrity verify, delete propagation, catalog snapshot.
4. **Intelligence** — pipeline, People view, unified search, Map, OCR.
5. **Extras** — LLM query parsing, perceptual near-duplicate detection, CLI tool, sidecar layout export.

## 11. Known risks & spikes

- **iPhone deletion over USB**: iOS restricts ImageCaptureCore deletion when iCloud Photos is enabled (and is generally flaky). Spike in phase 1. Fallback: user confirms deletion on-phone after verified import.
- **MobileCLIP model selection/conversion**: verify a Core ML build with acceptable quality and a usable text encoder before phase 4.
- **Offline reverse-geocode dataset**: choose one (~tens of MB, city-level is sufficient) before phase 4.
- **HEIC/Live Photo edge cases**: pairing relies on Apple's content identifier; some third-party apps strip it. Fallback heuristic: same basename + adjacent timestamps.
