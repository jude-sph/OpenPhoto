# Phase 3 Slice 3 — Deletion Propagation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a photo deleted on the Mac have its lingering copy on the canonical drive moved into the drive's bin — reviewed, reversible, never hard-deleted.

**Architecture:** A dedicated Delete-only queue in the catalog (`pending_deletions`) records true deletions (Evict records nothing). A pure `DeletionPropagator.eligible(...)` decides what may propagate to a given drive (queued ∧ no-local-instance ∧ on-drive, computed at review time); `propagate(...)` performs the destructive step by reusing `BinStore` on the drive vault (`origin: .propagated`), then rewrites the drive manifest atomically and updates presence/queue/sync-log. Two UI surfaces (a standalone `DeletionReviewSheet` and a Sync-plan section) share one `DeletionListView` and one `AppState.propagateDeletions` path.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (CLT only), GRDB SQLite, Swift Testing (`@Test`/`#expect`).

**Conventions (every task):**
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit.
- **Generated mock media only** — never touch `~/Pictures`, `~/Movies`, or any personal folder. Use `TestDirs` (system temp), `makeJPEG`, `t.file(...)`.
- **Zero compiler warnings:** `swift build 2>&1 | grep -i warning` must print nothing.
- Each commit message ends with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Branch: continue on `phase3-drives` (do not start on `main`).

**Existing building blocks (do not reinvent):**
- `BinStore(vault:).moveToBin(relPath:hash:origin:)` / `.restore(relPath:)` / `.list()` — `Sources/OpenPhotoCore/Vault/BinStore.swift`. `origin` is `.user | .propagated`.
- `Manifest.read(from:)` / `Manifest.write(_:to:)` (atomic) — `Sources/OpenPhotoCore/Vault/Manifest.swift`. `ManifestEntry{hash: ContentHash, path, size, mtime}`.
- `Vault` URLs: `manifestURL`, `syncLogURL`, `binDirURL`, `binLogURL`, `absoluteURL(forRelativePath:)`, `descriptor.vaultID`, `rootURL`. `Vault` is `Identifiable` (`id == descriptor.vaultID`).
- `VaultPresenceEntry{hash, relPath, dirPath, size, driveRelPath}`; `Catalog.vaultPresenceRows(forVault:)`, `replaceVaultPresence(vaultID:entries:)`, `vaultPresenceHashes(forVault:)`.
- `Catalog.instanceItem(hash:vaultID:) -> InstanceRecord?`.
- `AppState`: `canonicalVaults`, `driveIsPresent(_)`, `openVault(for:) -> Vault?`, `driftScan(_)`, `refreshQueries()`, `autoScanConnectedDrives()`, `refreshCanonicalPresence(driveVault:)`, `driveDrift` cache pattern.
- `ThumbnailStore.cachedDisplayImage(for: ContentHash, maxPixel:) async -> CGImage?` (cache-only — works with the original gone / drive unplugged).
- `ISO8601Millis.string(from: Date())`; `AtomicFile.write(_:to:)`.

---

## File Structure

**Core (`Sources/OpenPhotoCore/`)**
- `Catalog/Catalog.swift` — *modify*: migration `v4` (`pending_deletions`), queue CRUD, `instanceHashes()`, `removeVaultPresence(vaultID:hashes:)`, `assetLivePairHash(forHash:)`.
- `Catalog/PendingDeletion.swift` — *create*: `PendingDeletionRecord` value type.
- `Sync/SyncLog.swift` — *create*: tiny shared sync-log appender (DRY for `LibraryService` + propagator).
- `Sync/DeletionPropagator.swift` — *create*: `PendingDeletion`, `eligible(...)`, `propagate(...)`.
- `LibraryService.swift` — *modify*: `delete` enqueues (+pair), `restore` dequeues (+pair); `appendSyncLog` delegates to `SyncLog`.

**App (`Sources/OpenPhotoApp/`)**
- `AppState.swift` — *modify*: `drivePendingDeletions` cache, `refreshPendingDeletions()`, `propagateDeletions(drive:selected:)`, `restorePending(_)`; hook refresh into `refreshQueries()` + `autoScanConnectedDrives()`.
- `Drives/DeletionListView.swift` — *create*: shared thumbnailed, selectable list (Select-All + per-row Restore).
- `Drives/DeletionReviewSheet.swift` — *create*: standalone review gate.
- `Drives/DrivesView.swift` — *modify*: pending-deletions indicator + `.sheet(item:)`.
- `Drives/SyncPlanSheet.swift` — *modify*: Deletions section.

**Tests (`Tests/OpenPhotoCoreTests/`)**
- `PendingDeletionsTests.swift`, `DeletionPropagatorTests.swift`, `SyncLogTests.swift` — *create*.
- `LibraryServiceTests.swift` — *modify* (enqueue/dequeue/evict-clean).

**Docs**
- `docs/format/vault-format-v1.md` — *modify* (§8 clarify, §9 add `"delete"`), in the **same commit** as the propagator (Task 12).
- `docs/superpowers/specs/2026-06-09-phase3-drives-design.md`, `docs/superpowers/specs/2026-06-07-openphoto-design.md` — *modify* (Task 16).

---

## M1 — Catalog queue

### Task 1: `pending_deletions` table + record + queue CRUD

**Files:**
- Create: `Sources/OpenPhotoCore/Catalog/PendingDeletion.swift`
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Test: `Tests/OpenPhotoCoreTests/PendingDeletionsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/PendingDeletionsTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func enqueueDequeueAndListRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let h2 = "sha256:" + String(repeating: "2", count: 64)

    try cat.enqueuePendingDeletion(hash: h1, relPath: "rome/IMG_1.jpg", deletedAtMs: 100)
    try cat.enqueuePendingDeletion(hash: h2, relPath: "paris/IMG_2.jpg", deletedAtMs: 200)
    // Re-enqueue same hash updates, never duplicates (PK = hash).
    try cat.enqueuePendingDeletion(hash: h1, relPath: "rome/IMG_1.jpg", deletedAtMs: 150)

    let all = try cat.pendingDeletions()
    #expect(all.count == 2)
    #expect(all.first?.hash == h2)                 // newest (deletedAtMs DESC)
    #expect(all.first(where: { $0.hash == h1 })?.deletedAtMs == 150)

    try cat.dequeuePendingDeletion(hash: h1)
    #expect(try cat.pendingDeletions().map(\.hash) == [h2])

    try cat.clearPendingDeletions(hashes: [h2])
    #expect(try cat.pendingDeletions().isEmpty)
    // Empty input is a no-op, never an error.
    try cat.clearPendingDeletions(hashes: [])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter enqueueDequeueAndListRoundTrip`
Expected: FAIL — `value of type 'Catalog' has no member 'enqueuePendingDeletion'`.

- [ ] **Step 3: Create the record type**

Create `Sources/OpenPhotoCore/Catalog/PendingDeletion.swift`:

```swift
import Foundation

/// One queued local deletion awaiting review for propagation to a drive.
/// Rebuildable-cache semantics (lives in the catalog); a wiped catalog forgets
/// pending intents — a safe failure (the drive simply keeps its copy).
public struct PendingDeletionRecord: Sendable, Equatable {
    public let hash: String        // content identity; join key vs instances + vault_presence
    public let relPath: String     // Mac-aligned path, display only
    public let deletedAtMs: Int64
    public init(hash: String, relPath: String, deletedAtMs: Int64) {
        self.hash = hash; self.relPath = relPath; self.deletedAtMs = deletedAtMs
    }
}
```

- [ ] **Step 4: Add migration `v4` + CRUD to `Catalog`**

In `Sources/OpenPhotoCore/Catalog/Catalog.swift`, register migration `v4` immediately after the `v3` block (before `try migrator.migrate(dbQueue)`):

```swift
        migrator.registerMigration("v4") { db in
            // Delete-only propagation queue (rebuildable cache). Evict never writes here.
            try db.create(table: "pending_deletions") { t in
                t.primaryKey("hash", .text)
                t.column("relPath", .text).notNull()
                t.column("deletedAtMs", .integer).notNull()
            }
        }
```

Add these methods to `Catalog` (e.g. after `vaultPresenceHashes(forVault:)`):

```swift
    // MARK: Pending deletions (Slice 3 — Delete-only queue)

    public func enqueuePendingDeletion(hash: String, relPath: String, deletedAtMs: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_deletions (hash, relPath, deletedAtMs) VALUES (?, ?, ?)
                ON CONFLICT(hash) DO UPDATE SET relPath = excluded.relPath,
                                                deletedAtMs = excluded.deletedAtMs
                """, arguments: [hash, relPath, deletedAtMs])
        }
    }

    public func dequeuePendingDeletion(hash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_deletions WHERE hash = ?", arguments: [hash])
        }
    }

    public func clearPendingDeletions(hashes: [String]) throws {
        guard !hashes.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            try db.execute(sql: "DELETE FROM pending_deletions WHERE hash IN (\(marks))",
                           arguments: StatementArguments(hashes))
        }
    }

    public func pendingDeletions() throws -> [PendingDeletionRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, relPath, deletedAtMs FROM pending_deletions ORDER BY deletedAtMs DESC
                """).map {
                PendingDeletionRecord(hash: $0["hash"], relPath: $0["relPath"],
                                      deletedAtMs: $0["deletedAtMs"])
            }
        }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter enqueueDequeueAndListRoundTrip`
Expected: PASS.

- [ ] **Step 6: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/PendingDeletion.swift \
        Sources/OpenPhotoCore/Catalog/Catalog.swift \
        Tests/OpenPhotoCoreTests/PendingDeletionsTests.swift
git commit -m "feat(catalog): pending_deletions queue (migration v4) + CRUD

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Eligibility-support accessors — `instanceHashes`, `removeVaultPresence`, `assetLivePairHash`

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Test: `Tests/OpenPhotoCoreTests/PendingDeletionsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/PendingDeletionsTests.swift`:

```swift
@Test func eligibilitySupportAccessors() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "mac", role: "local", rootPath: "/p")
    let still = "sha256:" + String(format: "%064d", 1)
    let video = "sha256:" + String(format: "%064d", 2)
    var photo = AssetRecord(hash: still, kind: "photo", takenAtMs: 0, pixelWidth: 1, pixelHeight: 1,
                            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                            durationSeconds: nil, livePairHash: video, isLivePairedVideo: false,
                            favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    try cat.upsert(assets: [photo])
    try cat.upsert(instances: [InstanceRecord(hash: still, vaultID: "mac",
        relPath: "a/I.heic", dirPath: "a", size: 1, mtimeMs: 0)])

    #expect(try cat.instanceHashes() == [still])
    #expect(try cat.assetLivePairHash(forHash: still) == video)
    #expect(try cat.assetLivePairHash(forHash: video) == nil)

    // removeVaultPresence is targeted by (vaultID, hash) and no-ops on empty.
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: still, relPath: "a/I.heic", dirPath: "a", size: 1, driveRelPath: "Pictures/a/I.heic"),
        VaultPresenceEntry(hash: video, relPath: "a/I.mov", dirPath: "a", size: 1, driveRelPath: "Pictures/a/I.mov"),
    ])
    try cat.removeVaultPresence(vaultID: "drive", hashes: [still])
    #expect(try cat.vaultPresenceHashes(forVault: "drive") == [video])
    try cat.removeVaultPresence(vaultID: "drive", hashes: [])   // no-op
    #expect(try cat.vaultPresenceHashes(forVault: "drive") == [video])
    _ = photo
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter eligibilitySupportAccessors`
Expected: FAIL — `Catalog` has no member `instanceHashes`.

- [ ] **Step 3: Add the accessors to `Catalog`**

In `Sources/OpenPhotoCore/Catalog/Catalog.swift`, after the pending-deletions methods:

```swift
    /// Distinct hashes that have a LOCAL instance (drive presence lives in vault_presence,
    /// never in `instances`). Used by deletion eligibility's "no local copy remains" rule.
    public func instanceHashes() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT hash FROM instances"))
        }
    }

    /// The paired-video hash for a Live Photo still (nil otherwise) — lets restore mirror
    /// the dequeue onto the pair.
    public func assetLivePairHash(forHash hash: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT livePairHash FROM assets WHERE hash = ?",
                                arguments: [hash])
        }
    }

    /// Drop specific hashes from one vault's presence mirror (after they're propagated off it).
    public func removeVaultPresence(vaultID: String, hashes: [String]) throws {
        guard !hashes.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ? AND hash IN (\(marks))",
                           arguments: StatementArguments([vaultID] + hashes))
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter eligibilitySupportAccessors`
Expected: PASS.

- [ ] **Step 5: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift \
        Tests/OpenPhotoCoreTests/PendingDeletionsTests.swift
git commit -m "feat(catalog): instanceHashes, removeVaultPresence, assetLivePairHash accessors

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M2 — Enqueue / dequeue wiring (Delete-only)

### Task 3: `LibraryService.delete` enqueues (still + Live pair)

**Files:**
- Modify: `Sources/OpenPhotoCore/LibraryService.swift:221-232`
- Test: `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`:

```swift
@Test func deleteEnqueuesPendingDeletion() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)

    try await lib.delete(item)

    let queued = try lib.catalog.pendingDeletions()
    #expect(queued.map(\.hash) == [item.hash])
    #expect(queued.first?.relPath == "rome/IMG_1.jpg")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter deleteEnqueuesPendingDeletion`
Expected: FAIL — `pendingDeletions()` returns empty (delete doesn't enqueue yet).

- [ ] **Step 3: Make `delete` enqueue**

In `Sources/OpenPhotoCore/LibraryService.swift`, replace the body of `delete(_:)` (currently lines ~221-232):

```swift
    public func delete(_ item: TimelineItem) async throws {
        guard let bin = binStores[item.vaultID] else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try bin.moveToBin(relPath: item.relPath,
                          hash: ContentHash(stringValue: item.hash), origin: .user)
        try catalog.enqueuePendingDeletion(hash: item.hash, relPath: item.relPath, deletedAtMs: nowMs)
        // If this is a Live Photo, the paired video goes too — and is queued too.
        if let pairHash = item.livePairHash,
           let pairInstance = try catalog.instanceItem(hash: pairHash, vaultID: item.vaultID) {
            try bin.moveToBin(relPath: pairInstance.relPath,
                              hash: ContentHash(stringValue: pairHash), origin: .user)
            try catalog.enqueuePendingDeletion(hash: pairHash, relPath: pairInstance.relPath,
                                               deletedAtMs: nowMs)
        }
        try await rescan(vaultID: item.vaultID)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter deleteEnqueuesPendingDeletion`
Expected: PASS.

- [ ] **Step 5: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService.swift Tests/OpenPhotoCoreTests/LibraryServiceTests.swift
git commit -m "feat(library): delete enqueues a pending deletion (still + Live pair)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `LibraryService.restore` dequeues (+ Live pair)

**Files:**
- Modify: `Sources/OpenPhotoCore/LibraryService.swift:271-274`
- Test: `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`:

```swift
@Test func restoreDequeuesPendingDeletion() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    try await lib.delete(item)
    let entry = try #require(try lib.binItems().first)

    try await lib.restore(entry)

    #expect(try lib.catalog.pendingDeletions().isEmpty)   // undeleting cancels the propagation
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter restoreDequeuesPendingDeletion`
Expected: FAIL — the queue still contains the entry (restore doesn't dequeue yet).

- [ ] **Step 3: Make `restore` dequeue**

In `Sources/OpenPhotoCore/LibraryService.swift`, replace `restore(_:)`:

```swift
    public func restore(_ entry: BinEntry) async throws {
        try binStores[entry.vaultID]?.restore(relPath: entry.item.path)
        try catalog.dequeuePendingDeletion(hash: entry.item.hash)
        // Mirror the dequeue onto a Live pair (favor not-deleting: a restored still
        // should not leave its video queued to propagate alone).
        if let pair = try catalog.assetLivePairHash(forHash: entry.item.hash) {
            try catalog.dequeuePendingDeletion(hash: pair)
        }
        try await rescan(vaultID: entry.vaultID)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter restoreDequeuesPendingDeletion`
Expected: PASS.

- [ ] **Step 5: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService.swift Tests/OpenPhotoCoreTests/LibraryServiceTests.swift
git commit -m "feat(library): restore dequeues the pending deletion (+ Live pair)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Evict leaves the queue empty (the gotcha guard)

**Files:**
- Test: `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`

This is a **test-only** task — `evict` already never enqueues; this locks that property so a future change can't silently make eviction delete from drives.

- [ ] **Step 1: Write the test**

Append to `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`:

```swift
@Test func evictDoesNotEnqueuePendingDeletion() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)

    _ = try await lib.evict([item])

    // Evict releases the local copy but must NEVER propose deleting the drive copy.
    #expect(try lib.catalog.pendingDeletions().isEmpty)
}
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `swift test --filter evictDoesNotEnqueuePendingDeletion`
Expected: PASS (evict already doesn't enqueue). If it FAILS, evict was wrongly enqueuing — stop and fix `evict` to not call `enqueuePendingDeletion`.

- [ ] **Step 3: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add Tests/OpenPhotoCoreTests/LibraryServiceTests.swift
git commit -m "test(library): evict never enqueues a pending deletion (delete-only guard)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M3 — Propagator + normative format

### Task 6: `SyncLog` shared appender (DRY)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/SyncLog.swift`
- Modify: `Sources/OpenPhotoCore/LibraryService.swift:296-309` (delegate)
- Test: `Tests/OpenPhotoCoreTests/SyncLogTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/SyncLogTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func syncLogAppendsOneJSONLineWithRequiredKeys() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)

    SyncLog.append(event: "delete", summary: "3 propagated to drive bin",
                   counterparty: "mac-1", to: drive.syncLogURL)
    SyncLog.append(event: "sync", summary: "ok", counterparty: "", to: drive.syncLogURL)

    let lines = (try Data(contentsOf: drive.syncLogURL))
        .split(separator: 0x0A).filter { !$0.isEmpty }
    #expect(lines.count == 2)
    let first = try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any]
    #expect(first?["event"] as? String == "delete")
    #expect(first?["counterparty_vault_id"] as? String == "mac-1")
    #expect((first?["at"] as? String)?.isEmpty == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter syncLogAppendsOneJSONLineWithRequiredKeys`
Expected: FAIL — `cannot find 'SyncLog' in scope`.

- [ ] **Step 3: Create `SyncLog`**

Create `Sources/OpenPhotoCore/Sync/SyncLog.swift`:

```swift
import Foundation

/// Append-only sync-log writer (format §9, informative). One JSON object per line.
public enum SyncLog {
    public static func append(event: String, summary: String, counterparty: String, to url: URL) {
        let line: [String: Any] = ["event": event,
                                   "at": ISO8601Millis.string(from: Date()),
                                   "counterparty_vault_id": counterparty,
                                   "summary": summary]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else { return }
        var existing = (try? Data(contentsOf: url)) ?? Data()
        existing.append(data); existing.append(0x0A)
        try? AtomicFile.write(existing, to: url)
    }
}
```

- [ ] **Step 4: Delegate `LibraryService.appendSyncLog` to it (DRY)**

In `Sources/OpenPhotoCore/LibraryService.swift`, replace the body of `appendSyncLog(vault:event:summary:counterpartyKey:)`:

```swift
    /// Append an event to the vault's sync-log.jsonl (format §9, informative).
    public func appendSyncLog(vault: Vault, event: String, summary: String,
                              counterpartyKey: String) {
        SyncLog.append(event: event, summary: summary,
                       counterparty: counterpartyKey, to: vault.syncLogURL)
    }
```

- [ ] **Step 5: Run tests to verify (new passes, old still green)**

Run: `swift test --filter syncLogAppendsOneJSONLineWithRequiredKeys`
Expected: PASS.
Run: `swift test --filter SyncApply`
Expected: PASS (the existing sync-log assertions still hold).

- [ ] **Step 6: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/SyncLog.swift Sources/OpenPhotoCore/LibraryService.swift \
        Tests/OpenPhotoCoreTests/SyncLogTests.swift
git commit -m "refactor(core): extract SyncLog appender; LibraryService delegates to it

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `DeletionPropagator.eligible` (pure)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`
- Test: `Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift`

- [ ] **Step 1: Write the failing test (the full eligibility matrix)**

Create `Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func presence(_ hash: String, _ drivePath: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: hash, relPath: drivePath, dirPath: "x", size: 1, driveRelPath: drivePath)
}

@Test func eligibleAppliesTheThreePartRule() {
    let onMac    = "sha256:" + String(format: "%064d", 1)   // deleted but a duplicate local copy remains
    let gone     = "sha256:" + String(format: "%064d", 2)   // deleted, no local copy, on drive  → ELIGIBLE
    let notDrive = "sha256:" + String(format: "%064d", 3)   // deleted, no local copy, NOT on drive
    let q: [PendingDeletionRecord] = [
        .init(hash: onMac, relPath: "a/1.jpg", deletedAtMs: 1),
        .init(hash: gone, relPath: "a/2.jpg", deletedAtMs: 2),
        .init(hash: notDrive, relPath: "a/3.jpg", deletedAtMs: 3),
    ]
    let local: Set<String> = [onMac]                              // only onMac still has a local instance
    let pres = [presence(onMac, "P/a/1.jpg"), presence(gone, "P/a/2.jpg")]

    let result = DeletionPropagator().eligible(queue: q, localHashes: local, presence: pres)

    #expect(result.map(\.hash) == [gone])
    #expect(result.first?.driveRelPath == "P/a/2.jpg")
}

@Test func eligibleEmptyWhenQueueEmptyOrNothingOnDrive() {
    let h = "sha256:" + String(format: "%064d", 9)
    #expect(DeletionPropagator().eligible(queue: [], localHashes: [], presence: [presence(h, "p")]).isEmpty)
    #expect(DeletionPropagator().eligible(
        queue: [.init(hash: h, relPath: "a", deletedAtMs: 1)],
        localHashes: [], presence: []).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter eligibleAppliesTheThreePartRule`
Expected: FAIL — `cannot find 'DeletionPropagator' in scope`.

- [ ] **Step 3: Create `DeletionPropagator` with the pure `eligible`**

Create `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`:

```swift
import Foundation

/// A queued deletion resolved against a specific drive, ready to propagate.
public struct PendingDeletion: Sendable, Equatable {
    public let hash: String
    public let relPath: String        // Mac-aligned, for display
    public let driveRelPath: String   // path on the drive (the copy to bin)
    public let size: Int64
    public let deletedAtMs: Int64
    public init(hash: String, relPath: String, driveRelPath: String, size: Int64, deletedAtMs: Int64) {
        self.hash = hash; self.relPath = relPath; self.driveRelPath = driveRelPath
        self.size = size; self.deletedAtMs = deletedAtMs
    }
}

/// Slice 3 — moves locally-deleted photos' drive copies into the drive's bin.
public struct DeletionPropagator: Sendable {
    public init() {}

    public struct Result: Sendable, Equatable {
        public var propagated: Int    // copies actually moved to the drive bin
        public var skipped: Int       // already gone on the drive (still cleared from queue/presence)
        public var failed: Int        // move failed — left queued for retry
        public init(propagated: Int = 0, skipped: Int = 0, failed: Int = 0) {
            self.propagated = propagated; self.skipped = skipped; self.failed = failed
        }
    }

    /// Pure eligibility: queued ∧ no-local-instance ∧ on-drive. Resolves drive path/size
    /// from the drive's presence mirror. No I/O.
    public func eligible(queue: [PendingDeletionRecord],
                         localHashes: Set<String>,
                         presence: [VaultPresenceEntry]) -> [PendingDeletion] {
        let byHash = Dictionary(presence.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        return queue.compactMap { rec in
            guard !localHashes.contains(rec.hash), let p = byHash[rec.hash] else { return nil }
            return PendingDeletion(hash: rec.hash, relPath: p.relPath, driveRelPath: p.driveRelPath,
                                   size: p.size, deletedAtMs: rec.deletedAtMs)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter eligible`
Expected: PASS (both eligibility tests).

- [ ] **Step 5: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/DeletionPropagator.swift \
        Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift
git commit -m "feat(sync): DeletionPropagator.eligible — pure queued∧no-local∧on-drive rule

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: `DeletionPropagator.propagate` (the destructive step) + format docs

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`
- Modify: `docs/format/vault-format-v1.md` (§8 clarify, §9 add `"delete"`) — **same commit**
- Test: `Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift`

- [ ] **Step 1: Write the failing integration test**

Append to `Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift`:

```swift
@Test func propagateMovesDriveCopyToBinAndUpdatesEverything() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)

    // A file present on the drive, recorded in manifest + presence + queue.
    let drivePath = "Pictures/rome/IMG_1.jpg"
    let onDrive = drive.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: onDrive.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("photo".utf8).write(to: onDrive)
    let hash = "sha256:" + String(repeating: "a", count: 64)
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath,
                                      size: 5, mtime: "2022-10-07T14:23:01.000Z")], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 5, driveRelPath: drivePath)])
    try cat.enqueuePendingDeletion(hash: hash, relPath: "rome/IMG_1.jpg", deletedAtMs: 1)

    let entries = DeletionPropagator().eligible(
        queue: try cat.pendingDeletions(), localHashes: try cat.instanceHashes(),
        presence: try cat.vaultPresenceRows(forVault: drive.descriptor.vaultID))
    let result = try DeletionPropagator().propagate(drive: drive, entries: entries,
                                                    macVaultID: "mac-1", catalog: cat)

    #expect(result == .init(propagated: 1, skipped: 0, failed: 0))
    #expect(!FileManager.default.fileExists(atPath: onDrive.path))                  // original gone
    let binned = drive.rootURL.appendingPathComponent(".openphoto/bin/").appendingPathComponent(drivePath)
    #expect(FileManager.default.fileExists(atPath: binned.path))                    // in drive bin
    let log = try BinStore(vault: drive).list()
    #expect(log.first?.origin == .propagated)                                       // origin: propagated
    #expect(try Manifest.read(from: drive.manifestURL).isEmpty)                     // manifest line removed
    #expect(try cat.vaultPresenceHashes(forVault: drive.descriptor.vaultID).isEmpty)// presence cleared
    #expect(try cat.pendingDeletions().isEmpty)                                     // queue cleared
    let synced = String(data: try Data(contentsOf: drive.syncLogURL), encoding: .utf8) ?? ""
    #expect(synced.contains("\"delete\""))                                          // sync-log event
}

@Test func propagateIsIdempotentWhenDriveCopyAlreadyGone() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    let hash = "sha256:" + String(repeating: "b", count: 64)
    // Presence/queue say it's there, but the file is already gone (e.g. binned earlier).
    let e = PendingDeletion(hash: hash, relPath: "a/x.jpg", driveRelPath: "Pictures/a/x.jpg",
                            size: 1, deletedAtMs: 1)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: hash, relPath: "a/x.jpg", dirPath: "a", size: 1, driveRelPath: "Pictures/a/x.jpg")])
    try cat.enqueuePendingDeletion(hash: hash, relPath: "a/x.jpg", deletedAtMs: 1)

    let result = try DeletionPropagator().propagate(drive: drive, entries: [e],
                                                    macVaultID: "mac-1", catalog: cat)

    #expect(result == .init(propagated: 0, skipped: 1, failed: 0))     // counted gone, not fatal
    #expect(try cat.pendingDeletions().isEmpty)                        // still cleared (goal state reached)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter propagateMovesDriveCopyToBinAndUpdatesEverything`
Expected: FAIL — `DeletionPropagator` has no member `propagate`.

- [ ] **Step 3: Implement `propagate`**

In `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`, add to `DeletionPropagator`:

```swift
    /// Destructive: move each drive copy into the drive's bin (origin: propagated), then one
    /// atomic manifest rewrite, then update presence + queue + sync-log. A copy already gone is
    /// counted `skipped` but still cleared (goal state reached); a genuine move failure is left
    /// queued for retry. Files move first (each recoverable in the bin), so an interruption before
    /// the manifest rewrite self-heals as a recoverable `missing` drift on the next scan.
    @discardableResult
    public func propagate(drive: Vault, entries: [PendingDeletion],
                          macVaultID: String, catalog: Catalog) throws -> Result {
        guard !entries.isEmpty else { return Result() }
        let bin = BinStore(vault: drive)
        let fm = FileManager.default
        var clearedHashes: [String] = []          // removed from drive (moved OR already gone)
        var clearedDrivePaths = Set<String>()
        var moved = 0, skipped = 0, failed = 0

        for e in entries {
            let src = drive.absoluteURL(forRelativePath: e.driveRelPath)
            if !fm.fileExists(atPath: src.path) {
                skipped += 1
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath)
                continue
            }
            do {
                try bin.moveToBin(relPath: e.driveRelPath,
                                  hash: ContentHash(stringValue: e.hash), origin: .propagated)
                moved += 1
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath)
            } catch {
                failed += 1   // leave queued; do not clear
            }
        }

        // One atomic manifest rewrite dropping every cleared path.
        let remaining = try Manifest.read(from: drive.manifestURL)
            .filter { !clearedDrivePaths.contains($0.path) }
        try Manifest.write(remaining, to: drive.manifestURL)

        try catalog.removeVaultPresence(vaultID: drive.descriptor.vaultID, hashes: clearedHashes)
        try catalog.clearPendingDeletions(hashes: clearedHashes)

        if moved > 0 {
            SyncLog.append(event: "delete", summary: "\(moved) propagated to drive bin",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return Result(propagated: moved, skipped: skipped, failed: failed)
    }
```

- [ ] **Step 4: Update the format doc (same commit)**

In `docs/format/vault-format-v1.md`, in **§8** add a clarifying sentence after the `origin` paragraph (after the line ending `Restore = the reverse move + manifest line re-added.`):

```markdown
A *vault's* propagated deletions therefore land in that vault's own `.openphoto/bin/` (the same mechanism as a local deletion), tagged `origin:"propagated"`. The volume-root `.openphoto-trash/` directory of §12 is used **only** for deletions on removable *non-vault* volumes (e.g. an SD card during import), which have no `.openphoto/` vault to host a bin.
```

In **§9**, add `"delete"` to the event-name list. Change:

```markdown
Event names include `"import"`, `"device-delete"`, `"send"`, `"sync"`, `"clone"`, `"evict"`.
```
to:
```markdown
Event names include `"import"`, `"device-delete"`, `"send"`, `"sync"`, `"clone"`, `"evict"`, `"delete"` (a reviewed deletion propagated to this vault's bin).
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter propagate`
Expected: PASS (both propagate tests).

- [ ] **Step 6: Verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 7: Commit (code + normative format together — sovereignty discipline)**

```bash
git add Sources/OpenPhotoCore/Sync/DeletionPropagator.swift \
        Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift \
        docs/format/vault-format-v1.md
git commit -m "feat(sync): DeletionPropagator.propagate to drive bin + format §8/§9

Moves locally-deleted photos' drive copies into the drive's .openphoto/bin
(origin: propagated), atomic manifest rewrite, presence/queue/sync-log update.
Idempotent; failures stay queued. Updates vault-format-v1 §8 (vault bin for
propagated deletions) and §9 (the 'delete' event) in the same commit.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M4 — App + UI

> App-layer tasks are **build-verified + manually checked** (SwiftUI views and `@MainActor AppState` aren't unit-tested in this codebase — matching Slices 1/2/2.5). The correctness-critical logic is already covered by the Core tests above. After each task: `swift build 2>&1 | grep -i warning` must be empty, and `swift build` must succeed.

### Task 9: `AppState` pending-deletions cache + refresh

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add the cache + refresh method**

In `Sources/OpenPhotoApp/AppState.swift`, near `driveDrift` (around line 302) add:

```swift
    /// Eligible pending deletions per connected drive (vaultID → entries). Drives the row
    /// indicator + both review surfaces. Recomputed on connect, after any delete/restore/evict
    /// (via refreshQueries), after sync, and after propagation.
    private(set) var drivePendingDeletions: [String: [PendingDeletion]] = [:]

    func refreshPendingDeletions() {
        guard let lib = library else { drivePendingDeletions = [:]; return }
        let queue = (try? lib.catalog.pendingDeletions()) ?? []
        let local = (try? lib.catalog.instanceHashes()) ?? []
        var out: [String: [PendingDeletion]] = [:]
        for vr in canonicalVaults where driveIsPresent(vr) {
            let presence = (try? lib.catalog.vaultPresenceRows(forVault: vr.id)) ?? []
            let eligible = DeletionPropagator().eligible(queue: queue, localHashes: local, presence: presence)
            if !eligible.isEmpty { out[vr.id] = eligible }
        }
        drivePendingDeletions = out
    }
```

- [ ] **Step 2: Hook the refresh into the existing refresh paths**

In `refreshQueries()` (around line 498), add the call just before `refreshToken += 1`:

```swift
        binEntries = try library.binItems()
        refreshPendingDeletions()
        refreshToken += 1
```

In `autoScanConnectedDrives()` (around line 357), add the call right after the final `reloadCanonicalPresence()`:

```swift
        reloadCanonicalPresence()
        refreshPendingDeletions()
```

- [ ] **Step 3: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.
Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): AppState pending-deletions cache + refresh hooks

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: `AppState.propagateDeletions` + `restorePending`

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add the two action methods**

In `Sources/OpenPhotoApp/AppState.swift`, after `refreshPendingDeletions()`:

```swift
    /// Move the selected drive copies into the drive's bin, then refresh presence/badges/queue/UI.
    func propagateDeletions(drive driveVault: Vault, selected: [PendingDeletion]) {
        guard let lib = library, !selected.isEmpty else { return }
        let macID = lib.vaults.first?.descriptor.vaultID ?? ""
        _ = try? DeletionPropagator().propagate(drive: driveVault, entries: selected,
                                                macVaultID: macID, catalog: lib.catalog)
        _ = driftScan(driveVault)        // re-derives presence + badges + drift from the updated manifest
        try? refreshQueries()            // also calls refreshPendingDeletions()
    }

    /// Undo one pending deletion: un-bin the photo locally (which dequeues it + its Live pair).
    func restorePending(_ e: PendingDeletion) async {
        guard let lib = library else { return }
        if let entry = (try? lib.binItems())?.first(where: { $0.item.hash == e.hash }) {
            try? await lib.restore(entry)
        } else {
            // File already restored/gone from the bin — just drop the intent.
            try? lib.catalog.dequeuePendingDeletion(hash: e.hash)
        }
        try? refreshQueries()
    }
```

- [ ] **Step 2: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): propagateDeletions + restorePending actions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 11: `DeletionListView` (shared, thumbnailed, select-all, per-row restore)

**Files:**
- Create: `Sources/OpenPhotoApp/Drives/DeletionListView.swift`

- [ ] **Step 1: Create the view**

Create `Sources/OpenPhotoApp/Drives/DeletionListView.swift`:

```swift
import SwiftUI
import OpenPhotoCore

/// Shared, selectable list of pending deletions — small cached thumbnails, Select-All, and a
/// per-row Restore (distinct from unchecking). Used by both the standalone review sheet and the
/// Sync plan's Deletions section.
struct DeletionListView: View {
    @Bindable var state: AppState
    let entries: [PendingDeletion]
    @Binding var selected: Set<String>      // selected hashes
    let onRestore: (PendingDeletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entries.count) photo\(entries.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(entries.map(\.hash))
                }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 4).padding(.bottom, 4)
            List(entries, id: \.hash) { e in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(e.hash) },
                        set: { if $0 { selected.insert(e.hash) } else { selected.remove(e.hash) } }))
                        .labelsHidden().toggleStyle(.checkbox)
                    DeletionThumb(state: state, hash: e.hash)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.relPath).font(.system(size: 12))
                            .lineLimit(1).truncationMode(.middle)
                        Text("deleted \(relativeAge(e.deletedAtMs))")
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Button { onRestore(e) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }.controlSize(.small).font(.system(size: 11))
                }
            }.listStyle(.inset)
        }
    }

    private var allSelected: Bool { !entries.isEmpty && selected.count == entries.count }

    private func relativeAge(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// 32px cached thumbnail by hash (works with the local original deleted + the drive unplugged);
/// falls back to a glyph when nothing is cached.
private struct DeletionThumb: View {
    @Bindable var state: AppState
    let hash: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.hairline)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            }
        }
        .task(id: hash) {
            image = await state.library?.thumbnails.cachedDisplayImage(
                for: ContentHash(stringValue: hash), maxPixel: 64)
        }
    }
}
```

- [ ] **Step 2: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/DeletionListView.swift
git commit -m "feat(app): shared DeletionListView (thumbnails, select-all, per-row restore)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 12: `DeletionReviewSheet` (standalone gate)

**Files:**
- Create: `Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift`

- [ ] **Step 1: Create the sheet**

Create `Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift`:

```swift
import SwiftUI
import OpenPhotoCore

/// Standalone deletion-review gate. Computes eligibility on appear (no external state to go
/// stale — the lesson from Slices 1/2), defaults to all-selected, and confirms with
/// "Move N to drive bin". Restore on a row undeletes the photo and drops it from the list.
struct DeletionReviewSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [PendingDeletion]?
    @State private var selected: Set<String> = []
    @State private var movedCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review Deletions — \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding(16)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 620, height: 480)
        .task { reload(defaultSelectAll: true) }
    }

    @ViewBuilder private var content: some View {
        if let movedCount {
            ContentUnavailableView("Moved \(movedCount) to drive bin",
                systemImage: "checkmark.seal",
                description: Text("The drive's copies are in its bin — recoverable, never hard-deleted."))
        } else if let entries {
            if entries.isEmpty {
                ContentUnavailableView("No deletions to propagate",
                    systemImage: "checkmark.seal",
                    description: Text("Photos you delete on this Mac that still exist on \(drive.rootURL.lastPathComponent) appear here."))
            } else {
                VStack(spacing: 10) {
                    Text("These photos were deleted on this Mac and still exist on \(drive.rootURL.lastPathComponent). Confirm to move the drive's copies into its bin (recoverable).")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.top, 12)
                    DeletionListView(state: state, entries: entries,
                                     selected: $selected, onRestore: restore)
                        .padding(.horizontal, 12)
                    HStack {
                        Spacer()
                        Button("Move \(selected.count) to drive bin") { propagate() }
                            .keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
                    }.padding(16)
                }
            }
        } else {
            ProgressView().padding(24).frame(maxHeight: .infinity)
        }
    }

    private func reload(defaultSelectAll: Bool) {
        state.refreshPendingDeletions()
        let e = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
        entries = e
        selected = defaultSelectAll ? Set(e.map(\.hash)) : selected.intersection(Set(e.map(\.hash)))
    }

    private func restore(_ e: PendingDeletion) {
        Task { await state.restorePending(e); reload(defaultSelectAll: false) }
    }

    private func propagate() {
        let chosen = (entries ?? []).filter { selected.contains($0.hash) }
        state.propagateDeletions(drive: drive, selected: chosen)
        movedCount = chosen.count
    }
}
```

- [ ] **Step 2: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift
git commit -m "feat(app): standalone DeletionReviewSheet (all-selected, restore-aware)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 13: `DrivesView` pending-deletions indicator

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`

- [ ] **Step 1: Add the indicator state + sheet**

In `Sources/OpenPhotoApp/Drives/DrivesView.swift`, add a state var beside the others (after `@State private var forgetTarget: VaultRecord?`):

```swift
    @State private var deletionDrive: Vault?
```

Add a `.sheet(item:)` next to the existing ones (after the `.sheet(item: $drift)` line):

```swift
        .sheet(item: $deletionDrive) { d in DeletionReviewSheet(state: state, drive: d) }
```

- [ ] **Step 2: Render the indicator under the drift status line**

In `row(_:)`, the `VStack(alignment: .leading, ...)` currently shows `statusText`/`statusLine`. Add a third line after `statusLine(vr)`:

```swift
                statusLine(vr)
                pendingDeletionsLine(vr)
```

Add the builder (place it next to `statusLine`):

```swift
    /// Pending-deletions indicator — opens the standalone review sheet. Honest count from the
    /// eligibility cache (refreshed on connect + after any delete/restore/sync/propagate).
    @ViewBuilder private func pendingDeletionsLine(_ vr: VaultRecord) -> some View {
        if state.driveIsPresent(vr), let pend = state.drivePendingDeletions[vr.id], !pend.isEmpty {
            Button {
                if let v = state.openVault(for: vr) { deletionDrive = v }
            } label: {
                Label("\(pend.count) deletion\(pend.count == 1 ? "" : "s") pending · Review",
                      systemImage: "trash")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }.buttonStyle(.plain)
        }
    }
```

- [ ] **Step 3: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/DrivesView.swift
git commit -m "feat(app): Drives row pending-deletions indicator → review sheet

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 14: `SyncPlanSheet` Deletions section

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`

- [ ] **Step 1: Add deletion selection state**

In `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`, add beside the other `@State` vars:

```swift
    @State private var deletionSelection: Set<String> = []
```

- [ ] **Step 2: Show the section in `planView` (defaults to none selected)**

In `planView(_:)`, insert before the trailing `Spacer()` / `HStack { ... Button("Sync") ... }`:

```swift
            let pending = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
            if !pending.isEmpty {
                Divider().overlay(Theme.hairline)
                Text("Deletions to review (\(pending.count))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text("Deleted on this Mac, still on the drive. Tick to move the drive's copies into its bin.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                DeletionListView(state: state, entries: pending,
                                 selected: $deletionSelection, onRestore: restore)
                    .frame(maxHeight: 160)
            }
```

- [ ] **Step 3: Apply ticked deletions after the copies; update the Sync button enablement**

Replace the `Button("Sync")` block in `planView` so it also enables when deletions are ticked:

```swift
                Button("Sync") { Task { await runApply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enough || (plan.copies.isEmpty && plan.sidecarUpdates.isEmpty
                                          && deletionSelection.isEmpty))
```

In `runApply()`, after `try? state.refreshCanonicalPresence(driveVault: drive)` and before `result = r`:

```swift
        let pending = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
        let chosen = pending.filter { deletionSelection.contains($0.hash) }
        if !chosen.isEmpty { state.propagateDeletions(drive: drive, selected: chosen) }
```

Add the per-row restore helper to the struct:

```swift
    private func restore(_ e: PendingDeletion) {
        Task { await state.restorePending(e) }
    }
```

- [ ] **Step 4: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift
git commit -m "feat(app): Sync plan Deletions section (unticked by default)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 15: Refresh the indicator after a Sync

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`

A sync can newly satisfy eligibility rule 3 (more hashes land on the drive), so refresh the pending cache after the copies even when no deletions were ticked.

- [ ] **Step 1: Add the refresh**

In `runApply()`, immediately after `try? state.refreshCanonicalPresence(driveVault: drive)`:

```swift
        state.refreshPendingDeletions()
```

(Place it before the `chosen`/propagate block from Task 14 so the section count is current.)

- [ ] **Step 2: Build + verify no warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift
git commit -m "feat(app): refresh pending-deletions after a sync

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 16: Full suite + manual smoke

**Files:** none (verification only)

- [ ] **Step 1: Run the whole test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass (the ~142 prior + the new Core tests).

- [ ] **Step 2: Verify zero warnings across the build**

Run: `swift build 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 3: Manual smoke (record results in the PR/commit notes)**

Build + run the app (`scripts/make-app.sh` or the usual run path). With a folder used as a canonical drive that has been synced:
- Delete a synced photo on the Mac → the Drives row shows `1 deletion pending · Review`.
- Open Review → the row shows the photo's **thumbnail** + path; **Select All/Deselect All** works; **Restore** brings the photo back to the library and removes the row.
- With one ticked, **Move 1 to drive bin** → the drive's copy is now under `<drive>/.openphoto/bin/`, the indicator clears, and the photo no longer appears as drive-only.
- Open **Sync…** with a pending deletion → the **Deletions** section appears **unticked**; applying a copy-only sync does not delete; ticking + Sync propagates.
- **Evict** a folder (don't delete) → confirms **no** pending-deletions indicator appears.

- [ ] **Step 4: No commit** (verification task). If any check fails, fix in the relevant task's files and re-commit there.

---

## M5 — Doc reconciliation

### Task 17: Reconcile Phase-3 spec wording + master-spec note & changelog

**Files:**
- Modify: `docs/superpowers/specs/2026-06-09-phase3-drives-design.md`
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1: Fix the loose `.openphoto-trash/` wording in the Phase-3 design spec**

In `docs/superpowers/specs/2026-06-09-phase3-drives-design.md`, the two deletion-slice references currently say `.openphoto-trash/` at the volume root. Change both to the §8 vault bin:

- The invariant line (≈ line 19): `On a drive, deletion moves files into `.openphoto-trash/` at the volume root (format §8 spirit).` →
  `On a drive, deletion moves files into the drive vault's `.openphoto/bin/` (format §8).`
- The Slice 3 summary line (≈ line 53): `on confirmation, drive copies move to the drive's `.openphoto-trash/`. `origin:"propagated"` per format §8.` →
  `on confirmation, drive copies move into the drive vault's `.openphoto/bin/`, `origin:"propagated"` per format §8.`

- [ ] **Step 2: Add the standalone-review note to the master design spec §4**

In `docs/superpowers/specs/2026-06-07-openphoto-design.md`, in the §4 **Propagation** bullet, append a sentence:

```markdown
Review is available **standalone** (a "Review Deletions" gate on the drive, any time it's connected) as well as inside the sync plan; both share one confirm and move copies into the drive vault's `.openphoto/bin/` (`origin:"propagated"`).
```

- [ ] **Step 3: Add a dated changelog entry to the master design spec**

In the changelog section of `docs/superpowers/specs/2026-06-07-openphoto-design.md`, add:

```markdown
- **2026-06-09** — Phase 3 **Slice 3 (Deletion propagation)** implemented on `phase3-drives`. The first destructive slice: locally-deleted photos can have their canonical-drive copies moved into the drive vault's `.openphoto/bin/` (`origin:"propagated"`), reviewed via a standalone "Review Deletions" gate or a Sync-plan section (thumbnailed, select-all, per-row restore). A dedicated Delete-only catalog queue (`pending_deletions`, migration v4) records true deletions only — eviction never propagates. Eligibility (queued ∧ no-local-instance ∧ on-drive) is computed at review time. New `DeletionPropagator` (pure `eligible` + destructive `propagate`: BinStore move + atomic manifest rewrite + presence/queue/sync-log update; idempotent, failures stay queued). Format `vault-format-v1` §8 clarified (vault bin hosts propagated deletions; `.openphoto-trash/` is removable-non-vault-only) and §9 gained the `"delete"` event. Deferred: drive-only deletion → Slice 4; backup-drive propagation → Slice 5. Spec: `docs/superpowers/specs/2026-06-09-phase3-slice3-deletion-propagation-design.md`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-09-phase3-drives-design.md \
        docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: reconcile drive-bin wording + record Slice 3 in master changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final review

After all tasks, dispatch a final whole-slice code review (per subagent-driven-development) covering: the eligibility rule's three guards, the propagate ordering/crash-consistency, that evict never enqueues, atomic manifest rewrite correctness, and the two UI surfaces sharing one confirm path. Then use **superpowers:finishing-a-development-branch** — but note the standing decision to **merge all of `phase3-drives` to `main`** is the user's call; surface it, don't auto-merge.

## Self-Review

**Spec coverage:** §3 eligibility → Tasks 2,7,9. §4 queue + wiring → Tasks 1,3,4,5. §5.1 `eligible` → Task 7. §5.2 `propagate` (BinStore move + atomic manifest + presence + queue + sync-log, idempotent) → Tasks 6,8. §6.1 AppState → Tasks 9,10. §6.2 `DeletionListView` (thumbnails, select-all, restore-vs-uncheck) → Task 11. §6.3 standalone (`DeletionReviewSheet` + indicator) → Tasks 12,13. §6.4 in-Sync section (default none) → Tasks 14,15. §7 format §8/§9 → Task 8; Phase-3 + master docs → Task 17. §9 testing → Tasks 1–8,16. §10 out-of-scope respected (no drive-only delete, no backup propagation). Milestones M1–M5 all covered.

**Placeholder scan:** none — every code/doc step has literal content and exact commands.

**Type consistency:** `PendingDeletionRecord{hash,relPath,deletedAtMs}` (catalog) vs `PendingDeletion{hash,relPath,driveRelPath,size,deletedAtMs}` (drive-resolved) used consistently; `DeletionPropagator.eligible(queue:localHashes:presence:)` and `propagate(drive:entries:macVaultID:catalog:) -> Result{propagated,skipped,failed}` match across Tasks 7–10; `DeletionListView(state:entries:selected:onRestore:)` signature identical in Tasks 11–14; `AppState.drivePendingDeletions` / `refreshPendingDeletions` / `propagateDeletions(drive:selected:)` / `restorePending(_)` consistent across Tasks 9–14; `SyncLog.append(event:summary:counterparty:to:)` consistent in Tasks 6,8.
