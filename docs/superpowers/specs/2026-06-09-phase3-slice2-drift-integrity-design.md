# Phase 3 Slice 2 — Drift & Integrity: Design Spec

**Status:** Approved (2026-06-09). Detailed design for Phase 3 **Slice 2**, building on Slice 1 (the sync spine). Part of the Phase 3 roadmap in `docs/superpowers/specs/2026-06-09-phase3-drives-design.md` §4.

**One-line goal:** keep the backup *honest* — detect when a passive drive's real contents have drifted from OpenPhoto's record (files added/removed outside the app, or silent bit-rot), report it truthfully with recoverability, and offer only **non-destructive** repairs.

---

## 1. Why this slice exists

A canonical drive is **passive** — OpenPhoto never runs on it. So its contents can change behind the app's back: a file deleted in Finder on another machine, files written by other software (the future photo-server use case), or bytes silently rotting on aging media. Over time the drive's reality drifts from the manifest.

Slice 1's "backed up on canonical" badge trusts the *record*. Without verification the app could report a photo as safe when it's actually gone or corrupt — silent data loss. Slice 2 is the trust layer, and it is the **prerequisite for the destructive slices**: we must never evict the Mac's only other copy (Slice 4) unless we can be sure the drive really holds a good one.

**Hard reality this slice is built around:** a corrupted file can only be repaired from a *good copy of the same bytes* that exists somewhere reachable. If the only copy was the canonical drive and it rots — with the Mac evicted and the phone cleared — the photo is **permanently lost**. The defense is redundancy (multiple copies; the later clone→backup slice), and this slice is what knows, at any moment, **how many verified-good copies exist**.

## 2. Invariants (unchanged from `CLAUDE.md`)

- **Read-only detection; human-gated repair. No destructive auto-resolution.** Drift is surfaced for review; the user chooses.
- **Non-destructive only in this slice:** the only mutations are *additive* — adopt an unknown file into the manifest, or restore a missing file into an empty slot. Nothing is overwritten, moved, or removed. Replacing a corrupt/changed file (which means dealing with the bad file in place) is deferred to Slice 3.
- All writes atomic; all copies hash-verified (reuse Slice 1's copy-verify).
- The rebuildable **presence cache may auto-sync to observed reality** (so the badge never lies); the durable **manifest changes only through user-gated review**.

## 3. What "drift" is — the finding types

A `DriftFinding` describes one discrepancy between the drive's `manifest.jsonl` and its actual filesystem, drive-relative path:

| Kind | Meaning | Detected by | Found via |
|---|---|---|---|
| **unknown** | A media file on disk that the manifest doesn't list (added outside OpenPhoto). | existence | fast scan |
| **missing** | A path the manifest lists but that is gone from disk. | existence | fast scan |
| **changed** | A path present on disk whose **size or mtime** differs from the manifest (replaced/modified outside OpenPhoto). Its current identity is unknown without re-hashing. | size + mtime | fast scan |
| **corrupt** | A path present whose **size and mtime match** the manifest but whose **bytes don't hash to the recorded value** — silent bit-rot. | re-hash | Verify Integrity only |

`changed` and `corrupt` are the same shape ("the file at P is not what we recorded"); they differ only in whether the cheap check caught it. Both are **report-only** in this slice.

## 4. Two operations, one reconcile core

A new **`DriftReconciler`** (Core, drive-scoped — it never writes to the catalog's `instances`/timeline) reuses `Manifest`, `ContentHash`, `AtomicFile`, and `DriveVolume`:

### 4.1 Fast drift scan — `scan(drive:) -> DriftReport`
Walk the drive's media files once; compare against `Manifest.read`. Classify each into **unknown / missing / changed** by existence + `size` + `mtime` (the same fast-path fields the Scanner already uses, format §4). **No hashing.** Cheap enough to run automatically on every connect.

### 4.2 Verify Integrity — `verify(drive:progress:) -> DriftReport`
Re-hash **every** file on the drive and compare to the manifest. Produces everything the fast scan does **plus corrupt** (and definitively classifies `changed` files by their real hash). Slow (reads all bytes) → **explicit, user-initiated, with progress**. Emits a `DriftProgress` (mirrors `SyncProgress`).

```swift
public struct DriftFinding: Sendable, Equatable {
    public enum Kind: String, Sendable { case unknown, missing, changed, corrupt }
    public let kind: Kind
    public let relPath: String            // drive-relative
    public let recordedHash: String?      // manifest hash (missing/changed/corrupt)
    public let onDiskHash: String?        // re-hashed value (verify only; unknown after adopt)
    public let recordedSize: Int64?
    public let onDiskSize: Int64?
    public var recoverability: Recoverability = .unknown   // filled for missing/changed/corrupt
}

public struct DriftReport: Sendable, Equatable {
    public var unknown: [DriftFinding] = []
    public var missing: [DriftFinding] = []
    public var changed: [DriftFinding] = []
    public var corrupt: [DriftFinding] = []
    public var verified: Bool = false     // true if produced by a full re-hash
    public var isClean: Bool { unknown.isEmpty && missing.isEmpty && changed.isEmpty && corrupt.isEmpty }
}
```

## 5. Recoverability (the redundancy answer)

For every **missing / changed / corrupt** finding, the report says whether the *recorded* hash can be restored — i.e. whether a verified-good copy of those exact bytes exists on a currently-reachable vault. This reuses the Phase 2 `PresenceService`:

```swift
public enum Recoverability: Sendable, Equatable {
    case recoverable(source: String)   // a good copy exists (e.g. "This Mac", "Backup-SSD")
    case lostNoCopy                    // no good copy known anywhere → unrecoverable
    case unknown                       // not yet evaluated
}
```

- **recoverable** when the recorded hash has a confirmed location other than this drive — a local instance on the Mac (`catalog.instances(forHash:)`) or another connected drive's verified presence. The source name comes from `PresenceService.locations(forHash:)`.
- **lostNoCopy** when this drive was the only known home → the report says so plainly: *"⚠️ no good copy exists anywhere — this photo is lost."*

The same machinery powers an **early warning**: a photo whose only verified-good copy is the one on this drive is *"down to its last copy"* — surfaced so the user can make a backup *before* a failure, not after. (The eviction slice will consume this to refuse/​warn on single-copy eviction.)

## 6. Safe repairs (the only mutations in this slice)

Surfaced in a **drift-review sheet**; each action is explicit and user-confirmed. Restore/adopt reuse Slice 1's atomic copy→fsync→re-hash→verify helper (factored out of `SyncEngine.apply` into a shared `VerifiedCopy` so both call it).

| Finding | Action(s) | Effect | Why it's safe |
|---|---|---|---|
| **unknown** | **Adopt** | Hash the file, add a `manifest.jsonl` entry, add the hash to `vault_presence`. | Purely additive — records a file that's already there. |
| **missing** | **Restore from `<source>`** (only if `recoverable`) | Copy the good bytes from the source into the empty path, verify, add the manifest entry + presence back. | Additive — the slot is empty, nothing is overwritten. |
| **missing** | **Acknowledge gone** | Drop the manifest line + the presence entry. | Records reality for an already-absent file; deletes nothing. |
| **changed / corrupt** | **Report only** (with recoverability) | No file mutation. Drop the recorded hash from `vault_presence` so the badge stops claiming it's safe. | Resolving in place means overwrite/replace → deferred to Slice 3. |

"Adopt all" / "Restore all recoverable" bulk actions operate over a group; individual rows can also be actioned.

## 7. Presence honesty (badge can't lie)

Slice 1 populated `vault_presence` straight from the manifest. Slice 2 makes it **reality-checked**:

- On **connect**, the fast scan runs automatically and refreshes `vault_presence` to the set of manifest hashes whose files **actually exist with the expected size** (the rebuildable cache syncing to reality — non-destructive). Missing/changed files drop out immediately → the "backed up on canonical" badge corrects itself with no user action.
- **Verify Integrity** additionally removes **corrupt** hashes from presence (bytes failed verification).
- The manifest itself is *not* auto-edited; only the cache. Manifest changes happen through the review actions in §6.

(Presence in this slice means "present with the expected size, not known-corrupt." Tracking *verification recency* per copy — needed for strict single-copy eviction math — is noted for the eviction slice; no schema change here.)

## 8. UI

- **Drives row (extends Slice 1's `DrivesView`)**: after connect + fast scan, show a status line — *"✓ No changes"* or *"⚠️ N changes · Review"* — plus a **Verify Integrity** button (with a "last verified" date when known). "Check for changes" re-runs the fast scan on demand.
- **Drift-review sheet** (mirrors `SyncPlanSheet`): findings grouped by kind with counts; each row shows path + recoverability; group actions ("Adopt all unknown", "Restore all recoverable") and per-row actions; corrupt/lost rows are clearly flagged, not actionable here.
- **Verify Integrity** → progress sheet (re-hashing N files) → presents the enriched report in the same review UI.

## 9. Where the code lives

- **Create** `Sources/OpenPhotoCore/Sync/DriftReconciler.swift` — `scan`, `verify`, recoverability annotation (takes a `PresenceService`), and the repair operations `adopt`, `restore(from:)`, `acknowledgeGone` (each updating manifest + presence atomically).
- **Create** `Sources/OpenPhotoCore/Sync/DriftReport.swift` — the value types (`DriftFinding`, `DriftReport`, `Recoverability`, `DriftProgress`).
- **Refactor** `Sources/OpenPhotoCore/Sync/SyncEngine.swift` — extract the per-item copy→fsync→re-hash→verify block into a shared `VerifiedCopy.copy(from:to:expectedHash:)` used by both `apply` and `DriftReconciler.restore`. (DRY; no behavior change to Slice 1, re-run its tests.)
- **Catalog**: add `func reconcileVaultPresence(vaultID:presentHashes:)` if a finer update than `replaceVaultPresence` is wanted; otherwise reuse `replaceVaultPresence`. No new tables.
- **App**: extend `DrivesView` (status + buttons), add `DriftReviewSheet.swift`; `AppState` gains `driftScan(_)`, `verifyIntegrity(_)`, and the repair calls, refreshing `canonicalPresence` after.

## 10. Testing (TDD, Swift Testing, generated fixtures only)

Core scenario tests on temp-dir vaults with **injected drift**:
- delete a manifest-listed file → **missing**; add a stray media file → **unknown**; change a file's bytes keeping size+mtime → **corrupt** (caught only by `verify`, not `scan`); change a file's size → **changed**.
- recoverability: a missing hash that also exists in a local vault → `recoverable(source: "This Mac")`; one that exists nowhere → `lostNoCopy`.
- repairs: **adopt** adds the manifest line + presence; **restore** copies verified bytes into the empty slot and re-adds the record; **acknowledge gone** drops the line; corrupt is report-only and drops from presence.
- presence honesty: after a fast scan, a missing file's hash is absent from `vault_presence`; after verify, a corrupt hash is absent.
- `VerifiedCopy` refactor: Slice 1's full `SyncApplyTests` still pass unchanged.
- Tier-2: optional exFAT `.dmg` verify pass (reuse Slice 1's harness).

## 11. Out of scope (later slices)

In-place replacement of a corrupt/changed file (overwrite-restore or move-to-bin); moving anything to the drive's `.openphoto-trash/`; deletion propagation; explicit Verify Integrity for *local* vaults (already scanned at launch); rename auto-detection (matching a `changed`/`unknown` hash to a `missing` one); per-copy verification-recency tracking for strict eviction math.

## 12. Milestones

- **M0 — `VerifiedCopy` refactor** out of `SyncEngine`; Slice 1 tests green.
- **M1 — Fast scan**: `DriftReconciler.scan` → `DriftReport` (unknown/missing/changed); reality-checked `vault_presence` refresh on connect.
- **M2 — Recoverability + repairs**: `PresenceService`-driven recoverability annotation; `adopt` / `restore` / `acknowledgeGone`.
- **M3 — Verify Integrity**: full re-hash with progress → corrupt findings + presence correction.
- **M4 — UI**: `DrivesView` status + Verify button; `DriftReviewSheet`; `AppState` wiring + badge refresh.
