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
- **Propagation**: at next drive sync, a review screen lists deletions since the last sync; on confirmation, drive copies move to the *drive's* bin. Review is available **standalone** (a "Review Deletions" gate on the drive, any time it's connected) as well as inside the sync plan; both share one confirm and move copies into the drive vault's `.openphoto/bin/` (`origin:"propagated"`).
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

### 5.4 Clone & backups (canonical → backup)
The Mac cannot populate backups alone (it lacks evicted originals), so backups are made by cloning canonical → backup with **both drives plugged in** — manifest-driven, hash-verified, identity-mapped (a mirror: the backup's layout equals the canonical's). Any number of backup drives; the catalog tracks per-drive presence.

**The canonical is the source of truth; backups are derived from it.** A backup is a full redundant copy whose contents are *defined by* the canonical. The principle:

- **Reads treat all connected durable drives (canonical + backup) as equal** — any of them satisfies "backed up", and any is a valid source for browse, rehydrate, send-from-drive, and verified-evict (re-hashing a backup copy is proof as good as canonical). When several are connected, **canonical is preferred** as the read source.
- **Writes flow one-way, canonical → backup, only.** A backup never feeds back into the canonical (no merge — except the explicit migration flag-flip, §5.5). Additions always flow *through* the canonical: a backup never receives a photo before the canonical has it. When a backup deviates from the canonical, the backup is **wrong** and is repaired *from* the canonical (drift restore), never the reverse.

**Keeping backups current — no byte caching, no bloat.** When the canonical gains photos (a new import synced Mac→canonical) or loses them (a deletion), other drives may be unplugged. The Mac never stages the changed *bytes* — the canonical **is** the byte store. It remembers only tiny metadata it already has: **per-drive presence** (which hashes each drive holds, in the catalog) and **pending deletions** (just hashes). Bringing a backup up to date is therefore two independent streams:

- **Additions** = a re-runnable, diff-driven clone (canonical manifest − backup manifest = the missing files), copied canonical → backup. This requires the canonical *and* the backup both connected (the bytes live on canonical). Nothing accumulates on the Mac, so adding GBs to the canonical while a backup is away costs the Mac nothing — the diff is recomputed and copied the next time both are present.
- **Deletions** = per-drive cached instructions (a hash each). A deletion stays pending **for every drive that still holds the photo** and applies (through the Review-Deletions gate) when that drive next connects — needing only that drive (the instruction is the cache). It clears for a drive once that drive no longer holds the hash, and clears entirely once no drive holds it. So a deleted photo can never resurrect from an unplugged backup, and the only thing "remembered" indefinitely is a hash.

On connect, the app already knows from the catalog whether a backup is behind, and offers to **update it** — copy the additions (if the canonical is also connected) and review+apply its pending deletions (always). If the canonical is absent, deletions still apply and the additions are reported as pending ("connect the canonical to copy N photos").

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

**Known UI issues (to polish, surfaced 2026-06-09):** the vertical divider between the left sidebar and the content area doesn't reach the top of the window — it stops below the title-bar / traffic-light region, leaving a short gap at the top edge of the divider.

## Changelog

- **2026-06-07** — Initial approved design. Added UI reference section after Claude Design handoff landed in `UI-Design/`, with three mockup-vs-spec deltas resolved in the spec's favor.
- **2026-06-08** — Phase 1 implemented (45+ commits on `phase1-browse`). ICC deletion spike resolved §11's iPhone-deletion risk positively (works with iCloud Photos ON). Hash algorithm pinned to SHA-256 (`sha256:` prefix) in format v1 — see format doc §2. Timeline gained grouping modes (day/week/month/year/continuous) and the viewer a rename action, both from first user-testing feedback.
- **2026-06-08** — Phase 2 (Device Import) implemented and user-validated (iPhone via ImageCaptureCore, SD/volume, import registry §12, opt-in free-up-phone). Added a **Library Selection / Evict / Send-to-device / Locations** feature on top — its own design spec (`2026-06-08-library-selection-evict-send-design.md`): shared multi-select in timeline + folders, evict-to-bin with an only-copy warning, send back to an iPhone via **AirDrop** (verified by re-enumeration) and to volumes by hash-verified copy (new registries: `sends.jsonl` §13, `devices.jsonl` §14), and an inspector **Locations** panel (confirmed/believed/historical presence). Key finding: **USB push to an iPhone is impossible** (ImageCaptureCore is read+delete only) — AirDrop is the transport, the cable is identity/verification only; two spikes proved AirDrop lands photos at their original date and round-trips byte-for-byte. **Deferred to Phase 5:** a tiled thumbnail renderer to fix the dense-grid Space-switch compositing lag (`docs/spikes/2026-06-08-dense-grid-compositing-lag.md`). **Outstanding:** SD-card *send* hardware smoke. Next up: **Phase 3 (Drives)**.

- **2026-06-09** — Phase 3 (Drives) started on `phase3-drives`. **Slice 1 (sync spine)** implemented: a `DriveVolume` abstraction (one path-based `FileSystemVolume` covers folder, attached exFAT `.dmg`, and real volume — no security-scoped bookmarks, matching the app's path-based model); `SyncEngine` `plan`/`apply` for additive one-way Mac→canonical sync (atomic temp→fsync→rename, re-hash verify, resumable, **never overwrites** — collisions reported as conflicts); catalog `vault_presence` table (migration v2, isolated from `instances` so timeline browse never double-counts); drive vaults surface as `.confirmed` locations in `PresenceService`; Drives sidebar + Add-Drive adoption + Sync plan-preview sheet (free-space check) + "backed up on canonical" badge. Tested across the three-tier ladder (temp-dir scenarios + a real attached exFAT disk image — which caught an exFAT `volumeAvailableCapacityForImportantUsage == 0` free-space bug). Detailed plan: `docs/superpowers/plans/2026-06-09-phase3-slice1-sync-spine.md`. Remaining Phase 3 slices (drift/integrity, deletion propagation, evict/rehydrate + optional send-from-drive, clone/migration) each get their own spec → plan → build. Slice 1 introduces no new on-disk format.

- **2026-06-09** — Phase 3 **Slice 2 (Drift & Integrity)** implemented: `DriftReconciler` fast scan (unknown/missing/changed via size+mtime) + **Verify Integrity** (full re-hash → corrupt/bit-rot); recoverability via `PresenceService` (restorable-from / lost-no-copy); non-destructive repairs (adopt/restore/acknowledge — `VerifiedCopy` extracted from `SyncEngine`); **honest presence** (badges follow verified reality); auto-scan on connect, per-drive status line, Verify progress, and bulk Adopt/Restore actions. Detailed spec/plan: `docs/superpowers/specs/2026-06-09-phase3-slice2-drift-integrity-design.md`, `docs/superpowers/plans/2026-06-09-phase3-slice2-drift-integrity.md`. Also recorded a **Phase 5 backlog** (§10) from usage feedback: video-only filter, Finder-tag interop, tag search.

- **2026-06-09** — Phase 3 **Slice 3 (Deletion propagation)** implemented on `phase3-drives`. The first destructive slice: locally-deleted photos can have their canonical-drive copies moved into the drive vault's `.openphoto/bin/` (`origin:"propagated"`), reviewed via a standalone "Review Deletions" gate or a Sync-plan section (thumbnailed, select-all, per-row restore). A dedicated Delete-only catalog queue (`pending_deletions`, migration v4) records true deletions only — eviction never propagates. Eligibility (queued ∧ no-local-instance ∧ on-drive) is computed at review time. New `DeletionPropagator` (pure `eligible` + destructive `propagate`: BinStore move + atomic manifest rewrite + presence/queue/sync-log update; idempotent, failures stay queued). Format `vault-format-v1` §8 clarified (vault bin hosts propagated deletions; `.openphoto-trash/` is removable-non-vault-only) and §9 gained the `"delete"` event. Deferred: drive-only deletion → Slice 4; backup-drive propagation → Slice 5. Spec: `docs/superpowers/specs/2026-06-09-phase3-slice3-deletion-propagation-design.md`.
- **2026-06-09** — Phase 3 **Slice 4 (Evict / Rehydrate / drive-only deletion)** implemented on `phase3-drives`. **Evict** became the *real* operation (no longer a bin shortcut): it releases a local original to the **macOS Trash** (recoverable, never a hard-delete) only after the copy is verified on a **connected** canonical drive by **re-hashing** the drive file — `.verified` mode, the default. A `.forced` override (release trusting recorded drive presence, drive may be absent) is gated behind an acknowledgment toggle and "a few clicks", not the default. Live pairs evict as a unit (both halves verify or both are refused); the local sidecar is left in place. **Rehydrate** copies evicted (drive-only) originals back from a connected drive, hash-verified (`VerifiedCopy`), via the inverse drive→local path mapping; "already local" counts as restored (idempotent). **Drive-only deletion** (deferred from Slice 3): delete a photo that exists only on the drive → straight into the drive's `.openphoto/bin/` (`origin:"user"`, no pending queue), Live pair expanded. New `LibraryService+Eviction` (`evict`/`rehydrate`, `EvictMode`/`EvictOutcome`/`RehydrateOutcome`) and `DeletionPropagator.deleteDriveOnly`; format `vault-format-v1` §9 gained the `"rehydrate"` event. Inspector shows **Evict** when the drive is connected, **Force Evict** when it isn't, and neither when the photo isn't on the Mac or isn't backed up. Spec: `docs/superpowers/specs/2026-06-09-phase3-slice4-evict-rehydrate-design.md`. Deferred: send-from-drive → Slice 4.5; clone/migration + catalog snapshot → Slice 5.
- **2026-06-10** — Phase 3 **Slice 4.5 (Send-from-drive)** implemented on `phase3-drives`. The user can now **Send** (AirDrop to a phone / copy to a volume) photos that exist only on a plugged-in canonical drive — sourced **directly from the drive**, without rehydrating to the Mac first. New pure Core resolver `LibraryService.resolveSendSources` splits a selection into `sendable` `SendItem`s (each sourced from the local file, or directly from a connected drive's file — no temp staging) and an `unreachable` remainder (drive-only items whose drive is unplugged), grouped by drive. `SendSheet` gained a **pre-flight warning** that names which photos can't be sent and which drive to connect, with **Send N** (reachable count; disabled when none) / Cancel — the all-reachable case skips the warning entirely (unchanged flow). `SendEngine`/`SendDestination`/`VolumeCopyDestination`/`AirDropDestination`/`sends.jsonl` are reused **unchanged**: the engine is source-agnostic, so hash-keyed dedup and hash-verified copy hold regardless of where the bytes came from. Deliberately **read-only on the drive** — no drive sync-log write (the send is already journaled in `sends.jsonl` + the primary vault's sync-log), keeping the drive a pure read source. **No on-disk format change.** Spec: `docs/superpowers/specs/2026-06-10-phase3-slice4.5-send-from-drive-design.md`. Remaining in Phase 3: **Slice 5 (Clone / Migration + catalog snapshot)**, then merge `phase3-drives` → `main`.
- **2026-06-10** — Phase 3 **Slice 5a (Clone + first-class backups + durable deletion)** implemented on `phase3-drives` (first of three Slice-5 sub-slices). **Clone** mirrors the canonical onto a backup drive (`SyncEngine.planClone`, identity-mapped — destination paths equal the canonical's drive-layout paths, no re-prefix), hash-verified and **diff-driven/re-runnable** (re-running copies only what's new); `apply`'s logging was generalized so a drive→drive clone logs a `"clone"` event on the destination only. **Backups are first-class durable drives** (`AppState.durableVaults` = canonical + backup): they contribute presence/browse/the "backed up" badge and are valid rehydrate/send/verified-evict sources, with the **canonical preferred** as the read source (`connectedDrivesCanonicalFirst()`). **Durable deletion propagation:** a `pending_deletions` entry now clears only once **no** drive's `vault_presence` holds the hash (`Catalog.clearPendingDeletionsWithoutPresence`), so a deletion is remembered for an unplugged backup and applies (via the per-drive Review-Deletions gate) on its next connect — nothing resurrects from a backup. **No byte caching on the Mac** — the canonical is the byte store; backups pull additions from it when both are connected (the Mac remembers only per-drive presence + deletion hashes). The Drives panel labels Canonical/Backup and offers "Make backup" / "Update backup (N)". **No on-disk format change** (`"clone"` is an existing §9 event; clone writes the already-specified `manifest.jsonl`/`vault.json`). *Deferred to 5c:* rewriting a cloned drive's on-disk `vault.json` role to `backup` (the catalog role is authoritative for single-Mac 5a; the self-description flip matters for cross-Mac adoption/migration). Spec: `docs/superpowers/specs/2026-06-10-phase3-slice5a-clone-backups-design.md`; principle in §5.4. Remaining: **5b** (catalog-snapshot write + `catalog-schema.md` + fresh-Mac adoption), **5c** (migration / role flag-flip), then merge `phase3-drives` → `main`.
- **2026-06-10** — Phase 3 **Slice 5b (Catalog snapshot + confirmed adoption)** implemented on `phase3-drives` (second Slice-5 sub-slice). A drive now carries a **disposable copy of the machine-derived index** at `<drive>/.openphoto/catalog-snapshot/` (`catalog.sqlite` via SQLite `VACUUM INTO`, `thumbs/` for only this drive's manifest hashes, `snapshot.json` header), written **atomically** (`temp dir → replaceItemAt`) at the end of each sync and clone — documented in format §7 + the new `docs/format/catalog-schema.md` (with a portability key: a reader uses only `assets` + this drive's `vault_presence`, ignores Mac-local rows, and the `manifest.jsonl` is authoritative). **Confirmed adoption** (a prompt, never silent): plugging a snapshot-carrying drive into a Mac that doesn't know it offers **Adopt**, which **imports** the snapshot (`CatalogSnapshot.import` — assets *insert-if-absent* so local human metadata is never clobbered + this-drive presence + thumbnails) for **instant drive-only browse**, then **verifies against the manifest in the background** (`CatalogSnapshot.verifyAdoption` — manifest wins: stale rows dropped, manifest-only entries added with minimal assets). The snapshot DB is opened **read-only** so adoption never writes to the drive. Drives now **self-describe their role in `vault.json`** (`Vault.writingRole`; a clone writes `backup`), closing the 5a deferral so canonical-vs-backup is unambiguous and exactly one drive reads "Canonical". The snapshot is rebuildable, never a source of truth, never merged. **No catalog migration.** Spec: `docs/superpowers/specs/2026-06-10-phase3-slice5b-catalog-snapshot-adoption-design.md`. Remaining: **5c** (canonical management & migration — designate/change the canonical, agreement-gated promotion, demote the old), then merge `phase3-drives` → `main`.

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

1. **Browse** ✅ — Core foundation (vault/manifest/hash/catalog/scanner), timeline, folder tree, viewer, inspector, local bin. *Includes the ImageCaptureCore deletion spike to de-risk phase 2.*
2. **Import** ✅ — iPhone/SD grid, verify-then-delete, dedup-on-import. *Plus the out-of-band Library Selection / Evict / Send-to-device / Locations feature (see changelog).*
3. **Drives** ⬅ in progress — canonical sync (**Slice 1 ✅**: additive Mac→canonical sync spine), evict/rehydrate, clone/migrate, drift review, integrity verify, delete propagation, catalog snapshot. *Decomposed into slices; see the 2026-06-09 changelog entry and `docs/superpowers/specs/2026-06-09-phase3-drives-design.md`.*
4. **Intelligence** — pipeline, People view, unified search, Map, OCR.
5. **Extras** — LLM query parsing, perceptual near-duplicate detection, CLI tool, sidecar layout export.

### Phase 5 backlog (added 2026-06-09, from usage feedback)

- **Video-only filter** — a quick filter in the timeline (and folder view) to show only videos. Small Browse-layer addition; complements the existing photo/video split already tracked per asset (`MediaKind`).
- **macOS Finder tag interoperability** — make OpenPhoto's tags correspond to macOS Finder tags, not only the XMP tags it uses today. Two directions: **read** tags a user added in Finder, and **write** OpenPhoto tags so they're readable in Finder. *Technical note for whoever designs this:* OpenPhoto currently stores tags as XMP `dc:subject` in sidecars. Finder tags are a different mechanism — they live in the extended attribute `com.apple.metadata:_kMDItemUserTags` (surfaced via Spotlight's `kMDItemUserTags`), not in XMP. So this needs a design decision: bridge/sync the two, or treat Finder tags as a first-class source. Watch the sovereignty invariant — Finder tags are an OS-managed xattr, so syncing them to/from the XMP sidecars (which remain the portable record) is the likely approach.
- **Tag search in timeline & folder views** — search/filter assets by tag in both browse surfaces. *Overlap note:* this is closely related to Phase 4's unified search (Intelligence) — a basic tag-only search could land in **Phase 4** alongside search rather than waiting for Phase 5; worth deciding when Phase 4 is planned.
- **Map in the Library sidebar** — a **Map** entry in the left navbar's Library group (alongside Timeline / Folders / Drives / Bin) that plots geotagged photos. *Overlap note:* a Map view is already slated for **Phase 4 (Intelligence)** as part of the pipeline/search work — this records it as a concrete sidebar surface under Library; reconcile the two when Phase 4 is planned (it may simply be the Phase 4 Map, confirmed to live under Library).
- **Unify photo-tile corner shape across surfaces** (surfaced 2026-06-09, from usage feedback) — the import-screen grid uses **rounded** thumbnail tiles while the timeline (and folder) grid uses **sharp** corners; the sharp corners read as inconsistent and, worse, when a photo is selected the square photo corners **poke out past the rounded selection ring**, looking broken. Unify on the rounded tile shape everywhere (timeline, folders, import), and ensure the thumbnail is clipped to the same corner radius as — or slightly inside — the selection ring so no corner protrudes. Browse/Selection-layer styling change (`ThumbView`/`PhotoCellView` + `selectionChrome` corner radii); no data or format impact.
- **Drive/presence indicator on photo tiles — timing + clipping** (surfaced 2026-06-09, from usage feedback) — the per-tile presence badge (the "on drive" / drive-only / backed-up glyph in `PhotoCellView`) appears to (a) **get clipped at the tile edge** — it's drawn past the thumbnail's clip bounds, so part of the glyph is cut off (likely the same corner-clipping issue as the tile-shape item above — fix together), and (b) possibly **not show at the right time** — verify the badge's appearance is driven by *honest* presence (it should reflect actual drive-only vs backed-up-on-canonical vs local-only state, refreshed on the same signals as the Drives badges). Audit when the glyph is shown vs the asset's true presence, and inset it within the rounded tile so it's never clipped. Browse-layer fix; no data/format impact.
- **Apple Photos library as an import source** (surfaced 2026-06-09, from usage feedback) — let users import originals from the Mac's **Apple Photos** library (the managed `.photoslibrary` bundle), alongside the existing phone/SD/folder sources. *Technical note for whoever designs this:* the Photos library is an opaque managed bundle — do **not** read its internals directly; use **PhotoKit** (`PHPhotoLibrary` authorization → `PHAsset` enumeration → `PHAssetResourceManager`/`requestImageDataAndOrientation` to pull the **original** file bytes + capture date/location). This is a new `ImportSource` implementation feeding the same import pipeline (copy → hash → dedup → place → manifest/catalog). Honors sovereignty: OpenPhoto copies *out* into plain files; it never writes back into the Photos library. Dedup-on-import (existing hash logic) prevents re-importing the same shots. Consider Live Photos (PhotoKit exposes both resources) and edited-vs-original (import the original, optionally the rendered edit).
- **Preserve folder organization when sending photos back to a phone** (surfaced 2026-06-09, from usage feedback) — when sending Mac/drive photos to an iPhone, OpenPhoto's **nested folder** structure is lost (they land in the camera roll). The user wants the organization to survive. *Hard constraint to research:* iOS Photos has **flat albums** (no nested folders, though "folders of albums" exist in the Photos app's own model), and **AirDrop cannot create or assign albums** — received photos go straight to Recents with no album. So true folder preservation over AirDrop is likely **not possible** as-is. Possible approaches to evaluate: (a) **flatten** a nested folder path into a single album name (e.g. `2022 › rome2022` → an album "2022/rome2022") — but album creation still can't be driven from the Mac side over AirDrop; (b) a small **companion iOS Shortcut/app** that watches for incoming OpenPhoto sends and files them into albums by an embedded hint; (c) embed a folder hint in metadata (e.g. a keyword/`dc:subject`) so a later on-device pass can sort. Record as **uncertain/research** — confirm the platform limits before committing; it may only be achievable with a companion app.
- **Open-only `Vault` accessor for read-only drive queries** (surfaced 2026-06-10, Slice 4.5 code review) — every drive-read path on `AppState` (`openVault(for:)`, used by `fullResURL`, `evict`, `rehydrate`, `deleteDriveOnly`, and now `sendPlan`) calls `Vault.openOrCreate(at:role:.canonical)`, which **writes a fresh `vault.json` (with a new random vaultID)** when the present drive lacks one. For a properly adopted drive this never fires (the file exists → it just reads), and even in the anomalous wiped-`vault.json` case the new ID won't match `item.vaultID` so the asset safely falls through to unreachable/unavailable — but a *read-only* "what can I send / show?" query should never mutate a passive drive. Add a pure `Vault.open(at:)` (open-only; throws/returns nil if no `vault.json`) and switch the read-only callers (`openVault(for:)` and especially `sendPlan`/`fullResURL`, which run on sheet-open / viewer-load) to it, leaving `openOrCreate` only for genuine adoption. Small `OpenPhotoCore` + `AppState` change with its own tests; no format impact (it *reduces* incidental drive writes). Aligns with the "drives are passive" invariant.
- **Choose among multiple connected devices when sending** (surfaced 2026-06-10, from usage feedback) — the Send action targets a **single** device: `AppState.connectedSendTarget()` returns the *first* connected device that can receive (cameras/AirDrop preferred), and the toolbar/selection Send button is wired to just that one. When several receivers are connected (e.g. two iPhones, or a phone + an SD card/volume), the user can't pick which to send to. Add a **device picker** at send time (a menu/sheet listing all connected send targets — phones via AirDrop, volumes via copy — by friendly name), defaulting to the current auto-pick. `SendSheet` already takes an explicit `device`, so the change is mostly in the entry points (`connectedSendTarget()` → "list connected targets" + a chooser) — no change to `SendEngine`/destinations. Browse/Send-UI addition; no data/format impact.
- **`ISO8601Millis.dateLenient` rejects the app's own fractional-second timestamps** (surfaced 2026-06-10, Slice 5b code review) — `ISO8601Millis.string(from:)` writes timestamps **with** fractional seconds (`.withFractionalSeconds`), but `dateLenient(from:)` uses a formatter configured **without** them, so re-parsing the app's own `manifest.jsonl` `mtime` (or any value it wrote) returns `nil`. Consequence today: `CatalogSnapshot.verifyAdoption`'s minimal-asset `takenAtMs` always falls back to `0` (those stale-snapshot edge assets sort to the bottom of the timeline until a rescan regenerates real metadata) — benign and spec-accepted, but the "lenient" name is misleading and any other caller mis-parses too. One-line fix: make `dateLenient` try the fractional formatter first, then the non-fractional (`date(from:) ?? lenient.date(from:)`), so it accepts both — strictly more lenient, can't break existing parses. Core util change with its own test; no data/format impact.

## 11. Known risks & spikes

- **iPhone deletion over USB**: ~~iOS restricts ImageCaptureCore deletion when iCloud Photos is enabled~~ **RESOLVED by spike (2026-06-08, see `docs/spikes/2026-06-08-icc-deletion.md`)**: deletion via `requestDeleteFiles` SUCCEEDED with iCloud Photos ON on Jude's device. Phase 2 may offer "Delete from iPhone" after verified import, with per-item failure surfacing as a fallback for other configurations. The locked-phone state (error −9943) must be handled by waiting for `cameraDeviceDidRemoveAccessRestriction` and retrying; device item order is not chronological — sort by `creationDate`.
- **MobileCLIP model selection/conversion**: verify a Core ML build with acceptable quality and a usable text encoder before phase 4.
- **Offline reverse-geocode dataset**: choose one (~tens of MB, city-level is sufficient) before phase 4.
- **HEIC/Live Photo edge cases**: pairing relies on Apple's content identifier; some third-party apps strip it. Fallback heuristic: same basename + adjacent timestamps.
