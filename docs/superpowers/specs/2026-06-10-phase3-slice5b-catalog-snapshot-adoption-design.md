# Phase 3 Slice 5b — Catalog Snapshot + Confirmed Fresh-Mac Adoption (design)

**Date:** 2026-06-10
**Branch:** `phase3-drives`
**Status:** Approved
**Builds on:** Slice 1 (`SyncEngine.apply`, `Manifest`, `ThumbnailStore`), Slice 2 (`DriftReconciler`), Slice 2.5 (`vault_presence`, `CatalogIngest`, drive-only browse), Slice 5a (clone, durable backups, `durableVaults`/`canonicalVault`, `cloneToBackup`, `DrivePathMap`).

> **Slice 5 is three sub-slices:** 5a (clone + backups + durable deletion) ✅; **5b (this) — catalog snapshot + confirmed adoption**; 5c — canonical management & migration (designate/change the canonical, agreement-gated promotion, demote old). The "change which drive is canonical" mechanism is **5c**; 5b only needs to *identify* a drive's role (writing it into `vault.json`) and adopt a drive on a Mac that doesn't know it.

---

## 1. Goal

Let any Mac pick up the library **instantly** from a drive — no full re-scan / re-hash / re-thumbnail. The drive carries a **disposable copy of the machine-derived index** (catalog + thumbnails), refreshed each sync/clone. Plugging that drive into a Mac that doesn't know it offers a **confirmed** "adopt" that imports the index for immediate browsing, then verifies against the authoritative manifest in the background.

This is the payoff of "the library is just files": you're never locked to one machine.

### Three parts

1. **Write** the snapshot to `<drive>/.openphoto/catalog-snapshot/` after each sync and clone (atomic).
2. **Document** the snapshot format (§7) and the catalog schema (`docs/format/catalog-schema.md`) for third parties.
3. **Read / adopt** — a *confirmed* prompt on adding an unknown cataloged drive: import → instant drive-only browse → background verify vs manifest.

Plus the small enabler: **write a drive's role into its `vault.json`** (the deferred-from-5a flip) so adoption — and the "which drive is canonical" UI — can tell canonical from backup.

### Non-goals (explicit)

- **Changing which drive is the canonical / promoting a backup / migration** → Slice 5c. 5b only *sets* the canonical when a Mac has none yet (on first adoption) and *labels* the existing role.
- **Re-running ML / regenerating intelligence on adoption** — the whole point is to avoid it; the snapshot carries it.
- **Merging two catalogs.** The snapshot is never a source of truth and is never merged back; it is regenerated wholesale. On adoption the live catalog is seeded, never reconciled-by-merge.

---

## 2. Hard invariants honored

| Invariant | How |
|---|---|
| Machine-derived data is rebuildable, never authoritative | The snapshot is a **disposable accelerator**; the manifest (inventory) + files (bytes) + sidecars (human metadata) are the truth and win on any disagreement. |
| Originals never touched | The snapshot lives only under `.openphoto/`; adoption reads the drive, never writes originals. |
| Atomic writes | The snapshot dir is assembled in `catalog-snapshot.tmp/` then atomically swapped in (`replaceItemAt`), so a reader never sees a half-written snapshot. |
| Drives passive, one-way | Writing the snapshot is the Mac pushing onto the drive at sync/clone end (an explicit user action); adoption is read-only on the drive. No merge, no back-flow. |
| Sovereignty / documentation | The new on-disk artifact is documented normatively in `docs/format/` (§7 + `catalog-schema.md`) **before** it is written. |

---

## 3. Components

### 3.1 Snapshot layout (new on-disk artifact — format §7)

```
<drive-root>/.openphoto/catalog-snapshot/
  catalog.sqlite          ← clean VACUUM INTO copy of the Mac's catalog
  thumbs/<hh>/<hash>.jpg   ← content-addressed thumbnails, ONLY for this drive's hashes
  snapshot.json           ← {format_version, catalog_schema_version, source_vault_id,
                              written_at, asset_count}
```

- **`catalog.sqlite`** is produced with SQLite **`VACUUM INTO`** — a consistent single-file copy, no WAL sidecars, without locking or mutating the live DB. It contains the *whole* catalog; the reader selects only the portable parts (§3.2).
- **`thumbs/`** mirrors the live cache's content-addressed layout (`<hex[0..2]>/<hex>.jpg`), copying only the hashes present in this drive's `manifest.jsonl` — right-sized to the drive, never bloated with other drives' thumbnails.
- **`snapshot.json`** lets a reader reject an unknown future `format_version`/`catalog_schema_version` and fall back to a re-scan.

### 3.2 `CatalogSnapshot.write` (Core)

```swift
public enum CatalogSnapshot {
    /// Write <drive>/.openphoto/catalog-snapshot/ atomically: VACUUM the live catalog into a clean
    /// copy, copy thumbnails for the drive's manifest hashes, write snapshot.json, then swap the
    /// assembled temp dir over the old snapshot. Disposable: regenerated wholesale each call.
    public static func write(catalogDBPath: URL, thumbnails: ThumbnailStore,
                             drive: Vault) throws
}
```

Steps: read the drive's manifest → the set of hashes it holds; assemble `catalog-snapshot.tmp/` (VACUUM the live DB → `tmp/catalog.sqlite`; for each hash copy `thumbnails.cacheURL(for:)` → `tmp/thumbs/<hh>/<hash>.jpg` if it exists; write `snapshot.json`); `fsync`; `FileManager.replaceItemAt(catalog-snapshot, withItemAt: tmp)` (or move if absent). Called by the App after sync and after clone (§3.6) — "refreshed last, after verification."

### 3.3 Catalog schema doc + portability key (format `catalog-schema.md`)

Documents every catalog table (`vaults`, `assets`, `instances`, `vault_presence`, `pending_deletions`) with columns, and a **portability key** for snapshot readers:

| Table | Portable for a reader? |
|---|---|
| `assets` (hash-keyed machine metadata + sidecar mirrors) | **Yes** — but human columns (`favorite`/`rating`/`caption`/`tagsJSON`) are *mirrors of sidecars*; the drive's sidecars are authoritative and win on ingest. |
| `vault_presence` *for this drive's `vaultID`* | **Yes** — describes what this drive holds. |
| `vaults` | **No** — `rootPath`/`lastSeenMs` are the source Mac's; a reader MUST ignore them. |
| `instances` | **No** — the source Mac's local-vault rows. |
| `vault_presence` for *other* `vaultID`s | **No** — other drives the source Mac knows. |
| `pending_deletions` | **No** — the source Mac's delete queue. |

The doc states plainly: **the snapshot is a disposable accelerator; the `manifest.jsonl` is authoritative for what's on the drive.**

### 3.4 `CatalogSnapshot.import` (Core)

```swift
public struct AdoptionImport: Sendable, Equatable { public var assets: Int; public var present: Int }

extension CatalogSnapshot {
    /// Seed the live catalog from a drive's snapshot for instant drive-only browse: insert assets
    /// that aren't already known (never clobbering local human metadata), replace THIS drive's
    /// vault_presence from the snapshot, and copy the snapshot's thumbnails into the live cache.
    /// Reads only the portable parts (§3.2). Returns counts. Does NOT verify — that's `verifyAdoption`.
    public static func `import`(from drive: Vault, into catalog: Catalog,
                                thumbnails: ThumbnailStore) throws -> AdoptionImport
}
```

- Opens `catalog-snapshot/catalog.sqlite` **read-only**; reads `assets` and the snapshot's `vault_presence` rows whose `vaultID == drive.descriptor.vaultID`.
- **Assets:** `INSERT … ON CONFLICT(hash) DO NOTHING` — adds unknown assets, never overwrites an asset the live Mac already has (so a Mac with its own library keeps its authoritative human metadata).
- **Presence:** `replaceVaultPresence(vaultID: drive.id, entries:)` from the snapshot rows → the photos appear as drive-only.
- **Thumbnails:** copy `catalog-snapshot/thumbs/**` into the live cache (skip ones already present).
- Result: the drive's photos browse immediately (thumbnails + dates/metadata from the snapshot; full-res pulled from the drive on open via the Slice-5a `driveSource` resolution).

### 3.5 `CatalogSnapshot.verifyAdoption` (Core) — manifest wins

```swift
extension CatalogSnapshot {
    /// Reconcile an adopted drive's presence against its authoritative manifest (the snapshot may be
    /// stale): drop presence rows whose hash isn't in the manifest; ensure a presence row exists for
    /// every manifest entry (deriving relPath via DrivePathMap, with a minimal asset if the snapshot
    /// lacked it). Background; the manifest is the source of truth.
    public static func verifyAdoption(drive: Vault, into catalog: Catalog,
                                      sourceBasenames: [String]) throws
}
```

Runs after import, off the main thread. For a stale snapshot: a hash the snapshot listed but the manifest doesn't → its presence is dropped; a manifest hash the snapshot lacked → a presence row is created (path from the manifest; mac-relative via `DrivePathMap.driveToMacRelPath`) and a **minimal** asset inserted (kind/size from the manifest; full metadata + thumbnail regenerate on demand when the file is opened). Reuses the existing drive-ingest building blocks where possible.

### 3.6 App integration

- **Write hook:** after a successful sync (`SyncPlanSheet`/the sync path) and after `cloneToBackup`, call `CatalogSnapshot.write(...)` for the destination drive (last, after verification). Off-main; failure is non-fatal (logged) — a missing snapshot just means the *next* Mac re-scans.
- **Confirmed adoption (no silent canonical):** when a drive is added/connected, if it has a `catalog-snapshot/` **and** the live catalog has no `vault_presence` for it (contents unknown), surface a **prompt** — *"'<drive>' carries a photo library (N photos). Adopt it so you can browse it here?"* — with **Adopt** / **Not now**. Nothing imports until the user confirms. On **Adopt**: register the drive (role read from its `vault.json`), run `import` (instant browse), then `verifyAdoption` in the background. **If this Mac has no canonical yet, the adopted canonical-role drive becomes the canonical** (the only auto-canonical case; *changing* it later is 5c).
- **Role identity:** the Drives panel and `canonicalVault` key off the drive's true role (now written to `vault.json`, §3.7), so exactly one drive reads "Canonical."

### 3.7 `Vault` role-write + clone wiring (the deferred-from-5a flip)

```swift
extension Vault {
    /// Rewrite this vault's vault.json with a new role, preserving vault_id/created_at/format_version.
    /// Returns the updated Vault. Atomic (AtomicFile). Used when a drive becomes a backup (clone) or
    /// the canonical (adoption/migration).
    public func writingRole(_ role: VaultRole) throws -> Vault
}
```

Wire into `AppState.cloneToBackup`: after the catalog role flip, also `try? target.writingRole(.backup)` so the **drive self-describes as a backup on disk** — which is what makes adoption (and any other Mac) identify it correctly. This closes the 5a deferral and the "which drive is canonical" ambiguity (the canonical is the drive whose `vault.json` role is `canonical`; exactly one).

---

## 4. Data flow

**Sync/clone → snapshot:** copy bytes (existing) → rewrite manifest (existing) → **write snapshot** (new, last). **Adopt:** detect snapshot on unknown drive → prompt → confirm → register (role from `vault.json`) → `import` (assets insert-if-absent + this-drive presence + thumbs) → browse drive-only → `verifyAdoption` vs manifest (background, manifest wins). No schema migration (no catalog tables change in 5b; `vault.json` gains no new field — role already exists).

---

## 5. Error handling / edge cases

| Case | Behavior |
|---|---|
| Snapshot half-written | Impossible to read — the atomic `replaceItemAt` swaps the whole dir in one step. |
| Snapshot corrupt / unreadable / unknown `format_version` | Adoption falls back to a full re-scan (the existing safe path); no crash, no bad data. |
| Snapshot disagrees with manifest | `verifyAdoption`: manifest wins (snapshot extras dropped, manifest-only entries added). |
| Adopting on a Mac that already knows the drive | No prompt (it has presence for it) — nothing to adopt. |
| Adopting an asset the Mac already has | `INSERT … DO NOTHING` — keeps the Mac's authoritative human metadata; the drive's sidecars are ingested as usual. |
| Snapshot-write fails (disk full / unplugged mid-write) | Non-fatal: logged; the old snapshot (if any) stays intact (atomic swap never half-applied); next sync retries. |
| A drive's `vault.json` role can't be rewritten | `cloneToBackup` still flips the catalog role (single-Mac behavior unaffected); the on-disk flip retries next clone/update. |

---

## 6. Testing

**Core (unit, temp vaults + generated media — never `~/Pictures`):**
1. `write` produces `catalog-snapshot/{catalog.sqlite, thumbs/<hh>/<hash>.jpg, snapshot.json}`; thumbs only for the drive's manifest hashes; `catalog.sqlite` is a readable, valid copy; re-running replaces it atomically.
2. `import` into a *fresh empty* catalog seeds `assets` + this-drive `vault_presence` + thumbnails; the items then appear in `timelineItems()` as drive-only (`driveRelPath != nil`).
3. `import` does **not** overwrite an existing asset's human metadata (insert-if-absent); a non-this-drive presence row in the snapshot is ignored.
4. `verifyAdoption`: a snapshot listing a hash absent from the manifest → that presence dropped; a manifest hash absent from the snapshot → presence created + minimal asset. Manifest wins.
5. `writingRole(.backup)` rewrites `vault.json` (role becomes backup, `vault_id` unchanged); re-opening the vault reads the new role.
6. Round-trip: `write` on a populated drive → `import` into a fresh catalog → the fresh catalog's timeline matches the drive's contents.

**App:** build-verified (0 warnings) + manual — sync/clone leaves a `catalog-snapshot/` on the drive; *forget* a drive then *re-add* it → the **Adopt** prompt appears, confirming it browses instantly from the snapshot; a backup made by clone now reads "Backup" and its `vault.json` says backup.

---

## 7. Task decomposition (for the plan)

1. **Docs (format-first):** flesh out `vault-format-v1.md` §7 (snapshot layout, atomic, disposable, written at sync/clone end) + create `docs/format/catalog-schema.md` (tables + portability key). *Lands before the writer so the on-disk format is documented before it's produced.*
2. **Core — `CatalogSnapshot.write`** (VACUUM INTO + thumbs-by-manifest-hash + `snapshot.json` + atomic dir swap). TDD (test 1).
3. **Core — `CatalogSnapshot.import`** (assets insert-if-absent + this-drive presence + thumb copy). TDD (tests 2, 3).
4. **Core — `CatalogSnapshot.verifyAdoption`** (manifest-wins reconcile). TDD (test 4) + round-trip (test 6).
5. **Core — `Vault.writingRole(_:)`** + wire into `cloneToBackup`. TDD (test 5).
6. **App** — write hook after sync + clone; confirmed-adoption prompt on add (import → background verify); set-canonical-if-none; Drives-panel role labels key off `vault.json` role (one "Canonical"). Build-verified + manual.
7. **Docs** — master-spec changelog entry for 5b.

No catalog migration. The `SyncEngine` copy spine, `VerifiedCopy`, `Manifest`, and send destinations are untouched.
