# Phase 3 Slice 3 — Deletion Propagation: Design Spec

**Status:** Approved (2026-06-09). Detailed design for Phase 3 **Slice 3** — the first *destructive* slice. Part of the roadmap in `docs/superpowers/specs/2026-06-09-phase3-drives-design.md` (order: 1 ✅ · 2 ✅ · 2.5 ✅ · **3 ⬅ deletion-propagation** · 4 evict/rehydrate · 5 clone/migrate).

**One-line goal:** a photo you deleted on the Mac can have its lingering copy on the canonical drive moved into the drive's bin — reviewed, reversible, never hard-deleted.

---

## 1. Why this slice exists

Today **Delete** is Mac-only: `LibraryService.delete` moves the local file + sidecar into the *Mac vault's* `.openphoto/bin/` (`origin: user`) and rescans. The copy on the canonical drive is untouched, so a culled photo keeps living on the drive forever. This slice closes that loop: a reviewed, gated step moves the **drive's** copy into the **drive's** bin (`origin: propagated`), so the drive can be made to match the Mac's library — without ever unlinking a byte.

This is the first slice that removes data from a drive, so the whole design is built around *eligibility precision* (never delete the wrong thing) and *human gating* (one of the spec's three deliberate gates: import, delete-propagation, drift).

## 2. Invariants (honored)

- **Nothing hard-deletes.** Propagation = `move` into `<drive-root>/.openphoto/bin/` (format §8), plus a `bin.jsonl` record and a manifest-line removal. Recoverable.
- **One-way / passive drives.** The Mac decides; the drive is written additively-then-binned by the same third-party-writer rules as sync (§10). No merge, no read-back of drive intent.
- **Atomic writes.** Per-item file moves; a single atomic `manifest.jsonl` rewrite afterward (matches Slice 1's sync).
- **Reversible at every stage.** Local restore before propagation cancels it; the drive bin remains recoverable after.

## 3. The core safety rule (eligibility)

A queued deletion is proposed for a given drive **only when all three hold**:

1. it is in the dedicated **Delete-only queue** (§4), **and**
2. **no local instance** of that hash remains on the Mac (`hash ∉ instances`) — so deleting one of two duplicate copies, or a since-restored photo, never propagates, **and**
3. the hash **is on the drive** (`vault_presence`) — there is actually a copy to bin, and we can resolve its `driveRelPath`.

Eligibility is **computed at review time**, never stored, so it always reflects current reality. This predicate is the heart of the slice; everything else is plumbing.

**Why a dedicated queue and not "read the bin":** today both **Delete** and **Evict** (Stage-A) drop files into the Mac bin tagged `origin: user` — indistinguishable on disk. Inferring deletions from the bin would propose deleting *evicted* photos from the drive, the exact opposite of what evict means. So true Deletes are recorded explicitly at the moment of deletion; Evict records nothing.

## 4. The pending-deletions queue (Catalog migration `v4`)

A new catalog table — rebuildable-cache semantics, consistent with the spec's "pending delete propagations live in the catalog":

```
pending_deletions(hash TEXT PRIMARY KEY, relPath TEXT, deletedAtMs INTEGER)
```

- `hash` — content identity; the join key against `instances` (eligibility rule 2) and `vault_presence` (rule 3).
- `relPath` — Mac-aligned path, for display only.
- `deletedAtMs` — for "deleted 2m ago" and sort order.

If the catalog is ever rebuilt, pending intents are simply forgotten — a **safe failure**: the drive keeps the copy, nothing is lost, the user can re-delete.

Catalog methods: `enqueuePendingDeletion(hash:relPath:deletedAtMs:)` (upsert), `dequeuePendingDeletion(hash:)`, `pendingDeletions() -> [PendingDeletionRecord]`, `clearPendingDeletions(hashes:)`. Plus a small helper `instanceHashes() -> Set<String>` (`SELECT DISTINCT hash FROM instances`) for the eligibility join, and a targeted `removeVaultPresence(vaultID:hashes:)` used after propagation.

**Wiring (Delete-only):**
- `LibraryService.delete()` → after binning, **enqueue** the still **and** its Live-pair video (two rows — mirroring the existing pair-binning).
- `LibraryService.restore()` → **dequeue** the restored hash **and** its Live pair (mirror), so undeleting cancels the pending propagation.
- `LibraryService.evict()` → **enqueue nothing** (the gotcha fix; asserted by a test).
- Successful propagation → `clearPendingDeletions(hashes:)`.

## 5. Propagation (Core: new `DeletionPropagator`)

`Sources/OpenPhotoCore/Sync/DeletionPropagator.swift` — two clean units:

### 5.1 `eligible(...)` — pure, fully testable
```
eligible(queue: [PendingDeletionRecord],
         localHashes: Set<String>,
         presence: [VaultPresenceEntry]) -> [PendingDeletion]
```
Keeps queue entries whose `hash ∉ localHashes` **and** `hash ∈ presence`, resolving each to a `PendingDeletion { hash, relPath, driveRelPath, size, deletedAtMs }` (paths/size taken from the matching `vault_presence` row). No I/O — trivially unit-tested across the whole matrix.

### 5.2 `propagate(drive:entries:catalog:)` — the destructive step
For each confirmed `PendingDeletion`, in order:
1. `BinStore(vault: driveVault).moveToBin(relPath: driveRelPath, hash:, origin: .propagated)` — moves the drive file **and** its sidecar into `<drive>/.openphoto/bin/<driveRelPath>` and appends to the drive's `bin.jsonl`. A file already gone (already binned / removed outside) is **skipped, not fatal** (idempotent re-run).
Then once, after the loop:
2. **One atomic manifest rewrite** — `Manifest.write(remaining, to: drive.manifestURL)` removing every propagated path (matches Slice 1's "rewrite `manifest.jsonl` atomically after each sync").
3. `catalog.removeVaultPresence(vaultID:, hashes:)` for the propagated hashes — so drive-only browse + the "backed up on canonical" badge stop showing them.
4. `catalog.clearPendingDeletions(hashes:)` — dequeue.
5. Append a `sync-log.jsonl` **`"delete"`** event (`counterparty_vault_id` = the drive's vault id, `summary` = "N propagated to drive bin").

Returns the count actually binned.

**Crash-consistency:** files move first (each independently recoverable in the drive bin); if interrupted before the manifest rewrite, the next **drift scan** (Slice 2) sees *file-in-bin / still-in-manifest* as a recoverable `missing` finding. Acceptable and self-healing — no data loss either way.

## 6. App / UI

Two surfaces, **one shared confirm path** (`AppState.propagateDeletions`) and **one shared list view**.

### 6.1 `AppState`
- `drivePendingDeletions: [String: [PendingDeletion]]` — eligible entries per drive, an `@Observable` stored cache (same pattern as `driveDrift`). Powers the row indicator's count.
- `refreshPendingDeletions()` — recompute for connected canonical drives from `pendingDeletions()` × `instanceHashes()` × `vaultPresenceRows(forVault:)`. Called on connect (`autoScanConnectedDrives`), after any local delete/restore/evict, after sync, and after propagation.
- `propagateDeletions(drive:selected:)` — run `DeletionPropagator.propagate` over the ticked subset, then `refreshCanonicalPresence` + `driftScan(drive)` + `refreshPendingDeletions()` + `refreshQueries()`.

### 6.2 `DeletionListView` (shared subview) — DRY across both surfaces
Each row: **small thumbnail (~32px, rounded)** · Mac-aligned path · "deleted Xm ago" · selection checkbox · a per-row **↩ Restore**. Thumbnails come from the local cache by hash (`ThumbnailStore.cachedDisplayImage(for:)`) — they render even though the local original is gone (it's in the Mac bin) and even with the drive unplugged; a missing cache entry falls back to a generic photo glyph. Header carries **Select All / Deselect All**.

**Restore vs Uncheck are distinct** (both offered):
- **Uncheck** — keep it deleted on the Mac; just don't remove the drive copy *this time* (stays pending).
- **Restore** — full undo: `state.restore(...)` brings the photo back to the Mac library and drops it from the queue; the row then disappears (it has a local instance again → no longer eligible).

### 6.3 Standalone surface
- **Drive row indicator** in `DrivesView` (beside the drift status line): `⚠ N deletions pending · Review →`, shown when `drivePendingDeletions[vaultID]` is non-empty and the drive is present. Opens **`DeletionReviewSheet`**.
- **`DeletionReviewSheet`** — computes eligibility on `.task` into local `@State` (no stale-`@State` read, the lesson from Slices 1/2), selection **defaults to all-selected**, renders `DeletionListView`, confirms with **"Move N to drive bin"**. Presented via `.sheet(item:)` on an `Identifiable` presentation struct.

### 6.4 In-Sync surface
- `SyncPlanSheet` gains a **Deletions** section (the same `DeletionListView`) for pending deletions not yet propagated, selection **defaults to none** so additive copies never delete by reflex. On **Apply**: additive copies run as today; the ticked deletions are propagated afterward via the same `propagateDeletions` path.

## 7. On-disk format (updated in the same commits — sovereignty discipline)

- **`docs/format/vault-format-v1.md` §8** — clarify that a *vault's* propagated deletions use `<vault-root>/.openphoto/bin/` with `origin: "propagated"` (reusing the §8 bin), and reaffirm that the volume-root `.openphoto-trash/` of §12 is **only** for removable *non-vault* volumes (SD cards). Lands with the propagator commit (M3).
- **§9** — add `"delete"` to the (non-exhaustive, informative) event-name list. Lands with M3.
- **`docs/superpowers/specs/2026-06-09-phase3-drives-design.md`** — fix the loose `.openphoto-trash/` wording at the two deletion-slice references → `.openphoto/bin/` (M5).
- **`docs/superpowers/specs/2026-06-07-openphoto-design.md`** — §4 note that delete-propagation review is available **standalone** (any time the drive is connected) in addition to at-sync; add a dated changelog entry (M5).

## 8. Where the code lives

- **Modify** `Sources/OpenPhotoCore/Catalog/Catalog.swift` — migration `v4` (`pending_deletions`); queue CRUD; `instanceHashes()`; `removeVaultPresence(vaultID:hashes:)`.
- **Create** `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift` — `PendingDeletion`, `eligible(...)`, `propagate(...)`.
- **Modify** `Sources/OpenPhotoCore/LibraryService.swift` — `delete` enqueues (+pair); `restore` dequeues (+pair); `evict` unchanged (verified clean).
- **Modify** `Sources/OpenPhotoApp/AppState.swift` — `drivePendingDeletions` cache; `refreshPendingDeletions`; `propagateDeletions`.
- **Create** `Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift` and `Sources/OpenPhotoApp/Drives/DeletionListView.swift`.
- **Modify** `Sources/OpenPhotoApp/Drives/DrivesView.swift` — pending-deletions indicator + `.sheet(item:)`.
- **Modify** `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift` — Deletions section.

## 9. Testing (TDD, Swift Testing, generated mock media only — never real user folders)

**Core:**
- Migration `v4` creates `pending_deletions`; enqueue / dequeue / `pendingDeletions()` / `clearPendingDeletions` round-trip.
- `DeletionPropagator.eligible` matrix: (a) deleted, no local instance, on drive → **eligible** (driveRelPath resolved); (b) deleted but a duplicate local instance of the same hash remains → **not** eligible; (c) evicted (never enqueued) → **not** eligible; (d) in queue but not on the drive → **not** eligible; (e) restored (dequeued) → **not** eligible.
- `DeletionPropagator.propagate` integration on a temp drive vault: a file at `driveRelPath` (+ manifest entry + presence row + queue entry) → after propagate, file is in `<drive>/.openphoto/bin/<driveRelPath>`, `bin.jsonl` has the entry with `origin: propagated`, the manifest no longer lists it, `vault_presence` row gone, queue cleared, original path absent, `sync-log.jsonl` has a `"delete"` event. Idempotent re-run (file already binned) → skipped, count reflects reality. Live pair (two hashes on the drive) → both binned.
- `LibraryService`: `delete` enqueues the still (+ pair); `restore` dequeues (+ pair); `evict` leaves the queue empty.

**App:** build-verified (0 warnings) + manual — indicator count; thumbnails render from cache (incl. drive unplugged) with glyph fallback; Select All/Deselect All; per-row Restore removes the row and returns the photo locally; Sync section unticked-by-default; propagate moves the drive copy into the drive bin and clears the indicator.

## 10. Out of scope (later slices / deferred)

- **Deleting drive-only assets** (a photo with no local copy) — deferred to **Slice 4 (eviction)**, where drive-only assets become common; it will reuse this slice's drive-side bin engine (the viewer keeps its `!isDriveOnly` guard until then).
- **Propagating deletions to backup drives** (multi-drive) — **Slice 5 (clone/migration)**; the Phase-3 queue clears once the single canonical drive is done.
- **Drive-bin management / restore-from-drive-bin UI** — the drive bin is recoverable on disk (and via `BinStore.restore` on the drive vault); surfacing it in the UI is future work.
- Full Live-Photo pair symmetry beyond the still+video mirroring described here.

## 11. Milestones

- **M1 — Catalog queue:** migration `v4` (`pending_deletions`), queue CRUD, `instanceHashes()`, `removeVaultPresence(vaultID:hashes:)`.
- **M2 — Enqueue/dequeue wiring:** `LibraryService.delete` enqueues (+pair); `restore` dequeues (+pair); `evict` verified clean.
- **M3 — Propagator + normative format:** `DeletionPropagator.eligible` + `propagate` (BinStore move + atomic manifest rewrite + presence removal + dequeue + `"delete"` sync-log); format §8/§9 edits in the same commit.
- **M4 — App + UI:** `AppState` pending cache + `propagateDeletions`; `DeletionListView` (thumbnails, select-all, per-row restore); `DeletionReviewSheet`; `SyncPlanSheet` deletions section; `DrivesView` indicator.
- **M5 — Doc reconciliation:** fix Phase-3 spec `.openphoto-trash/` wording; master-spec §4 standalone-review note + dated changelog entry.
