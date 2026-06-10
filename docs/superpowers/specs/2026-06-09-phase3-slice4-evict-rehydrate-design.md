# Phase 3 Slice 4 — Evict / Rehydrate / Drive-only Deletion: Design Spec

**Status:** Approved (2026-06-09). Detailed design for Phase 3 **Slice 4**. Part of the roadmap in `docs/superpowers/specs/2026-06-09-phase3-drives-design.md` (order: 1 ✅ · 2 ✅ · 2.5 ✅ · 3 ✅ · **4 ⬅ evict/rehydrate + drive-only delete** · 4.5 send-from-drive · 5 clone/migrate).

**One-line goal:** free Mac space by releasing local originals that are safely on the canonical drive (evict), bring them back on demand (rehydrate), and let you delete a photo that lives only on the drive.

---

## 1. Why this slice exists

Browse (Slice 2.5) already shows **drive-only** assets — thumbnail + metadata persist on the Mac, full-res lives on the drive. But nothing yet *makes* a local photo drive-only on purpose. This slice delivers the working-set control the whole "library is just files, the app manages where the bytes live" vision needs:

- **Evict** — release a selection's local originals (to macOS Trash) once verified on the canonical drive; the asset stays browsable as drive-only.
- **Rehydrate** — copy evicted originals back from the drive, hash-verified.
- **Drive-only deletion** (deferred from Slice 3) — delete a photo that exists only on the drive, straight into the drive's bin.

The current `evict` is a Stage-A shortcut (moves local files into the *local vault bin* with `origin:.user` — doesn't free space until the bin empties, and conflates with delete). Slice 4 replaces it with the real operation.

## 2. Invariants (honored)

- **Originals never lost.** Evict releases the local copy to **macOS Trash** (recoverable), never a hard `unlink`. The drive copy is untouched.
- **Verify before release (default).** A verified evict re-hashes the drive copy and only releases the local original on a byte match — the gold standard, at the moment you let go.
- **Atomic + hash-verified copies.** Rehydrate uses `VerifiedCopy` (temp → fsync → re-hash → rename; never overwrites).
- **Drives passive / one-way.** Evict reads + verifies the drive; rehydrate copies *from* it; drive-only delete moves the drive copy into the drive's own `.openphoto/bin/` (§8). No merge.
- **Explicit action only.** Eviction is never automatic; it's a deliberate, gated, progress-barred operation.

## 3. Evict (the real operation)

`LibraryService.evict(_ items:, mode:)` replaces the Stage-A bin version. Two modes:

### 3.1 `.verified` (default — the obvious "Evict" button)
Requires the canonical drive **connected**. Per selected **local** item:
1. Find a **connected canonical** vault whose `vault_presence` holds the item's hash → its `driveRelPath`.
2. **Re-hash** the drive file (`ContentHash.ofFile(at: drive/driveRelPath)`); proceed only if it equals the item's hash.
3. `FileManager.trashItem` the **local original** (the media file). **Leave the local sidecar** in place (tiny; keeps rehydrate trivial).
4. **Live pairs evict as a unit:** the paired video must also verify on the drive; if either half fails, **refuse both** (never half-evict a Live Photo).

Items with **no connected-canonical copy**, or whose drive bytes don't match, are **refused and counted** (kept local, reported) — never released. After processing, **one rescan** per touched local vault drops the released files' `instances` rows → the assets become **drive-only** (`vault_presence`, untouched, still carries them). Records the existing `"evict"` sync-log event.

### 3.2 `.forced` (override — "Force Evict (skip verification)")
The deliberate escape hatch (e.g. drive at home while travelling). Releases the local original to Trash if the item's hash is in **any** canonical `vault_presence` (the drive may be **absent**; bytes are **not** re-checked) — trusting the hash recorded at sync time. Same trash + rescan tail. Items not in any canonical presence are still refused. **Still goes to macOS Trash** (the one recoverable floor that makes the override tolerable).

### 3.3 Outcome
`EvictOutcome { evicted: Int, refused: Int }`. The UI reports e.g. "Evicted 42 · 3 kept (not verified on a connected drive)".

## 4. Rehydrate (new)

`LibraryService.rehydrate(_ items:)` — for each selected **drive-only** item (drive **connected**):
1. Resolve the drive file: the item carries `driveRelPath` + `vaultID` (the drive's). Drive file = `driveVault.absoluteURL(forRelativePath: driveRelPath)`.
2. **Map back to a local vault + path** (inverse of `DrivePathMap.driveToMacRelPath`): `driveRelPath`'s first path component is the source-vault basename; the target is the **local vault whose `rootURL.lastPathComponent` matches it**, at the item's Mac-aligned `relPath`. (Single-local-vault is the common case; if no basename matches, fall back to the primary local vault + `relPath`.)
3. `VerifiedCopy.copy(from: driveFile, to: localPath, expectedHash: item.hash)` — atomic, re-hashed, never overwrites.
4. **Live pairs rehydrate together** (best-effort: still + paired video).
5. After processing, **rescan** the target local vault → the `instances` row reappears → the asset is **local** again (and still on the drive: now backed-up). Records a new `"rehydrate"` sync-log event (format §9 addition).

`RehydrateOutcome { rehydrated: Int, failed: Int }`.

## 5. Drive-only deletion (deferred from Slice 3)

`DeletionPropagator.deleteDriveOnly(drive:, entries:, catalog:)` — for a **drive-only** photo (drive connected), move its drive copy straight into the drive's `.openphoto/bin/` (`origin:"user"` — deleted directly in that vault's UI, §8), then the same drive-side bookkeeping as `propagate`: **atomic manifest rewrite** dropping the path, **`removeVaultPresence`** for the hash, and a `"delete"` sync-log event. **No local bin, no `pending_deletions`** (there's nothing local to track). Reuses the exact engine `propagate` already uses; `deleteDriveOnly` is the no-local-copy sibling.

Reachability: the existing **Delete** affordances (viewer / inspector / selection) currently disable for drive-only items. Slice 4 enables Delete for a drive-only item **only when its drive is connected** (else it stays disabled — the file is unreachable). The local-item Delete path (Slice 3) is unchanged.

## 6. Catalog / on-disk format

- **No new catalog tables.** Evict removes local `instances` (via rescan) and leaves `vault_presence` (drive) intact → drive-only. Rehydrate restores `instances`. Drive-only delete removes the hash from `vault_presence` + the drive manifest.
- **Format §9** — add `"rehydrate"` to the (informative) sync-log event-name list (same-commit, sovereignty discipline). `"evict"` and `"delete"` already exist and cover their cases.

## 7. App / UI

- **Evict** (existing selection/inspector button) now performs the **real `.verified`** evict: a sheet with a re-hash **progress** bar, then an outcome summary ("Evicted N · M kept — not on a connected drive"). The old "only-copy → still bins" warning becomes a **refusal** ("M can't be evicted — not yet verified on a connected drive").
- **Force Evict (skip verification)** — reached via an **overflow menu** (not a primary button). Its confirmation sheet lists the count and requires an explicit **acknowledgment toggle** ("If the drive copy is missing or damaged, emptying the Trash loses these originals") before the destructive **Force Evict** button enables. A few deliberate clicks.
- **Rehydrate** — a new selection/inspector action, shown when the selection includes **drive-only** items and the relevant drive is **connected**; copies them back with progress.
- **Delete** — enabled for **drive-only** items only when their drive is connected; routes to drive-only deletion (§5). For local items, unchanged (Slice 3).
- **AppState** — `evict(_:mode:)`, `rehydrate(_:)`, `deleteDriveOnly(_:)` wrappers (off-main for the re-hash/copy I/O, mirroring `verifyIntegrity`/`propagateDeletions`), each refreshing queries + presence + the pending/drive caches afterward.

## 8. Where the code lives

- **Create** `Sources/OpenPhotoCore/LibraryService+Eviction.swift` — `evict(_:mode:)` (verified/forced) + `rehydrate(_:)` as a focused extension (reuses the service's `catalog`/`vaults`/`vault(id:)`/`rescan`; keeps `LibraryService.swift` from growing). `EvictMode`, `EvictOutcome`, `RehydrateOutcome` value types.
- **Modify** `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift` — add `deleteDriveOnly(drive:entries:catalog:)` (drive-bin move + manifest + presence + sync-log; no queue).
- **Modify** `Sources/OpenPhotoCore/LibraryService.swift` — remove the Stage-A bin-based `evict`; the new evict lives in the extension. (Keep `delete`/`restore` as-is.)
- **Modify** `Sources/OpenPhotoApp/AppState.swift` — `evict(_:mode:)`, `rehydrate(_:)`, `deleteDriveOnly(_:)` wrappers; eviction eligibility helpers (`evictableItems`/`rehydratableItems`/`driveOnlyDeletable`).
- **Modify** the selection toolbar (`SelectionUI.swift` + `TimelineView`/`FolderGridView`) and `InspectorView` — Evict (real) + Force-Evict overflow + Rehydrate + drive-only Delete enablement; an `EvictProgressSheet` / `RehydrateProgressSheet` (or reuse a shared progress sheet).
- **Modify** `docs/format/vault-format-v1.md` §9 (`"rehydrate"` event) — same commit as rehydrate.

## 9. Out of scope (later)

- **Send-from-drive** → **Slice 4.5** (presence-aware Send: AirDrop an evicted photo straight from the drive without rehydrating).
- **Editing drive-only assets** (sidecar-edit queue applied at next sync) — stays deferred; drive-only remains view-only.
- **Backup-drive** interactions (evict requiring a *backup* too, clone) → Slice 5.
- **Auto-eviction / storage targets** — never automatic; explicit only.

## 10. Testing (TDD, Swift Testing, generated mock media only — never real user folders)

**Core (integration on temp vaults + a temp "drive" vault):**
- **Verified evict** — a local item whose hash + matching bytes are on the connected drive → local original is trashed (gone from its folder), the asset is now drive-only (`timelineItems` shows it with `driveRelPath != nil`), `vault_presence` still holds it. The local **sidecar remains**.
- **Refusal** — a local-only item (not on any canonical drive) → refused, kept local, counted in `EvictOutcome.refused`. Drive present but **bytes differ** (corrupt the drive copy) → refused under `.verified`.
- **Forced evict** — releases even when the drive is **absent** (presence-only), trusting the recorded hash; an item not in any presence is still refused.
- **Live pair** — evicting a Live still evicts the paired video too; if the video doesn't verify, **both** are refused.
- **Rehydrate** — a drive-only item → `VerifiedCopy` back → byte-identical local original, asset local again; **path-mapping inverse** puts `Pictures/rome/IMG.jpg` (drive) back at `rome/IMG.jpg` under the `Pictures` local vault.
- **Drive-only delete** — `deleteDriveOnly` moves the drive file into `<drive>/.openphoto/bin/`, removes the manifest line + `vault_presence` row, writes a `"delete"` sync-log event; an unrelated manifest entry is preserved.
- `trashItem` is exercised against temp-dir files (macOS trashes temp-dir items fine in tests).

**App:** build-verified (0 warnings) + manual — evict progress + refusal summary; Force-Evict overflow + ack-gated confirm; Rehydrate; drive-only Delete enabled only when the drive's present.

## 11. Milestones

- **M1 — Verified evict:** `LibraryService+Eviction` `evict(_:mode:.verified)` (connected + re-hash + trash + refuse + Live-pair-as-unit), `EvictMode`/`EvictOutcome`; replace the Stage-A evict; AppState `evict(_:mode:)` off-main.
- **M2 — Forced evict:** the `.forced` branch (presence-only, drive-may-be-absent) + the Force-Evict overflow UI (ack-gated confirm).
- **M3 — Rehydrate:** `rehydrate(_:)` (path-mapping inverse + `VerifiedCopy` + Live pair + `"rehydrate"` sync-log + format §9), AppState wrapper, Rehydrate selection/inspector action + progress.
- **M4 — Drive-only deletion:** `DeletionPropagator.deleteDriveOnly`, AppState `deleteDriveOnly`, enable Delete for drive-only-when-present across viewer/inspector/selection.
- **M5 — UI polish + docs:** evict/rehydrate progress sheets, outcome summaries, the refusal copy; master-spec changelog entry.
