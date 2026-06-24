# Evict / Rehydrate — Mac↔Drive Storage Management

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation
**Ships in:** OpenPhoto v1.0.0

## Goal

Let the user move original media between the Mac and the canonical/backup drive at three
granularities, as a background job:

1. **Free up all Mac space** — evict every local original that is already verified on a drive.
2. **Download everything to the Mac** — rehydrate every photo the drive has that the Mac lacks.
3. **Per-folder** — right-click a folder in the folder screen → evict just that folder, or download
   just that folder back to the Mac.

Whenever an operation needs a drive that isn't connected, prompt the user to plug in the specific
drive that holds the files.

## Approved decisions

- **Progress UX:** background job with a sidebar chip (live speed/ETA, Cancel, Minimize) — the same
  treatment as the 150 GB sync. **Hard constraint: at most ONE drive job (sync / evict / rehydrate)
  runs at a time.**
- **Evict safety:** re-verify each file's copy **on the drive** (re-hash, `EvictMode.verified`)
  before trashing the Mac original. Slower (reads the drive) but guarantees a byte-perfect copy
  exists. Originals always go to the **Trash** (recoverable), never hard-deleted.
- **Placement:** the two global buttons live in the **Drives-screen header**, next to "Verify All
  Drives".
- **Folder operations are recursive** (folder + all descendant subfolders).
- **Evict confirmation is a clear destructive dialog with exact numbers**, not a typed-in
  confirmation.

## Hard invariants (reaffirmed)

- Original media is moved to the Trash only after a byte-identical copy is confirmed on a drive
  (`.verified` re-hash). Trash, never hard-delete. (Invariant 1 + 3.)
- Rehydration copies are atomic (temp → fsync → rename) and hash-verified against the recorded hash
  before the rename — the existing `VerifiedCopy.copy` guarantees this. (Invariant 4.)
- Sync remains strictly one-way (Mac → drive). Rehydration is the **Mac actively pulling** from a
  passive drive; the drive is never written by a rehydrate. (Invariant 5 unbroken.)
- No new on-disk format. Eviction/rehydration already exist and operate on the catalog `instances`
  and `vault_presence` tables and the macOS Trash; this feature adds entry points + progress, not
  new persisted state. `docs/format/` needs no change.

## Architecture: one unified Drive Job

Today the sync background job is bespoke in `AppState`/`AppState+Sync.swift`:
`syncActivity: SyncActivity?`, `syncTask`, `syncTickerTask`, `syncRateMeter`, `syncCancelFlag`,
`syncRaw`, plus the sidebar chip and `SyncPlanSheet`'s running/finished/failure views.

Generalize this into a single **`DriveJob`** with one active slot. There is exactly one job at a
time; every entry point is disabled while it is running.

```swift
struct DriveJob {
    enum Kind: String, Sendable { case sync, evict, rehydrate }
    enum Phase: Sendable { case running, finished, cancelled }
    enum Stage: String, Sendable { case verifying, copying, trashing, finishing }

    var kind: Kind
    var scopeLabel: String          // "all photos", a folder name, or the drive name — for display
    var driveName: String
    var phase: Phase
    var stage: Stage
    var bytesDone: Int64
    var bytesTotal: Int64
    var filesDone: Int
    var filesTotal: Int
    var currentName: String
    var speedBytesPerSec: Double
    var etaSeconds: Double?
    var result: DriveJobResult?
}

enum DriveJobResult: Sendable {
    case sync(SyncResult)
    case evict(EvictOutcome)
    case rehydrate(done: Int, failed: [FailedItem])
}
```

Renames (mechanical): `syncActivity → activeJob`, `syncTask → jobTask`,
`syncTickerTask → jobTickerTask`, `syncRateMeter → jobRateMeter`, `syncCancelFlag → jobCancelFlag`,
`syncRaw → jobRaw`. `SyncActivity` is replaced by `DriveJob`; the sync code paths set `kind = .sync`.
The existing sync tests/behaviour must be preserved (the byte-bar, ticker, "finishing" state, and
file-count fixes from the recent commits all carry over).

A `jobRunning: Bool { activeJob?.phase == .running }` flag on `AppState` gates every start point.

### Progress plumbing (Core, additive)

The two core functions gain default-nil progress + cancel parameters so existing callers are
unaffected (`LibraryService+Eviction.swift`):

```swift
// Re-verify (re-hash) reports bytes hashed + checks cancel; trashing reports file progress.
// Stages: .verifying → .trashing.
@discardableResult
func evict(_ items: [TimelineItem], mode: EvictMode,
           connectedCanonical: [Vault], canonicalPresence: Set<String>,
           progress: (@Sendable (DriveProgress) -> Void)? = nil,
           shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> EvictOutcome

// Threads onBytes/shouldCancel into the existing VerifiedCopy.copy. Stage: .copying.
@discardableResult
func rehydrate(_ items: [TimelineItem], connectedCanonical: [Vault],
               progress: (@Sendable (DriveProgress) -> Void)? = nil,
               shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> RehydrateOutcome
```

`DriveProgress` is a small Core struct mirroring the sync `SyncProgress`
(`stage, filesDone, filesTotal, bytesDone, bytesTotal, currentName`). The App's ticker reads the
latest `DriveProgress` into `activeJob` every 0.5 s and runs the shared `SyncRateMeter` to derive
whole-job speed + ETA — identical to the sync path.

`RehydrateOutcome` gains a `failedItems: [FailedItem]` list (keeping the existing `failed: Int` as
its count, so current callers like the Inspector are unaffected) so the failure report can name the
files and offer per-file Retry, matching sync.

### Gather queries (Core)

```swift
// Every local original that is verified-present on a durable drive (evict-all candidates).
func allEvictableLocal(canonicalPresence: Set<String>) throws -> [TimelineItem]
// Every asset on a drive but absent from the Mac (rehydrate-all candidates: in vault_presence, not in instances).
func allDriveOnly() throws -> [TimelineItem]
```

Folder subsets reuse `items(inDir:recursive: true)` then filter with `evictableItems(_:)` (new,
mirrors the Inspector's "backed up + local" check via `canonicalPresence`) / `rehydratableItems(_:)`
(exists).

## Entry points (UI)

### Drives header (`DrivesView.swift`)
Two buttons next to "Verify All Drives":
- **Free Up Mac Space…** → confirm dialog → start an `evict` job over `allEvictableLocal(...)`.
- **Download All to Mac…** → drive check → start a `rehydrate` job over `allDriveOnly()`.

Both `.disabled(jobRunning || no durable vaults)`. The existing per-drive buttons (Sync / Check /
Verify Integrity / Update backup / Make canonical / Verify All Drives) already gate on the job flag
(generalized from the `syncing` flag added for the sync feature).

### Folder context menu (`FolderTreeView.swift`)
Append to the existing right-click menu (after a divider):
- **Download This Folder to Mac…** — shown when the folder has ≥1 drive-only item.
- **Evict This Folder…** — shown when the folder has ≥1 evictable local item.

Each resolves its item set via `items(inDir: node.path, recursive: true)`, filters, runs the drive
check, then starts the corresponding job with `scopeLabel = node.name`.

## Drive detection + plug-in prompt

A shared resolver decides whether a job can run now or needs a drive:

```swift
enum DriveAvailability {
    case ready([Vault])          // connected drives that can serve, canonical-first
    case needsDrive(name: String) // no connected drive serves; ask the user to plug this one in
    case nothingToDo
}
func resolveDrive(forHashes: Set<String>, operation: .evict | .rehydrate) -> DriveAvailability
```

- **Evict** needs the **canonical connected** (to re-hash). If absent → `needsDrive(canonicalName)`.
- **Rehydrate** needs **any drive** whose `vault_presence` covers the hashes (canonical-first). If
  none connected → `needsDrive(name)` for the best-covering registered drive.

`needsDrive` drives the existing `confirmationDialog` pattern (cf. `guidedPlugInTarget` in
`DrivesView`): *"Plug in '⟨name⟩' to download 1,203 photos"* / *"…to free up space."* with a Cancel.
The user plugs in and retries; we do not auto-wait/poll.

## Safety & confirmations

- **Evict-all:** destructive `.alert` — *"Move 16,784 originals (148 GB) to the Trash? They stay on
  '⟨drive⟩' and you can download them back anytime."* — destructive "Free Up Space" button + Cancel.
- **Evict-folder:** same copy scoped to the folder's counts.
- **Rehydrate** has no destructive confirmation (it only adds data to the Mac), but shows a one-line
  confirm with the count + total size before starting a large download, and the free-space guard
  (reuse the sync's free-space pre-check) refuses if the Mac can't hold it.

## Result + failure reporting

Generalize `SyncPlanSheet`'s running/finished/failure views into a shared job sheet reachable from
the chip:
- **Evict finished:** *"Freed 16,784 photos (148 GB). 3 kept — couldn't verify on the drive."* The 3
  refused items are listed (no Retry; they were kept safe by design).
- **Rehydrate finished:** *"Downloaded 1,203 photos."* Failures listed with per-file **Retry** (same
  component as sync failures, driven by `RehydrateOutcome.failed`).

## Testing

Core (`swift test`):
- `evict` reports byte progress monotonically up to total during `.verifying`, then file progress
  during `.trashing`; `shouldCancel` stops mid-job and leaves catalog + drive consistent (nothing
  half-trashed beyond the cancelled file); refused items are kept local.
- `rehydrate` reports byte progress to total; cancel mid-copy leaves no temp and no half file
  (existing `VerifiedCopy` guarantee); `RehydrateOutcome.failedItems` names source-missing/copy-failed
  items.
- `allEvictableLocal` returns exactly the local+backed-up set; `allDriveOnly` returns exactly the
  in-`vault_presence`-not-in-`instances` set.
- `resolveDrive` returns canonical-first `ready` when connected, and `needsDrive(correctName)` when
  the serving drive is absent.
- The existing sync tests (`SyncApplyTests`, `SyncRateMeterTests`, `VerifiedCopyTests`) still pass
  after the `DriveJob` generalization.

App behaviour is verified by Jude's live smoke on real hardware (the established pattern).

## Out of scope (YAGNI)

- No automatic eviction by age/size policy — this is all explicit, user-initiated.
- No partial/streamed selective eviction by smart criteria — only "all", "this folder", and the
  existing per-photo Inspector action.
- No auto-wait that watches for a drive to be plugged in — the prompt is one-shot; the user retries.
- No change to the one-way sync engine.
