# Reconnect Review — "Changes since last connect" Design

**Status:** Approved direction, design for review (not yet a build plan).
**Date:** 2026-06-25
**Supersedes behavior:** the silent auto-apply of queued offline folder ops on drive reconnect.

**Goal:** When a registered drive reconnects, present the user with everything that changed while it was unplugged — moves, deletions, and drive-side drift — and let them **approve (propagate to the drive)** or **undo (revert the Mac to the drive's truth)** each change, item by item. Nothing touches the drive until the user acts.

**Architecture in one line:** The catalog already holds the *optimistic* post-offline-edit state; the queued ops + pending deletions + drive drift are the diff to reconcile. We stop auto-applying that diff on reconnect and instead surface it in one review sheet, reusing the existing apply/restore machinery.

---

## Locked decisions (from Jude)

1. **Review & approve on reconnect** — hold offline changes pending until the user approves; offer propagate vs undo (drive = ground truth). Replaces today's silent auto-apply.
2. **New photos (adds) stay with Sync** — the review covers moves + deletions + drive drift only. Newly-imported local photos are still backed up by the existing **Sync** button, unchanged.
3. **Auto-open on reconnect** — the review sheet opens automatically whenever a reconnecting drive has anything to review. No banner-only mode.
4. **Fold "Check" in; keep Sync + Verify** — remove the standalone **Check** button (its fast drift scan *is* this review now). Keep **Sync** and **Verify Integrity** functionally unchanged, each with an explanatory tooltip.

---

## Current behavior (what we're changing)

- **Reconnect** — `AppState.reconnectDrive()` (AppState.swift:1468) fires a Task that calls `reconcileFolderOps()` (AppState.swift:1813) → `applyPendingFolderOps()` (AppState+FolderReorg.swift:364), which **silently replays every queued op onto the drive**, then `driftScan()` (AppState.swift:1711). Same on launch/mount via `autoScanConnectedDrives()` (AppState.swift:1817).
- **Queued ops** live in `pending_folder_ops`; op kinds enqueued today: `move`/`rename`/`create`/`delete` folder (AppState+FolderReorg.swift:88/142/309/349) and `moveFile` (AppState+FolderReorg.swift:193/237). Replayed per-kind in `applyPendingFolderOps` (AppState+FolderReorg.swift:371-418).
- **Deletions** — deleting a photo enqueues a `pending_deletion` (LibraryService.delete); `DeletionPropagator.eligible()` computes which apply to a connected drive (queued ∧ no-local-instance ∧ on-drive); `AppState.propagateDeletions()` (1676) bins the drive copy; `restorePending()` (1692) un-bins locally; cache in `drivePendingDeletions` (1645), refreshed by `refreshPendingDeletions()` (1661).
- **Drift** — `DriftReconciler().scan()` (fast: existence/size/mtime) categorizes `unknown`/`missing`/`changed`; `verify()` (full re-hash) adds `corrupt`. `driftScan` rebuilds the drive's `vault_presence` from the manifest via `replaceVaultPresence(... limitedTo: report.presentHashes)` (AppState.swift:1717).
- **UI** — per-drive buttons in DrivesView.swift: Sync (230), Check (232), Verify Integrity (235), Quick View (238). Drift status line "N change(s) · Review" / "No changes" (291-312) → `DriftReviewSheet`. Deletion line "N deletion(s) pending · Review" (278-287) → `DeletionReviewSheet`.

### The correctness trap this design must avoid

Folder moves now update the catalog **optimistically** at move time (commit `1ab58b9`: `rewriteVaultPresencePath` re-keys the drive's presence row to the new location immediately, even while the drive is offline). But `driftScan` **rebuilds presence from the drive manifest** (AppState.swift:1717), and the manifest still shows the *old* location until the move is actually applied to the drive. So a naive reconnect drift scan would **revert the optimistic move** — the photo would jump back to the old folder before the user has reviewed anything.

**Invariant we adopt:** for any drive, `vault_presence == (drive manifest) + (pending ops applied to presence)`. Every time we rebuild presence from the manifest, we must re-apply the still-pending ops to presence (catalog-only, no drive writes). See `reapplyPendingOpsToPresence` below.

---

## Design

### 1. The model

Three reviewable categories, all already tracked — the sheet aggregates them:

| Category | Source | Propagate (approve) | Undo (drive = truth) |
|---|---|---|---|
| **File moves** | `pending_folder_ops` kind `moveFile` | apply op to drive (`VaultReorganizer.moveFile`), clear op — *reuses replay logic* | move the local file back dst→src, re-path instance + presence back, clear op — **new** |
| **Folder changes** | `pending_folder_ops` kinds `move`/`rename`/`create`/`delete` | apply op to drive, clear op — *reuses replay logic* | reverse the op locally, clear op — **new** |
| **Deletions** | eligible `pending_deletions` | bin the drive copy (`DeletionPropagator.propagate`) — *reuses* | restore locally (`restorePending`) — *reuses* |
| **Drive drift** | `DriftReconciler().scan` → `unknown`/`missing`/`changed` | adopt / restore / acknowledge — *reuses existing actions* | — (drift is one-directional) |

Corrupt (`verify`-only) is **not** in the auto-review — it requires a full re-hash, which stays behind the **Verify Integrity** button.

### 2. Reconnect / mount flow (gated)

Replace the auto-apply with a gather-and-present sequence. On reconnect (`reconnectDrive`) and mount/launch (`autoScanConnectedDrives`), for each present durable drive:

1. **Do NOT** call the draining `applyPendingFolderOps`.
2. Run `driftScan(drive)` as today — **but** `driftScan`'s presence rebuild now calls `reapplyPendingOpsToPresence(driveID:)` immediately after `replaceVaultPresence`, so the optimistic moves survive (invariant above). This makes *every* `driftScan` caller airtight, not just reconnect.
3. Compute the review payload: `pendingFolderOps(forVault:)` + `drivePendingDeletions[id]` + the drift report.
4. If the payload is non-empty **and** the drive is not an adoption candidate (`adoptableDrive` already excludes drives with pending ops, AppState.swift:1593), set `reviewDrive = ReviewPresentation(drive:)`. DrivesView auto-presents the sheet. If empty, stay silent (drive shows connected/clean).
5. Nothing is written to the drive.

`reconcileFolderOps` keeps existing non-reconnect callers honest:
- **Sync** (`DriveJobSheet.computePlan`) — **unchanged**: it still reconciles (propagates moves) before planning, because Sync's job is to push the Mac's state to the drive. Pushing moves is part of that.
- **Verify Integrity** (`verifyAllConnected`, AppState.swift:1735) — **stop draining**. Verify must not silently apply moves; pending moves aren't drift (the drive is self-consistent), so verify is correct without draining. Its `replaceVaultPresence` (1744) routes through the same presence helper so the optimistic state is preserved.

### 3. The review sheet — `ReviewChangesSheet`

New file `Sources/OpenPhotoApp/Drives/ReviewChangesSheet.swift`. One sheet, header `Changes since last connect — <drive name>`, **Done** to dismiss. Per-row immediate actions with per-section bulk buttons (modeled on `DriftReviewSheet` — the established, low-risk pattern). Two groups:

**Group A — "Your changes to push"** (only shown when non-empty):
- **Moves** — one row per `moveFile` op: `moved <name> · <A> → <B>`, trailing `[Undo] [Propagate]`. Header bulk: `[Propagate all] [Undo all]`.
- **Folder changes** — one row per folder op: `<renamed/moved/created/deleted> <path>`, trailing `[Undo] [Propagate]`. Header bulk as above.
- **Deletions** — reuse `DeletionListView` rows (thumbnail + "deleted X ago"); trailing `[Restore] [Bin on drive]`. Header bulk `[Bin all] [Restore all]`.

**Group B — "Found on the drive"** (drift; only shown when non-empty):
- **Unknown / Missing / Changed** sections — reuse the existing section + row components from `DriftReviewSheet` (Adopt / Restore / Acknowledge), factored into shared subviews so there's no duplicate UI.

Acting on a row removes it; when both groups empty, the sheet shows a green "All caught up" state (like `DriftReviewSheet`'s clean state) and can be dismissed. Closing with items still pending leaves them queued (re-offered next reconnect; reachable via the Drives status line — see §5).

`load()` runs a fresh fast `driftScan` on open (cheap), then reads pending ops + deletions — identical lifecycle to `DriftReviewSheet.load()`.

### 4. New AppState / catalog surface

- `reapplyPendingOpsToPresence(driveID:)` — for each pending op, apply its presence transform catalog-only (no drive/file writes): `moveFile` → `rewriteVaultPresencePath(src→dst)`; folder `move`/`rename` → `rewriteVaultPresencePaths(fromDir:src, toDir:dst)` (Catalog.swift:488); `create`/`delete` → none. Called from a single presence helper used by `driftScan` and `verifyAllConnected`.
- `propagateFolderOp(_ op:, driveVault:)` — apply ONE queued op to the drive + `clearFolderOp(id:)`. Refactor: extract the per-kind body of `applyPendingFolderOps` (AppState+FolderReorg.swift:371-418) into a single-op function; `applyPendingFolderOps` becomes a loop over it (used by Sync).
- `undoFolderOp(_ op:)` — reverse ONE op against the Mac, catalog-only re-path + local file move, then `clearFolderOp`. Per kind:
  - `moveFile src→dst`: if a local instance exists at dst, `VaultReorganizer.moveFile(dst→src)` on the Mac vault; `rewriteInstancePath(dst→src)`; `rewriteVaultPresencePath(driveID, dst→src)`.
  - `move`/`rename src→dst`: reverse the folder op on the Mac vault; `rewriteVaultPresencePaths(toDir:src, fromDir:dst)`; re-derive locked flags.
  - `create dst`: remove the empty local folder dst (if empty).
  - `delete src`: re-create the local folder src.
  - Drive is never touched by undo.
- `reviewPayload(forDrive:) -> ReviewChanges` — gathers ops + eligible deletions + drift into a value type the sheet renders.
- AppState state: `var reviewDrive: ReviewPresentation?` (Identifiable wrapper around `Vault`, like `DriftPresentation`); DrivesView binds `.sheet(item: $reviewDrive)`.

### 5. DrivesView changes (folds in D)

- **Remove** the **Check** button (DrivesView.swift:232-234) and the standalone `DriftReviewSheet` presentation for the fast-scan path. The fast drift scan now lives in the review.
- The existing drift status line "N change(s) · Review" / "No changes" (291-312) and the deletion line (278-287) **collapse into one** "N change(s) since last connect · Review" line that opens `ReviewChangesSheet` (re-scanning on open). "No changes" when the payload is empty.
- **Sync** (230) — unchanged. Add `.help("Copy new photos and edits from this Mac to the drive.")`.
- **Verify Integrity** (235) — unchanged behavior; still opens the existing `DriftReviewSheet(verify: true)` (deep re-hash, surfaces corruption). Add `.help("Re-hash every file on the drive to catch silent corruption. Slow — for periodic deep checks.")`.
- **Quick View** (238) — unchanged.

### 6. Data safety (invariants preserved)

- **Drive is passive.** Reconnect writes nothing to the drive; only explicit Propagate (or Sync) does. (Invariant 5.)
- **Undo is non-destructive.** Undo reverts the Mac to match the drive; it moves local files or un-bins — it never hard-deletes. (Invariants 1, 3.)
- **Propagate reuses verified machinery.** Move propagation uses the tested `VaultReorganizer`; deletion propagation bins (never hard-deletes) the drive copy via `DeletionPropagator`. (Invariants 3, 4.)
- **No format change.** `pending_folder_ops`, `pending_deletions`, and the manifest are unchanged on disk, so `docs/format/` needs no edit. The reconnect *semantics* change is recorded as a dated changelog entry in the design spec `docs/superpowers/specs/2026-06-07-openphoto-design.md` (sync-flows section) when this ships.

### 7. Out of scope

- New-photo (add) propagation — stays with **Sync**.
- Corrupt detection in the auto-review — stays with **Verify Integrity**.
- Any change to Sync's plan/apply logic.

---

## Testing (must be airtight)

Core (OpenPhotoCoreTests, catalog/reorg level):
- `reapplyPendingOpsToPresence` preserves an optimistic move across a manifest-driven presence rebuild (`replaceVaultPresence` then reapply → presence at NEW location, drift report still clean).
- Propagate a `moveFile`: drive file moves OLD→NEW, op cleared, presence at NEW, drift clean (extends `appliedDriveMoveLeavesDriftClean`).
- Undo a `moveFile`: local file back at OLD, instance + presence at OLD, op cleared, **drive untouched** (drive file still at OLD).
- Undo a folder `rename`/`move`: local folder + all its instances revert, op cleared, drive untouched.
- Undo / Propagate a deletion: restore dequeues locally; propagate bins the drive copy + clears (extend existing deletion tests).

App level (where testable) / manual smoke:
- Reconnect with pending moves → review auto-opens, photos stay in their NEW folders (optimistic preserved), drive unchanged until Propagate.
- "No changes" path stays silent.
- Removing the Check button doesn't strand the fast scan (Review line covers it).

---

## Open risks

- **Folder-op undo breadth.** File-move undo is the headline path; folder move/rename/create/delete undo is included for completeness and each gets a test. If any proves fiddly, it can ship Propagate-only with Undo following — flagged at plan time, not silently dropped.
- **Verify tooltip vs. behavior.** Verify Integrity stays on the old `DriftReviewSheet` to honor "unchanged"; this leaves two drift sheets briefly. Shared section components keep it DRY. If we later want one sheet, Verify can route into `ReviewChangesSheet(verify: true)`.

---

## Next step

On approval: `superpowers:writing-plans` → a task-by-task implementation plan, then `superpowers:subagent-driven-development` to build it. Likely the headline feature of **1.1.0** (A/B/E/F ship as **1.0.2** beforehand, or all together — Jude's call).
