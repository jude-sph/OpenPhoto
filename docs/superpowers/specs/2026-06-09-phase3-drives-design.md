# Phase 3 — Drives & Sync: Design Spec

**Status:** Approved (2026-06-09). Umbrella design for Phase 3 plus a buildable spec for **Slice 1 (the sync spine)**. Later slices are sketched here and each gets its own spec → plan → build cycle.

**Audience:** OpenPhoto developers. The on-disk format this builds on is normative in `docs/format/vault-format-v1.md`; this spec must not contradict it, and any new on-disk structure introduced by a slice updates that document in the same commit (sovereignty discipline, `CLAUDE.md`).

---

## 1. What Phase 3 is

Phase 3 extends "the library is just files" from the Mac to **external drives**. A drive carries a complete, self-describing OpenPhoto vault, so a canonical drive is a full library that any conforming reader (including future server software) can interpret with no other information. The Mac becomes a *working subset + full catalog of everything*; the canonical drive holds *everything*.

The phase delivers, in dependency order: one-way sync (Mac → canonical), drift/integrity detection, reviewed deletion propagation, evict/rehydrate (with optional direct send-from-drive to a phone), and clone/migration to backups and fresh Macs. Throughout, the Mac's library view becomes a **single unified library** spanning every location, with per-photo presence shown and filterable.

## 2. Hard invariants (Phase 3 restatement of `CLAUDE.md`)

1. Originals are never modified or moved without explicit user action. On a drive, "new content = new file"; existing media files are never overwritten.
2. Human-authored metadata → XMP sidecars; machine-derived data → rebuildable catalog.
3. Nothing hard-deletes. On a drive, deletion moves files into `.openphoto-trash/` at the volume root (format §8 spirit).
4. **All writes atomic (temp → fsync → rename); all copies hash-verified.** A copy is "done" only after its bytes re-hash to the source hash on the destination.
5. **Sync is strictly one-way; drives are passive; there is no merge logic.** Human gates exist in exactly three places: import selection, delete propagation, drift review.

## 3. Testing substrate (cross-cutting, built in Slice 1)

Real external hardware is not required to develop or CI Phase 3. Three tiers, each catching what the one below cannot:

1. **Temp-dir folders (CI, fast).** The sync engine is path-driven, so a folder is a faithful stand-in for *all* sync logic: reconcile, plan, copy-verify, idempotency, kill-mid-copy resume, drift injection. This is the design's existing testing posture (master spec §9). All media is generated mock files; never any real user folder.
2. **Local exFAT disk image (scriptable, CI-able, no hardware).** `hdiutil create -fs ExFAT -size <N>m …` then attach. This is a *real* removable-volume experience without hardware: it mounts under `/Volumes` and **fires real mount/unmount notifications**, it is a **real exFAT filesystem** (catches case-folding, missing xattrs/symlinks/perms, 2-second mtime granularity, illegal filename chars), it is **fixed-size** (catches `ENOSPC`), and **detaching it mid-write simulates a yank**.
3. **Real hardware smoke (manual, thin checklist).** A real SD card + an external SSD for the handful of things only physics exercises (the eject button, USB-hub quirks, a large library). Same pattern as the Phase 2 AirDrop/ICC hardware smokes.

**Enabler — the drive abstraction.** A small interface makes folder, dmg, and real volume interchangeable to the engine (mirrors Phase 2's `SendDestination`):

```
protocol DriveVolume {
    var rootURL: URL { get }          // mount point / folder root
    var isMounted: Bool { get }
    func freeSpaceBytes() throws -> Int64
    func eject() throws               // no-op for a folder
}
```

- `RealVolume` — backed by a security-scoped bookmark; used for real drives *and* the exFAT dmg in tests (it genuinely mounts).
- `FolderVolume` — a plain directory; `eject()` is a no-op; `freeSpaceBytes()` reports the containing filesystem. Used for temp-dir CI and the optional dev "scratch drive."

**Dev scratch drive.** For interactive hand-testing, point the app at a **repo-local, gitignored** folder (e.g. `./.scratch/fake-canonical/`) — *not* `~/Documents/tests/` or anywhere near real data — so it is obviously throwaway and honours the "generated fixtures only" rule. For real-volume realism, point it at an attached exFAT dmg instead.

## 4. Phase 3 roadmap (slices)

Each slice ends with working, testable software. Nothing destructive ships until the non-destructive spine and drift detection are trusted.

1. **Sync spine — Mac → canonical, additive only** *(detailed in §7)*. Adopt a drive, reconcile, preview a plan, apply (copy new originals + sidecar updates, hash-verified, resumable, logged). Begins recording per-drive presence → backup badges. Builds the drive abstraction + exFAT-dmg harness everything else reuses.
2. **Drift & integrity.** Fast reconcile on connect surfaces outside changes to a drive as a **drift review** (repair options, never auto-resolution). On-demand **Verify Integrity** re-hashes a vault against its manifest (bit-rot).
3. **Deletion propagation.** A review screen lists deletions in the catalog since last sync; on confirmation, drive copies move to the drive's `.openphoto-trash/`. `origin:"propagated"` per format §8.
4. **Evict / rehydrate.** Per-folder evict releases local originals (to macOS Trash) only after every item is hash-verified on canonical; rehydrate copies a folder back, verified the same way. **Optional companion — send-from-drive** (§6): send an evicted photo straight from the drive to a phone (drive → phone) without rehydrating, and rehydrate (drive → Mac).
5. **Clone & migration.** Clone canonical → backup with both plugged in (manifest-driven, hash-verified; any number of backups). Migration = clone + flag-flip to designate a new canonical. Adopt-on-fresh-Mac imports the drive's catalog snapshot as the starting live catalog, then verifies against the manifest. This slice introduces **writing the catalog snapshot** at sync end (format §7).

## 5. Unified browsing & presence (cross-cutting; fills in across slices)

The Mac shows **one unified library** — every asset the catalog knows about, regardless of which disk holds the bytes — extending the Phase 2 `PresenceService`/Locations model (drives appear as additional *places*).

- **Always browsable, even unplugged.** Thumbnails and metadata live in the Mac catalog and persist from import time, so an evicted or drive-resident photo still appears in the timeline and folders, searchable, with EXIF readable, while the drive is in a drawer. "Skeleton" means **thumbnail-only** (full-res absent), never blank. (No catalog snapshot is needed for *this* Mac to browse — thumbnails already exist locally from import; the snapshot in Slice 5 is only so a *fresh* Mac gets them.)
- **Presence badges (always on).** Each non-local asset wears a small drive glyph; the inspector's Locations panel carries the per-photo detail (This Mac / Canonical / Backup …, and whether full-res is reachable right now). The minimal "backed up on canonical" badge ships in Slice 1.
- **Sources filter.** A compact **"Sources ▾"** popover lists every place the library lives — **This Mac** + one row per known drive (name, item count, an "available now" dot). **Union (OR) semantics:** show every asset present in *any* ticked source, deduped by identity; all ticked by default = the whole library. Unplugged drives still appear (browse their thumbnails), marked not-available-now. This subsumes a simple "on this Mac only" toggle (= only *This Mac* ticked). It is a **browsing convenience only** — it deliberately does not express set-difference questions like "not backed up anywhere"; that safety figure is the headline number on the sync screen.
- **Sequencing.** The badge ships in Slice 1 (every asset is still local then, so nothing is hidden — the badge answers *is this also safe on the drive*). Drive-only / thumbnail-only browsing and the Sources filter earn their keep once **eviction** (Slice 4) or **fresh-Mac adoption** (Slice 5) first make a photo not-local.

## 6. Send-from-drive (optional; companion to Slice 4)

Marked **nice-to-have**, not vital. Hard constraint from the Phase 2 spikes: **the Mac is unavoidably the AirDrop sender** — USB push to an iPhone is impossible (ImageCaptureCore is read+delete only), the phone can't run OpenPhoto, and a drive is passive. So "direct" cannot mean Mac-less; it means **no permanent intermediate copy**.

Today, sending an evicted photo to a phone would require rehydrating a full copy into the Mac library first. Instead, the existing Phase 2 Send becomes **presence-aware** and resolves each asset's best source:

- on the Mac already → send from the Mac (fast, no drive needed);
- evicted, canonical drive plugged in → AirDrop **straight from the drive path** (no rehydrate, nothing new lands in the library);
- neither → "plug in the canonical drive to send these."

This reuses everything: `sends.jsonl` keys by `(destination_key, hash)` regardless of byte source, AirDrop verification (ICC re-enumeration by size+date) is unchanged, and presence tracking is unaffected. It has teeth only after eviction exists, hence its home in Slice 4.

A raw, un-imported card → phone passthrough is **out of scope** (it would be untracked, against the model). If wanted, it becomes an explicit **import-then-send**.

---

## 7. Slice 1 — Sync spine (Mac → canonical, additive) — DETAILED

### 7.1 Scope

**In:** adopt/designate a canonical drive; reconcile the Mac's local vaults against the drive; preview a sync **plan**; apply it — copy **new originals** and **add/update XMP sidecars**, each hash-verified and atomic; update the drive manifest; append `sync` events; record per-drive presence in the catalog; show a "backed up on canonical" badge.

**Out (deferred):** rename detection, deletion propagation, drift repair (Slice 2/3); evict/rehydrate and send-from-drive (Slice 4); clone, migration, multiple/backup drives, and **writing the catalog snapshot** (Slice 5); the Sources filter and drive-only browsing (arrive with eviction). Slice 1 assumes a drive written only by OpenPhoto; outside-added/changed files are left untouched and unlisted (handled as drift in Slice 2).

**Safety property:** additive sync performs **no irreversible move on the drive** and **never overwrites an existing media file**, so Slice 1 cannot lose data on the drive.

### 7.2 Drive identity & adoption

Identity is the `vault_id` UUID inside `<drive>/.openphoto/vault.json` (format §3) — it travels with the files, so a folder, a dmg, and a real volume are identified identically. The OS locator (volume UUID + security-scoped bookmark) is only a hint for re-finding the same vault on reconnect.

**Add Drive** (folder/volume picker — yields the security-scoped bookmark, works identically for folder/dmg/volume):

- If the chosen location has `.openphoto/vault.json` → read it; refuse `format_version` newer than supported.
- If it has none → **initialize** a canonical vault: write `vault.json` (`{format_version:1, vault_id:<new UUID>, role:"canonical", created_at, app}`) and an empty `manifest.jsonl`, both atomically.
- Record the vault in the catalog `vaults` table with its locator. **Slice 1 supports exactly one canonical drive**; designating backups is Slice 5.

### 7.3 Source ↔ destination layout

The Mac's local vaults (default `~/Pictures`, `~/Movies` — arbitrary roots) each map to a **top-level directory on the drive named by the source root's basename** (`Pictures/`, `Movies/`), per format §1. A Mac asset at local path `P` within source vault `V` maps to drive-relative path `<basename(V)>/P`, with `/` separators and NFC normalization (format §4).

Slice 1 requires the source roots to have **distinct basenames** (true for the default layout). Basename collisions are an **open question** (§7.10) — handled later by an explicit root-mapping field in `vault.json` (documented when introduced).

### 7.4 Reconcile + plan (M1, zero writes)

Reconcile compares the **source assets** (from the Mac catalog/manifests of the local vaults) against the **drive's actual state**. For each source asset with mirrored destination path `D` and source hash `H`:

- **D missing on the drive** → **copy** (a new original).
- **D exists, hash == H** → **already present** → skip (records presence).
- **D exists, hash != H** → **conflict** → skip + report (deferred to Slice 2 drift; never overwritten in Slice 1).

Sidecars: for each source XMP sidecar, if the mirrored sidecar is **missing or byte-different** on the drive → **sidecar update** (sidecars are not originals; overwriting an older sidecar is permitted by format §10.1). 

```
struct SyncPlan {
    var copies: [PlanItem]          // new originals: hash, sourceURL, destRelPath, size
    var sidecarUpdates: [PlanItem]  // XMP to write/replace
    var conflicts: [PlanItem]       // path exists with a different hash (reported, not acted on)
    var totalCopyBytes: Int64
}
```

**M1 deliverable:** compute and render the plan (N new photos · total bytes, M sidecar updates, any conflicts) with a **free-space check** (`totalCopyBytes` vs `volume.freeSpaceBytes()`; block with a clear message if insufficient) and **Sync / Cancel**. **Nothing is written.** This is independently shippable as a "show me what would sync" dry run.

### 7.5 Apply (M2)

On confirm, execute the plan with progress. Per item, idempotent and crash-safe:

1. **Pre-check (resume):** if `destRelPath` already exists, hash it. If it equals `H`, the item is already done → ensure it's in the manifest set, skip the copy. If it differs → conflict (skip, report). This makes a re-run after a yank resume cleanly.
2. **Copy:** stream source → a temp file **on the same drive filesystem** → `fsync` → `rename` to `destRelPath` (atomic, invariant 4).
3. **Verify:** re-hash the destination file; if it ≠ `H`, remove it and record the item **failed** (never recorded as present). Only a byte-verified copy counts as done.
4. Sidecar updates use the same atomic temp→fsync→rename (no hash gate; XMP is human-authored text, content compared for change).

**Manifest:** after the copy pass, rewrite `<drive>/.openphoto/manifest.jsonl` **atomically** as (surviving prior entries whose files still exist) + (newly verified copies), sorted deterministically. The manifest is advisory per format §10.7 — an interrupted run leaves real, verified files on the drive and a possibly-stale manifest; the next reconcile re-derives truth from the filesystem (step 1) and rewrites a correct manifest. (Slice 1 does not hash outside-added drive files; those become drift in Slice 2.)

**Sync log:** append one `sync` event (format §9) to **both** the drive vault's `sync-log.jsonl` (`counterparty_vault_id` = the Mac primary vault's id) and the Mac primary vault's `sync-log.jsonl` (`counterparty_vault_id` = the drive's `vault_id`), with a `summary` of copied count + bytes.

```
struct SyncResult { var copied: Int; var sidecarsWritten: Int; var skipped: Int; var conflicts: Int; var failed: [PlanItem] }
```

### 7.6 Catalog additions (rebuildable; reflected in `catalog-schema.md` when stable)

- `vaults`: `vault_id` (PK), `role`, `display_name`, `locator_bookmark`, `volume_uuid`, `last_seen_at`. `present` is runtime (is it mounted now), not persisted as truth.
- `vault_presence`: `(vault_id, hash)` — an asset hash known present in that vault. Populated for the drive from its manifest at adopt/sync; the Mac's own vaults populate it from their manifests. This is the data behind badges, the Sources filter (later), and the "only on this Mac / not backed up" figure.

No new **on-disk format** structures: Slice 1 writes only existing `vault.json`, `manifest.jsonl`, and `sync-log.jsonl`. (Format-doc impact for Slice 1: confirm no change needed; the discipline gate is satisfied by this spec citing the existing sections.)

### 7.7 UI (M3)

- **Drives** entry in the sidebar (the master spec's "Devices-when-connected" area): shows the canonical drive with mounted/unmounted state and free space; **Add Drive** action.
- **Sync plan review** sheet (§7.4) → progress → result summary (copied / skipped / conflicts / failures). Cancel is safe at any time (resumable).
- **"Backed up on canonical" badge** on timeline/folder cells, driven by `vault_presence`. (The Sources filter and drive-only browsing are deferred per §5.)

### 7.8 Testing (TDD, Swift Testing)

- **Tier-1 scenario tests** on temp-dir vaults (generated mock media; `FolderVolume`): plan correctness (copy/skip/conflict classification, sidecar diff), free-space block, apply copy+verify, **idempotency** (double-run is a no-op), **resume** (kill mid-copy → re-run completes), verify-mismatch → failed + cleaned up, manifest rewrite correctness, sync-log emission, presence recorded. A `FailingVolume`/fault-injection helper simulates verify mismatch and ENOSPC.
- **Tier-2 exFAT dmg test(s):** a real attached exFAT image exercises mount detection, exFAT filename/mtime quirks, real `ENOSPC` on a small image, and detach-mid-write resume. Kept thin.
- **Tier-3 hardware smoke checklist** (manual): real SD card + external SSD; adopt, sync, eject, reconnect-and-resync (no-op).

### 7.9 Milestones

- **M0 — substrate:** `DriveVolume` (`RealVolume`, `FolderVolume`) + the exFAT-dmg test harness.
- **M1 — dry run (zero writes):** Add Drive (read/init `vault.json`) → reconcile → `SyncPlan` → plan-review UI with free-space check. Independently shippable.
- **M2 — apply:** atomic verified copy + sidecar write, idempotent/resumable, manifest rewrite, `sync` log events.
- **M3 — wiring:** catalog `vaults` + `vault_presence`, Drives sidebar entry, "backed up on canonical" badge.

### 7.10 Open questions / risks

- **Source-root basename collisions** (two Mac roots with the same basename) — deferred; resolve with an explicit root-mapping field in drive `vault.json` (format-doc update at that time).
- **Security-scoped bookmark staleness** across reboots/relocations — re-prompt to relocate the drive when a bookmark fails to resolve.
- **Large-library plan/reconcile cost** — reconcile uses the manifest `size`+`mtime` fast-path (format §4) before hashing; full hashing only on copy/verify.

## 8. Out of scope for Phase 3

Server/cloud software (a separate future product that reads a canonical drive via the format spec); any two-way/merge sync; editing originals; networked sync between Macs.
