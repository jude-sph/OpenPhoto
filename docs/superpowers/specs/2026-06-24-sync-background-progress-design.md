# Background sync — live progress, minimize, cancel, failure report — design

**Status:** approved design, pending implementation plan
**Date:** 2026-06-24
**Author:** Jude + Claude

## Overview

Syncing a large library (e.g. 150 GB) to the canonical drive today gives poor live
feedback and no control: the progress bar tracks **file count, not bytes** (so it stalls on
big videos), there is **no speed or ETA**, the run can't be **cancelled** (the Close button
is disabled while running), and **failures aren't surfaced or retryable**. The sync also runs
in a throwaway `Task` *inside* the sheet, untracked — dismissing the sheet leaves it running
with no way to observe or stop it.

This redesign makes a sync a first-class background job:

- **Live byte-accurate progress** with smoothed **speed (MB/s)** and **ETA**, smooth even
  within a single multi-GB file.
- **Minimize to background**: close the sheet, keep working; a **sidebar chip** shows live
  progress and re-opens the sheet.
- **Graceful Cancel** (~1 s), keeping everything already copied (resumable on re-sync) and
  discarding the in-flight file.
- An **actionable failure report**: the exact files that didn't sync, with filenames, plain
  reasons, optional thumbnails, and one-click **Retry**.

### Goals

- Make a 150 GB sync legible and controllable while it runs.
- Preserve every existing safety guarantee (atomic temp→fsync→rename, hash verification,
  never-overwrite, idempotent resume). These must not regress.
- Reuse existing patterns: `AppState.derivationTask` (stored, cancellable background work),
  the sidebar footer progress line, and the thumbnail cache.

### Non-goals (YAGNI)

- The **Send to phone/SD** flow (`SendEngine`/`SendProgress`) has the same shape and could get
  the same treatment, but is **out of scope** for this spec.
- Per-byte resume *within* a single interrupted file (resume stays per-file; a file interrupted
  mid-copy is re-copied from the start — its partial temp is discarded).
- Multiple concurrent syncs. **One active sync at a time** (matches the per-drive sheet).
- Pause/resume controls (only Cancel). Re-syncing resumes by design.

## Architecture

Five units, each with a clear boundary:

| Unit | Layer | Responsibility | Depends on |
|------|-------|----------------|------------|
| `VerifiedCopy` (streaming) | Core | Chunked, atomic, hash-verified copy with per-byte progress + cancellation | Foundation, CryptoKit |
| Sync progress/result/failure model | Core | `SyncProgress` (+bytes), `SyncResult` (+cancelled), `SyncFailureReason`, `FailedItem` | — |
| `SyncEngine.apply` | Core | Per-file loop reporting bytes, honoring cancel, classifying failures, writing the resume manifest | VerifiedCopy, Manifest |
| `AppState` sync activity | App | Own the sync Task; compute speed/ETA; start/cancel/retry; expose `syncActivity` | SyncEngine |
| Sync UI | App | Plan sheet → progress view → failure report; sidebar chip | AppState |

### Data flow

```
SyncPlanSheet "Sync" ─▶ AppState.startSync(plan, drive, volume)
                          │  stores syncTask
                          ▼
                     SyncEngine.apply(shouldCancel:, progress:)
                          │  streaming VerifiedCopy per file, chunked
                          ▼  progress(bytesDone, filesDone, currentName, …)  [throttled]
                     AppState.syncActivity  ── speed=EMA, eta=remaining/speed
                          ├────────────▶ SyncPlanSheet (progress view)   ← reopen via chip
                          └────────────▶ Sidebar chip (mini bar + GB + MB/s)
   Cancel ─▶ flag ─▶ engine stops after current chunk ─▶ temp discarded ─▶ result.cancelled
   Finish-with-failures ─▶ syncActivity holds SyncResult.failed ─▶ failure report
```

## Core 1 — streaming `VerifiedCopy`

Replaces the whole-file `copyItem` with a chunked stream so we get per-byte progress,
responsive cancel, and single-pass hashing.

```swift
public enum CopyOutcome: Sendable { case copied, cancelled, failed(SyncFailureReason) }

public static func copy(
    from source: URL, to dest: URL, expectedHash: String,
    chunkBytes: Int = 4 << 20,                          // 4 MB
    onBytes: (@Sendable (Int64) -> Void)? = nil,        // cumulative bytes written for THIS file
    shouldCancel: (@Sendable () -> Bool)? = nil
) -> CopyOutcome
```

Behavior (preserving every current guarantee):
1. Refuse if `dest` already exists (caller handles the conflict pre-check).
2. Create parent dir; open `source` for reading, a temp `.tmp-<UUID>` for writing (`defer`
   removes the temp on any non-success path).
3. Loop: read up to `chunkBytes` → write to temp → update an **incremental SHA-256**
   (CryptoKit `SHA256`) → `onBytes(total)`. Between chunks, if `shouldCancel?()` → return
   `.cancelled` (temp discarded by `defer`).
4. On EOF: `fsync` (FileHandle.synchronize) → finalize hash → if `!= expectedHash` return
   `.failed(.hashMismatch)` → else atomic `moveItem(tmp → dest)` → return `.copied`.
5. Map thrown errors to `.failed(.sourceMissing)` (read/open source) or `.failed(.copyFailed)`
   (write/rename — disk full, permissions, drive gone).

Note: the streamed hash must match the catalog's content-hash algorithm. `ContentHash`
currently hashes a file in one pass; the streaming hash must produce the identical digest
(same algorithm, whole-file, no per-chunk framing). A Core test asserts
`streamedHash(file) == ContentHash.ofFile(file)`.

## Core 2 — progress / result / failure model

```swift
public struct SyncProgress: Sendable {
    public enum Stage: String, Sendable { case copying, verifying, finishing }
    public let stage: Stage
    public let done: Int           // files copied so far
    public let total: Int          // files to copy
    public let bytesDone: Int64    // NEW: Σ completed-file sizes + current-file bytes
    public let bytesTotal: Int64   // NEW: plan.totalCopyBytes
    public let currentName: String
}

public enum SyncFailureReason: String, Sendable {
    case sourceMissing      // source file gone / unreadable
    case copyFailed         // I/O writing to the drive (disk full, permissions, drive gone)
    case hashMismatch       // copied bytes didn't verify — temp discarded
    case conflict           // a DIFFERENT file already occupies that path (never overwritten)
    public var userText: String { … }   // plain-English, for the report
    public var isRetryable: Bool { self != .conflict }
}

public struct FailedItem: Sendable, Equatable {
    public let item: PlanItem        // carries hash + sourceURL + destRelPath + size
    public let reason: SyncFailureReason
}

public struct SyncResult: Sendable, Equatable {
    public var copied = 0
    public var sidecarsWritten = 0
    public var skipped = 0
    public var failed: [FailedItem] = []   // CHANGED from [PlanItem]
    public var cancelled = false           // NEW
    public var conflicts: Int { failed.filter { $0.reason == .conflict }.count }
}
```

## Core 3 — `SyncEngine.apply`

```swift
public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                  event: String = "sync", counterpartyVaultID: String? = nil,
                  shouldCancel: (@Sendable () -> Bool)? = nil,         // NEW
                  progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult
```

- Track `bytesDone` across the `plan.copies` loop. Before each file, `if shouldCancel?() {
  result.cancelled = true; break }`. Call the streaming `VerifiedCopy` with an `onBytes` that
  reports `SyncProgress(bytesDone: completedBytes + fileBytes, …)` (throttled to ~10/s so the
  closure isn't called millions of times) and a `shouldCancel` that forwards the flag.
- Classify each non-`.copied` outcome into `FailedItem`. The existing resume pre-check
  (dest-exists-and-matches → skip; dest-exists-and-differs → `.conflict`) is preserved.
- On cancel or completion, **still write the manifest** for verified files, so a later re-sync
  resumes (the central safety property — must be covered by a test).

## App — `AppState` sync activity

```swift
struct SyncActivity: Sendable {           // the observable snapshot the UI reads
    var driveName: String
    var stage: SyncProgress.Stage
    var bytesDone: Int64, bytesTotal: Int64
    var filesDone: Int, filesTotal: Int
    var currentName: String
    var speedBytesPerSec: Double           // EMA-smoothed
    var etaSeconds: Double?                 // nil until enough samples
    var phase: Phase                        // .running / .finished(SyncResult) / .cancelled(SyncResult)
}
```

- `var syncActivity: SyncActivity?` (Observable) + `private var syncTask: Task<Void, Never>?`
  + `private var syncCancelRequested = false`, plus a small `SyncRateMeter` (pure) holding the
  EMA + last sample for speed/ETA.
- `startSync(plan:drive:volume:)` — guards single-active-sync; resets the meter; stores
  `syncTask`; runs `engine.apply(shouldCancel: { self.syncCancelRequested }, progress:)`; the
  progress callback (on the main actor) feeds the meter and updates `syncActivity`. On return,
  sets `phase = .finished/.cancelled` with the `SyncResult`.
- `cancelSync()` — sets `syncCancelRequested = true` (engine stops within ~1 s).
- `retrySyncFailures(_ items: [PlanItem])` — builds a fresh `SyncPlan` from the selected failed
  items and calls `startSync` again (resume/skip means only those are re-attempted).
- `dismissSyncResult()` — clears `syncActivity` (closes the chip/report).
- Library close / app teardown cancels `syncTask` (safe + resumable), mirroring `derivationTask`.

**Speed/ETA (`SyncRateMeter`, pure + unit-tested):** on each progress sample
`(bytesDone, monotonicTime)`, compute instantaneous bytes/sec over the delta, fold into an EMA
(α≈0.2) so the number is stable; `eta = (bytesTotal - bytesDone) / max(emaSpeed, ε)`, surfaced
only after a few samples. Time comes from a passed-in clock (so it's testable without
`Date.now`).

## UI

**SyncPlanSheet** becomes a thin view over `state.syncActivity`:
- *Confirm phase* (no active sync): the existing plan preview + **Sync** button.
- *Running phase*: byte progress bar (`bytesDone/bytesTotal`), `"37.2 / 150 GB · 84 MB/s ·
  ~14 min left"`, `"copying IMG_1234.mov · 412 / 9,000 files"`, and **[Cancel] [Minimize]**.
  **Minimize** just `dismiss()`es (sync keeps running in AppState). **Cancel** → `cancelSync()`.
- *Finished phase*: if `failed` is empty → a brief success summary + **Done**. If there are
  failures → the **failure report** (below).

**Failure report** (in the sheet's finished phase):
- Header `"⚠︎ N of M files didn't sync"` + a **Thumbnails** toggle (off by default → a fast text
  list; on → a small crop per row from the thumbnail cache, keyed by `item.hash`).
- One row per `FailedItem`: a **checkbox** (default-on for `isRetryable`, off + disabled for
  `.conflict`), the **filename** (`destRelPath` lastPathComponent), and `reason.userText`.
- **[Retry N selected]** → `retrySyncFailures(selected)`. **[Done]** → `dismissSyncResult()`.

**Sidebar chip** (`SidebarView` footer, same region/style as the "Analyzing…" line): shown
whenever `syncActivity != nil`.
- Running → mini bar + `"Syncing · 37 / 150 GB · 84 MB/s"`.
- Finished-with-failures → `"Sync finished · 3 failed"` (amber).
- Clicking re-presents the sheet (drives a binding back in `DrivesView`) straight into the
  running/finished view.

## Error handling

- **Drive disconnected mid-sync**: the current file's copy throws → `.failed(.copyFailed)`;
  subsequent files also fail fast (dest unreachable) and are collected. The manifest write may
  itself fail (drive gone) — caught and logged; resume still works from what landed on disk.
- **Source missing** (deleted between plan and apply): `.failed(.sourceMissing)`.
- **Disk full**: `.failed(.copyFailed)` (the report says "copy failed — out of space" where the
  error is identifiable; otherwise generic "copy failed").
- **App quit while syncing**: `syncTask` cancelled on teardown → temp discarded → next launch
  re-sync resumes. No partial at any destination path (invariant).

## Testing (Core, TDD)

- **Streaming `VerifiedCopy`**: byte-correct copy of a multi-MB file; `onBytes` is monotonic and
  ends at file size; temp absent after success AND after failure/cancel; never overwrites an
  existing dest; **mid-stream `shouldCancel` returns `.cancelled` and leaves no temp**;
  corrupted source vs expectedHash → `.failed(.hashMismatch)`.
- **Streamed hash == `ContentHash.ofFile`** for the same bytes (digest parity).
- **`SyncEngine.apply`**: `bytesDone` rises to `bytesTotal` across a multi-file plan; cancel
  between files sets `cancelled` and **still writes the manifest** (existing resume test keeps
  passing); failures are classified with the right `reason`; conflicts (different file at dest)
  classified `.conflict`, not retried by default.
- **`SyncRateMeter`**: with a fake clock and synthetic byte samples, EMA speed is sane and ETA =
  remaining/speed; no ETA before warm-up.

UI (App) is build-verified + manually smoke-tested (no app test target), but every piece of
*logic* (copy, classification, rate meter) lives in tested Core functions.

## Reuse map

| Need | Reuse |
|------|-------|
| Cancellable background Task pattern | `AppState.derivationTask` / `pokeDerivation` |
| Sidebar footer progress slot | `SidebarView` "Analyzing…" line + `ActivityIndicatorView` |
| Per-file thumbnails | existing thumbnail cache / `ThumbnailImage` (key by `item.hash`) |
| Sheet presentation | `DrivesView` `.sheet(item: $syncDrive)` |
| Manifest / resume / never-overwrite | `SyncEngine.apply`, `Manifest`, `VerifiedCopy` (preserved) |
