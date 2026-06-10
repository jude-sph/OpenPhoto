# Phase 3 Slice 4 — Evict / Rehydrate / Drive-only Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Free Mac space by releasing local originals that are verified on the canonical drive (evict → macOS Trash → drive-only), bring them back hash-verified (rehydrate), and delete photos that live only on the drive.

**Architecture:** Eviction lives in a focused `LibraryService` extension (`evict(_:mode:…)` + `rehydrate(_:…)`), reusing the service's `catalog`/`vaults`/`rescan`. Verified evict re-hashes the drive copy before `FileManager.trashItem`-ing the local original; forced evict trusts the recorded hash (drive may be absent). Rehydrate uses `VerifiedCopy` back from the drive. Drive-only deletion is a new sibling of `DeletionPropagator.propagate`. The Scanner turning a vanished local file into a dropped `instances` row (→ drive-only via Slice 2.5) does the heavy lifting.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (CLT only), GRDB, Swift Testing (`@Test`/`#expect`/`#require`).

**Conventions (every task):**
- TDD: failing test first → watch it fail → minimal impl → watch it pass → commit.
- **Generated mock media only** — never `~/Pictures`/`~/Movies` or any personal folder. Use `TestDirs`, `makeJPEG`, `makeMOV`, and a temp "drive" `Vault` via `Vault.openOrCreate(at:role:.canonical)` seeded with `Manifest.write` + `Catalog.replaceVaultPresence`.
- **Zero warnings:** `swift build 2>&1 | grep -i warning` prints nothing.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Branch: continue on `phase3-drives` (not `main`).

**Existing building blocks (do not reinvent):**
- `VerifiedCopy.copy(from:to:expectedHash:) -> Bool` — atomic temp→fsync→re-hash→rename; never overwrites; false on any failure/mismatch.
- `ContentHash.ofFile(at: URL) throws -> ContentHash`; `ContentHash(stringValue:)`; `.stringValue`.
- `FileManager.default.trashItem(at:resultingItemURL:) throws` — to macOS Trash (used in `BinView`).
- `Manifest.read(from:) -> [ManifestEntry]` / `Manifest.write(_:to:)` (atomic); `ManifestEntry{hash: ContentHash, path, size, mtime}`.
- `BinStore(vault:).moveToBin(relPath:hash:origin:)` (`origin: .user | .propagated`).
- `Catalog`: `vaultPresenceRows(forVault:) -> [VaultPresenceEntry]` (`{hash, relPath, dirPath, size, driveRelPath}`), `removeVaultPresence(vaultID:hashes:)`, `instanceItem(hash:vaultID:) -> InstanceRecord?`, `vaultPresenceHashes(forVault:)`.
- `SyncLog.append(event:summary:counterparty:to:)` → a vault's `syncLogURL`.
- `DeletionPropagator.propagate(drive:entries:macVaultID:catalog:)` — the per-item drive-bin-move + atomic manifest rewrite + `removeVaultPresence` + sync-log pattern to mirror.
- `DrivePathMap.driveToMacRelPath(_:sourceBasenames:)` — strips a leading source-vault basename (`Pictures/rome/x` → `rome/x`).
- `LibraryService`: `vaults` (local), `catalog`, `vault(id:) -> Vault?`, `rescan(vaultID:) async`, `appendSyncLog(...)`.
- `Vault`: `absoluteURL(forRelativePath:)`, `rootURL`, `descriptor.vaultID`, `manifestURL`, `syncLogURL`; `Identifiable`.
- `AppState`: `canonicalVaults: [VaultRecord]`, `canonicalPresence: Set<String>`, `driveIsPresent(_) -> Bool`, `openVault(for:) -> Vault?`, `isDriveOnly(_)`, `driftScan(_)`, `refreshQueries()`, `removeOpenedItem(using:)`, the Slice 3 selection affordances.
- `TimelineItem`: `hash`, `relPath`, `vaultID`, `livePairHash`, `driveRelPath` (nil = local; set = drive-only).

---

## File Structure

**Core (`Sources/OpenPhotoCore/`)**
- `LibraryService+Eviction.swift` — *create*: `EvictMode`, `EvictOutcome`, `RehydrateOutcome`; `evict(_:mode:connectedCanonical:canonicalPresence:)`; `rehydrate(_:connectedCanonical:)`; the private `verifyOnCanonical` + path-mapping helpers.
- `LibraryService.swift` — *modify*: remove the Stage-A bin-based `evict(_:)`.
- `Sync/DeletionPropagator.swift` — *modify*: add `deleteDriveOnly(drive:entries:macVaultID:catalog:)`.

**App (`Sources/OpenPhotoApp/`)**
- `AppState.swift` — *modify*: `evict(_:mode:)`, `rehydrate(_:)`, `deleteDriveOnly(_:)` wrappers (off-main); `rehydratableItems`/`driveOnlyDeletable` helpers.
- `Selection/SelectionUI.swift`, `Timeline/TimelineView.swift`, `Folders/FolderGridView.swift` — *modify*: real evict, Force-Evict overflow, Rehydrate action, drive-only Delete enablement.
- `Inspector/InspectorView.swift` — *modify*: Rehydrate + drive-only Delete + Force-Evict for the open photo.
- `Drives/` (or `Selection/`) — *create*: `EvictProgressSheet` (shared evict/rehydrate progress + outcome).

**Tests (`Tests/OpenPhotoCoreTests/`)**
- `EvictionTests.swift`, `RehydrateTests.swift` — *create*.
- `DeletionPropagatorTests.swift` — *modify* (drive-only delete).
- `LibraryServiceTests.swift` — *modify* (migrate the 3 Stage-A evict tests).

**Docs**
- `docs/format/vault-format-v1.md` §9 (`"rehydrate"` event) — *modify*, same commit as rehydrate (Task 5).
- `docs/superpowers/specs/2026-06-07-openphoto-design.md` — *modify* (changelog, Task 11).

---

## M1 — Verified evict

### Task 1: `evict(_:mode:.verified)` + types (coexists with the old evict)

**Files:**
- Create: `Sources/OpenPhotoCore/LibraryService+Eviction.swift`
- Test: `Tests/OpenPhotoCoreTests/EvictionTests.swift`

The new `evict` has a different signature than the Stage-A one, so they overload-coexist; Task 2 removes the old one. This keeps the build green.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/EvictionTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// A local library with one photo, plus a temp "drive" vault that has a verified copy of it.
/// Returns (lib, localVault, driveVault, the item, its hash).
private func evictFixture(_ t: TestDirs) async throws
    -> (LibraryService, Vault, Vault, TimelineItem) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)

    // Build a drive that holds a byte-identical copy at Pictures/rome/IMG_1.jpg.
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let drivePath = "Pictures/rome/IMG_1.jpg"
    let driveFile = drive.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: driveFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let localFile = pics.appendingPathComponent("rome/IMG_1.jpg")
    try FileManager.default.copyItem(at: localFile, to: driveFile)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: item.size, driveRelPath: drivePath)])
    return (lib, lib.vaults[0], drive, item)
}

@Test func verifiedEvictReleasesLocalAndBecomesDriveOnly() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, drive, item) = try await evictFixture(t)
    let localFile = local.rootURL.appendingPathComponent("rome/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: localFile.path))

    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [drive], canonicalPresence: [item.hash])

    #expect(outcome == EvictOutcome(evicted: 1, refused: 0))
    #expect(!FileManager.default.fileExists(atPath: localFile.path))     // local original gone
    // The local sidecar folder is left untouched (we only trash the media file).
    let items = try lib.catalog.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].driveRelPath != nil)                                // now drive-only
    #expect(items[0].hash == item.hash)
}

@Test func verifiedEvictRefusesWhenNotOnConnectedDrive() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, _, item) = try await evictFixture(t)
    // No connected drive, empty presence → must refuse and keep the local file.
    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [], canonicalPresence: [])
    #expect(outcome == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("rome/IMG_1.jpg").path))
}

@Test func verifiedEvictRefusesWhenDriveBytesDiffer() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, drive, item) = try await evictFixture(t)
    // Corrupt the drive copy → re-hash mismatch → refuse, keep local.
    try Data("corrupted".utf8).write(to: drive.rootURL.appendingPathComponent("Pictures/rome/IMG_1.jpg"))
    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [drive], canonicalPresence: [item.hash])
    #expect(outcome == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("rome/IMG_1.jpg").path))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter verifiedEvictReleasesLocalAndBecomesDriveOnly`
Expected: FAIL — `evict(_:mode:connectedCanonical:canonicalPresence:)` not found.

- [ ] **Step 3: Create the eviction extension**

Create `Sources/OpenPhotoCore/LibraryService+Eviction.swift`:

```swift
import Foundation

public enum EvictMode: String, Sendable {
    case verified   // requires a connected canonical drive; re-hashes the drive copy
    case forced     // trusts the recorded hash; the drive may be absent
}

public struct EvictOutcome: Sendable, Equatable {
    public var evicted: Int   // local originals released to macOS Trash
    public var refused: Int   // not verifiable on a canonical drive → kept local
    public init(evicted: Int = 0, refused: Int = 0) { self.evicted = evicted; self.refused = refused }
}

public struct RehydrateOutcome: Sendable, Equatable {
    public var rehydrated: Int
    public var failed: Int
    public init(rehydrated: Int = 0, failed: Int = 0) { self.rehydrated = rehydrated; self.failed = failed }
}

extension LibraryService {
    /// Release local originals to macOS Trash once verified on a canonical drive. `.verified`
    /// re-hashes the drive copy on a CONNECTED drive; `.forced` trusts `canonicalPresence` (drive
    /// may be absent). Live pairs evict as a unit — both halves must verify or BOTH are refused.
    /// Items not verifiable are refused (kept local). One rescan per touched local vault; the local
    /// sidecar is left in place (rehydrate restores the media beside it).
    @discardableResult
    public func evict(_ items: [TimelineItem], mode: EvictMode,
                      connectedCanonical: [Vault], canonicalPresence: Set<String>) async throws -> EvictOutcome {
        var byVault: [String: [TimelineItem]] = [:]
        for it in items where it.driveRelPath == nil { byVault[it.vaultID, default: []].append(it) }
        var outcome = EvictOutcome()
        for (vaultID, group) in byVault {
            guard let local = vault(id: vaultID) else { continue }
            var releasedHere = 0
            for item in group {
                // The set of (hash, relPath) this item releases: the still + its Live-pair video.
                var halves: [(hash: String, relPath: String)] = [(item.hash, item.relPath)]
                if let pairHash = item.livePairHash,
                   let pairInstance = try? catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                    halves.append((pairHash, pairInstance.relPath))
                }
                // Verify EVERY half before releasing ANY (never half-evict a Live Photo).
                guard halves.allSatisfy({ verifyOnCanonical(hash: $0.hash, mode: mode,
                                                            connectedCanonical: connectedCanonical,
                                                            canonicalPresence: canonicalPresence) })
                else { outcome.refused += 1; continue }
                // Release the still; only count it if the file is actually gone afterward.
                let stillURL = local.absoluteURL(forRelativePath: item.relPath)
                try? FileManager.default.trashItem(at: stillURL, resultingItemURL: nil)
                guard !FileManager.default.fileExists(atPath: stillURL.path) else {
                    outcome.refused += 1; continue
                }
                outcome.evicted += 1; releasedHere += 1
                // The paired video goes too (best-effort — already verified above).
                if halves.count > 1 {
                    try? FileManager.default.trashItem(
                        at: local.absoluteURL(forRelativePath: halves[1].relPath), resultingItemURL: nil)
                }
            }
            if releasedHere > 0 {
                appendSyncLog(vault: local, event: "evict", summary: "\(releasedHere) released", counterpartyKey: "")
                try await rescan(vaultID: vaultID)
            }
        }
        return outcome
    }

    /// Whether `hash`'s copy on a canonical drive can be trusted right now under `mode`.
    func verifyOnCanonical(hash: String, mode: EvictMode,
                           connectedCanonical: [Vault], canonicalPresence: Set<String>) -> Bool {
        switch mode {
        case .forced:
            return canonicalPresence.contains(hash)   // trust the recorded hash; drive may be absent
        case .verified:
            for drive in connectedCanonical {
                guard let row = (try? catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID))?
                        .first(where: { $0.hash == hash }) else { continue }
                let url = drive.absoluteURL(forRelativePath: row.driveRelPath)
                if (try? ContentHash.ofFile(at: url).stringValue) == hash { return true }
            }
            return false
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "verifiedEvict"`
Expected: PASS (all three verified-evict tests).

- [ ] **Step 5: No warnings**

Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService+Eviction.swift Tests/OpenPhotoCoreTests/EvictionTests.swift
git commit -m "feat(library): verified evict — re-hash on canonical, release local to Trash

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Live-pair-as-a-unit test + swap callers to the new evict, remove the Stage-A evict

**Files:**
- Test: `Tests/OpenPhotoCoreTests/EvictionTests.swift` (add a Live-pair test)
- Modify: `Sources/OpenPhotoCore/LibraryService.swift` (remove old `evict(_:)`)
- Modify: `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift` (migrate the 3 Stage-A evict tests)
- Modify: `Sources/OpenPhotoApp/AppState.swift` (the `evict` wrapper now takes a mode + resolves connected drives)

- [ ] **Step 1: Add the Live-pair test**

Append to `Tests/OpenPhotoCoreTests/EvictionTests.swift`:

```swift
@Test func verifiedEvictLivePairIsAllOrNothing() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_9.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try await makeMOV(at: pics.appendingPathComponent("a/IMG_9.mov").creatingParent())
    let now = Date()
    for f in ["a/IMG_9.jpg", "a/IMG_9.mov"] {
        try FileManager.default.setAttributes([.modificationDate: now],
            ofItemAtPath: pics.appendingPathComponent(f).path)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    let video = try #require(item.livePairHash)

    // Drive that holds BOTH halves, byte-identical.
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    var entries: [VaultPresenceEntry] = []
    for (rel, hash) in [("a/IMG_9.jpg", item.hash), ("a/IMG_9.mov", video)] {
        let dp = "Pictures/\(rel)"
        let df = drive.rootURL.appendingPathComponent(dp)
        try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pics.appendingPathComponent(rel), to: df)
        entries.append(VaultPresenceEntry(hash: hash, relPath: rel, dirPath: "a", size: 1, driveRelPath: dp))
    }
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: entries)

    // Both verify → both released.
    let ok = try await lib.evict([item], mode: .verified,
                                 connectedCanonical: [drive], canonicalPresence: [item.hash, video])
    #expect(ok == EvictOutcome(evicted: 1, refused: 0))
    #expect(!FileManager.default.fileExists(atPath: pics.appendingPathComponent("a/IMG_9.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: pics.appendingPathComponent("a/IMG_9.mov").path))

    // Now a case where the video can't verify → BOTH refused, BOTH kept.
    let t2 = try TestDirs(); defer { t2.cleanup() }
    let (lib2, local2, drive2, still2) = try await evictFixtureLivePartial(t2)
    let r = try await lib2.evict([still2], mode: .verified,
                                 connectedCanonical: [drive2], canonicalPresence: [still2.hash])
    #expect(r == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local2.rootURL.appendingPathComponent("a/IMG_9.jpg").path))
    #expect(FileManager.default.fileExists(atPath: local2.rootURL.appendingPathComponent("a/IMG_9.mov").path))
}

/// Live pair where only the STILL is on the drive (video missing) → evict must refuse both.
private func evictFixtureLivePartial(_ t: TestDirs) async throws -> (LibraryService, Vault, Vault, TimelineItem) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_9.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try await makeMOV(at: pics.appendingPathComponent("a/IMG_9.mov").creatingParent())
    let now = Date()
    for f in ["a/IMG_9.jpg", "a/IMG_9.mov"] {
        try FileManager.default.setAttributes([.modificationDate: now],
            ofItemAtPath: pics.appendingPathComponent(f).path)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    // Only the still copied to the drive; presence only lists the still.
    let dp = "Pictures/a/IMG_9.jpg"
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("a/IMG_9.jpg"), to: df)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: "a/IMG_9.jpg", dirPath: "a", size: 1, driveRelPath: dp)])
    return (lib, lib.vaults[0], drive, item)
}
```

- [ ] **Step 2: Run — expect the new test to pass**

Run: `swift test --filter verifiedEvictLivePairIsAllOrNothing`
Expected: PASS. (Implementation from Task 1 already handles all-or-nothing.)

- [ ] **Step 3: Migrate the Stage-A evict tests + remove old evict**

In `Sources/OpenPhotoCore/LibraryService.swift`, **delete** the entire Stage-A `evict(_ items:) async throws -> Int` method (the one that does `bin.moveToBin(... origin: .user)` and `appendSyncLog(... event: "evict"...)`).

In `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`, the three tests now reference a removed method. Replace them:

- **Delete** `evictLivePhotoBinsBothHalves` and `evictSkipsMissingFilesAndCountsSuccesses` (they asserted bin behavior that no longer exists; the new behavior is covered by `EvictionTests`).
- **Replace** `evictDoesNotEnqueuePendingDeletion` with the version below (the delete-only guard still matters; the new evict still must never enqueue):

```swift
@Test func evictDoesNotEnqueuePendingDeletion() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    // Drive with a verified copy so evict actually releases.
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let dp = "Pictures/rome/IMG_1.jpg"
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("rome/IMG_1.jpg"), to: df)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome", size: item.size, driveRelPath: dp)])

    _ = try await lib.evict([item], mode: .verified, connectedCanonical: [drive], canonicalPresence: [item.hash])

    // Evict releases the local copy but must NEVER propose deleting the drive copy.
    #expect(try lib.catalog.pendingDeletions().isEmpty)
}
```

- [ ] **Step 4: Update the `AppState.evict` wrapper to the new signature**

In `Sources/OpenPhotoApp/AppState.swift`, replace the `evict(_ items:)` wrapper with one that resolves the connected canonical drives and runs off-main:

```swift
    /// Evict a selection (verified by default) — release verified local originals to the Trash.
    /// Runs the re-hash + trash off the main thread; refreshes queries + presence afterward.
    @discardableResult
    func evict(_ items: [TimelineItem], mode: EvictMode = .verified) async -> EvictOutcome {
        guard let lib = library else { return EvictOutcome() }
        let drives = canonicalVaults.filter { driveIsPresent($0) }.compactMap { openVault(for: $0) }
        let presence = canonicalPresence
        let outcome = await Task.detached(priority: .userInitiated) {
            (try? await lib.evict(items, mode: mode, connectedCanonical: drives, canonicalPresence: presence))
                ?? EvictOutcome()
        }.value
        try? refreshQueries()
        for vr in canonicalVaults where driveIsPresent(vr) { if let v = openVault(for: vr) { _ = driftScan(v) } }
        return outcome
    }
```

(The existing UI calls `await state.evict(items)` — that still compiles, now defaulting to `.verified`. The confirm-dialog copy is polished in Task 10; functionally it works now.)

- [ ] **Step 5: Run the full suite + warnings**

Run: `swift test 2>&1 | tail -3` → all pass.
Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService.swift Sources/OpenPhotoApp/AppState.swift \
        Tests/OpenPhotoCoreTests/EvictionTests.swift Tests/OpenPhotoCoreTests/LibraryServiceTests.swift
git commit -m "feat(library): replace Stage-A evict with verified evict; migrate tests + AppState

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M2 — Forced evict + override UI

### Task 3: `.forced` evict branch

**Files:**
- Test: `Tests/OpenPhotoCoreTests/EvictionTests.swift`

The `.forced` branch already exists in `verifyOnCanonical` (Task 1). This task locks its behavior with tests.

- [ ] **Step 1: Write the tests**

Append to `Tests/OpenPhotoCoreTests/EvictionTests.swift`:

```swift
@Test func forcedEvictReleasesEvenWithDriveAbsent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, _, item) = try await evictFixture(t)
    // No connected drive at all, but presence says the hash is on canonical → forced releases it.
    let outcome = try await lib.evict([item], mode: .forced,
                                      connectedCanonical: [], canonicalPresence: [item.hash])
    #expect(outcome == EvictOutcome(evicted: 1, refused: 0))
    #expect(!FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("rome/IMG_1.jpg").path))
}

@Test func forcedEvictStillRefusesWhenNotInPresence() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, _, item) = try await evictFixture(t)
    let outcome = try await lib.evict([item], mode: .forced,
                                      connectedCanonical: [], canonicalPresence: [])  // not on any canonical
    #expect(outcome == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("rome/IMG_1.jpg").path))
}
```

- [ ] **Step 2: Run — expect pass** (`.forced` already implemented).

Run: `swift test --filter forcedEvict`
Expected: PASS. If it FAILS, fix the `.forced` branch in `verifyOnCanonical` (it must return `canonicalPresence.contains(hash)` and the evict loop must not require a connected drive in forced mode).

- [ ] **Step 3: No warnings.** `swift build 2>&1 | grep -i warning` → none.

- [ ] **Step 4: Commit**

```bash
git add Tests/OpenPhotoCoreTests/EvictionTests.swift
git commit -m "test(library): forced evict releases on presence alone; refuses when absent from canonical

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Force-Evict override UI (ack-gated)

**Files:**
- Modify: `Sources/OpenPhotoApp/Selection/SelectionUI.swift` (overflow menu on the action bar)
- Modify: `Sources/OpenPhotoApp/Timeline/TimelineView.swift`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift` (force-evict state + ack sheet)

App task — build-verified + manual.

- [ ] **Step 1: Add a `Force Evict…` overflow to `SelectionActionBar`**

In `Sources/OpenPhotoApp/Selection/SelectionUI.swift`, add an `onForceEvict: () -> Void = {}` parameter and, after the Evict button, an overflow menu:

```swift
            Menu {
                Button(role: .destructive, action: onForceEvict) {
                    Label("Force Evict (skip verification)…", systemImage: "exclamationmark.triangle")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .disabled(count == 0)
```

- [ ] **Step 2: Wire force-evict + ack sheet in `TimelineView`**

Add state: `@State private var showForceEvict = false`. Pass `onForceEvict: { if !evictableItems.isEmpty { showForceEvict = true } }` to the action bar. Add the ack-gated confirmation (a `.sheet`, not a one-tap alert):

```swift
        .sheet(isPresented: $showForceEvict) {
            ForceEvictSheet(count: evictableItems.count) {
                let items = evictableItems
                Task { _ = await state.evict(items, mode: .forced); selection.clear(); selectMode = false }
            }
        }
```

Create the sheet in `Sources/OpenPhotoApp/Selection/SelectionUI.swift`:

```swift
/// The deliberate, ack-gated confirmation for Force Evict (skip verification).
struct ForceEvictSheet: View {
    let count: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Force Evict \(count) photo\(count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
            Text("This releases the local originals without re-checking the drive. If the drive copy is missing or damaged, these originals will be lost when you empty the Trash.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Toggle("I understand these originals may be unrecoverable.", isOn: $acknowledged)
                .font(.system(size: 12)).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Force Evict") { onConfirm(); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!acknowledged)
            }
        }
        .padding(20).frame(width: 420)
    }
}
```

- [ ] **Step 3: Mirror the same wiring in `FolderGridView`** (state `showForceEvict`, `onForceEvict`, the `.sheet` with `ForceEvictSheet`, identical to TimelineView).

- [ ] **Step 4: Build + verify** — `swift build` succeeds; `swift build 2>&1 | grep -i warning` → none; `swift test 2>&1 | tail -2` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/Selection/SelectionUI.swift Sources/OpenPhotoApp/Timeline/TimelineView.swift \
        Sources/OpenPhotoApp/Folders/FolderGridView.swift
git commit -m "feat(app): Force Evict override behind an overflow + acknowledgment-gated confirm

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M3 — Rehydrate

### Task 5: `rehydrate(_:)` Core + format §9

**Files:**
- Modify: `Sources/OpenPhotoCore/LibraryService+Eviction.swift`
- Modify: `docs/format/vault-format-v1.md` (§9 `"rehydrate"` — same commit)
- Test: `Tests/OpenPhotoCoreTests/RehydrateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/RehydrateTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func rehydrateCopiesDriveOnlyBackToLocal() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let original = try #require(try lib.catalog.timelineItems().first)
    let originalBytes = try Data(contentsOf: pics.appendingPathComponent("rome/IMG_1.jpg"))

    // Drive with the copy; then evict so the asset is drive-only.
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let dp = "Pictures/rome/IMG_1.jpg"
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("rome/IMG_1.jpg"), to: df)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: original.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: original.size, driveRelPath: dp)])
    _ = try await lib.evict([original], mode: .verified, connectedCanonical: [drive], canonicalPresence: [original.hash])
    let driveOnly = try #require(try lib.catalog.timelineItems().first { $0.driveRelPath != nil })

    let outcome = try await lib.rehydrate([driveOnly], connectedCanonical: [drive])

    #expect(outcome == RehydrateOutcome(rehydrated: 1, failed: 0))
    let restored = pics.appendingPathComponent("rome/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: restored.path))
    #expect(try Data(contentsOf: restored) == originalBytes)             // byte-identical
    #expect(try lib.catalog.timelineItems().first?.driveRelPath == nil)  // local again
}
```

- [ ] **Step 2: Run — expect failure** (`rehydrate` not found).

Run: `swift test --filter rehydrateCopiesDriveOnlyBackToLocal` → FAIL.

- [ ] **Step 3: Implement `rehydrate`**

Add to the `extension LibraryService` in `Sources/OpenPhotoCore/LibraryService+Eviction.swift`:

```swift
    /// Copy evicted (drive-only) originals back from a connected canonical drive, hash-verified.
    /// Maps each drive path back to the right local vault (the inverse of the basename-strip).
    /// Live pairs rehydrate together (best-effort). One rescan per touched local vault.
    @discardableResult
    public func rehydrate(_ items: [TimelineItem], connectedCanonical: [Vault]) async throws -> RehydrateOutcome {
        var outcome = RehydrateOutcome()
        var touchedVaults = Set<String>()
        for item in items where item.driveRelPath != nil {
            guard let drive = connectedCanonical.first(where: { $0.descriptor.vaultID == item.vaultID })
            else { outcome.failed += 1; continue }
            // Every hash to bring back: the still + its Live-pair video (resolved from drive presence).
            var halves: [(hash: String, driveRelPath: String, relPath: String)] =
                [(item.hash, item.driveRelPath!, item.relPath)]
            if let pairHash = item.livePairHash,
               let row = (try? catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID))?
                    .first(where: { $0.hash == pairHash }) {
                halves.append((pairHash, row.driveRelPath, row.relPath))
            }
            var stillOK = false
            for h in halves {
                guard let (local, localRel) = localTarget(forDriveRelPath: h.driveRelPath, macRelPath: h.relPath)
                else { continue }
                let src = drive.absoluteURL(forRelativePath: h.driveRelPath)
                if VerifiedCopy.copy(from: src, to: local.absoluteURL(forRelativePath: localRel),
                                     expectedHash: h.hash) {
                    touchedVaults.insert(local.descriptor.vaultID)
                    if h.hash == item.hash { stillOK = true }
                }
            }
            if stillOK { outcome.rehydrated += 1 } else { outcome.failed += 1 }
        }
        for vid in touchedVaults {
            if let v = vault(id: vid) {
                appendSyncLog(vault: v, event: "rehydrate", summary: "\(outcome.rehydrated) restored", counterpartyKey: "")
            }
            try await rescan(vaultID: vid)
        }
        return outcome
    }

    /// Map a drive path back to (local vault, mac-relative path): match the drive path's first
    /// component to a local vault's root basename; otherwise fall back to the primary local vault.
    func localTarget(forDriveRelPath driveRelPath: String, macRelPath: String) -> (Vault, String)? {
        let first = driveRelPath.split(separator: "/").first.map(String.init)
        if let first, let v = vaults.first(where: { $0.rootURL.lastPathComponent == first }) {
            return (v, macRelPath)
        }
        return vaults.first.map { ($0, macRelPath) }
    }
```

- [ ] **Step 4: Add the `"rehydrate"` event to the format doc (same commit)**

In `docs/format/vault-format-v1.md` §9, update the event-name list to include `"rehydrate"`. Change:
```markdown
…, `"evict"`, `"delete"` (a reviewed deletion propagated to this vault's bin).
```
to:
```markdown
…, `"evict"`, `"rehydrate"` (an evicted original copied back from a drive), `"delete"` (a reviewed deletion propagated to this vault's bin).
```

- [ ] **Step 5: Run — expect pass**

Run: `swift test --filter rehydrateCopiesDriveOnlyBackToLocal` → PASS.
Run: `swift build 2>&1 | grep -i warning` → none.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService+Eviction.swift Tests/OpenPhotoCoreTests/RehydrateTests.swift \
        docs/format/vault-format-v1.md
git commit -m "feat(library): rehydrate evicted originals from drive (VerifiedCopy) + format §9

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: AppState rehydrate wrapper + Rehydrate UI action

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`
- Modify: `Sources/OpenPhotoApp/Selection/SelectionUI.swift`, `Timeline/TimelineView.swift`, `Folders/FolderGridView.swift`, `Inspector/InspectorView.swift`

App task — build-verified.

- [ ] **Step 1: AppState.rehydrate (off-main) + eligibility helper**

In `Sources/OpenPhotoApp/AppState.swift`:

```swift
    /// Items in `items` that are drive-only AND whose drive is currently connected (rehydratable).
    func rehydratableItems(_ items: [TimelineItem]) -> [TimelineItem] {
        items.filter { item in
            item.driveRelPath != nil &&
            canonicalVaults.contains { $0.id == item.vaultID && driveIsPresent($0) }
        }
    }

    @discardableResult
    func rehydrate(_ items: [TimelineItem]) async -> RehydrateOutcome {
        guard let lib = library else { return RehydrateOutcome() }
        let drives = canonicalVaults.filter { driveIsPresent($0) }.compactMap { openVault(for: $0) }
        let outcome = await Task.detached(priority: .userInitiated) {
            (try? await lib.rehydrate(items, connectedCanonical: drives)) ?? RehydrateOutcome()
        }.value
        try? refreshQueries()
        for vr in canonicalVaults where driveIsPresent(vr) { if let v = openVault(for: vr) { _ = driftScan(v) } }
        return outcome
    }
```

- [ ] **Step 2: Add a Rehydrate action to `SelectionActionBar`** (`onRehydrate: () -> Void = {}` + a button shown only when there's something to rehydrate — gate at the call site):

```swift
            if showRehydrate {
                Button(action: onRehydrate) {
                    Label("Rehydrate", systemImage: "arrow.down.circle.dotted")
                }.disabled(count == 0).controlSize(.small)
                    .help("Copy the selected drive-only originals back to this Mac.")
            }
```
Add `var showRehydrate: Bool = false` to the struct.

- [ ] **Step 3: Wire in `TimelineView` + `FolderGridView`** — pass `showRehydrate: !rehydratableItems.isEmpty` and `onRehydrate: { let items = state.rehydratableItems(selectedItems); Task { _ = await state.rehydrate(items); selection.clear(); selectMode = false } }`. Add `private var rehydratableItems: [TimelineItem] { state.rehydratableItems(selectedItems) }`.

- [ ] **Step 4: Inspector** — in `deleteEvictActions`, when `state.isDriveOnly(item)` AND the drive is connected, show a **Rehydrate** button instead of the (hidden) delete/evict pair:

```swift
        } else if state.rehydratableItems([item]).count == 1 {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                Button { Task { _ = await state.rehydrate([item]) } } label: {
                    Label("Rehydrate", systemImage: "arrow.down.circle.dotted")
                }.controlSize(.small)
                Spacer()
            }
        }
```
(Place this as an `else if` after the existing `if !state.isDriveOnly(item) { … }` block.)

- [ ] **Step 5: Build + verify** — `swift build` ok; no warnings; `swift test 2>&1 | tail -2` all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Selection/SelectionUI.swift \
        Sources/OpenPhotoApp/Timeline/TimelineView.swift Sources/OpenPhotoApp/Folders/FolderGridView.swift \
        Sources/OpenPhotoApp/Inspector/InspectorView.swift
git commit -m "feat(app): Rehydrate action (selection + inspector) for connected drive-only items

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M4 — Drive-only deletion

### Task 7: `DeletionPropagator.deleteDriveOnly`

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`
- Test: `Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift`:

```swift
@Test func deleteDriveOnlyMovesToDriveBinAndClearsPresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    // Two files on the drive; we delete one, the other is a bystander.
    let goneHash = "sha256:" + String(repeating: "a", count: 64)
    let keepHash = "sha256:" + String(repeating: "b", count: 64)
    for (rel, h) in [("Pictures/a/x.jpg", goneHash), ("Pictures/a/y.jpg", keepHash)] {
        let u = drive.rootURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rel.utf8).write(to: u)
    }
    try Manifest.write([
        ManifestEntry(hash: ContentHash(stringValue: goneHash), path: "Pictures/a/x.jpg", size: 1, mtime: "2022-10-07T00:00:00.000Z"),
        ManifestEntry(hash: ContentHash(stringValue: keepHash), path: "Pictures/a/y.jpg", size: 1, mtime: "2022-10-07T00:00:00.000Z"),
    ], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: goneHash, relPath: "a/x.jpg", dirPath: "a", size: 1, driveRelPath: "Pictures/a/x.jpg"),
        VaultPresenceEntry(hash: keepHash, relPath: "a/y.jpg", dirPath: "a", size: 1, driveRelPath: "Pictures/a/y.jpg"),
    ])

    let n = try DeletionPropagator().deleteDriveOnly(
        drive: drive, entries: [(hash: goneHash, driveRelPath: "Pictures/a/x.jpg")],
        macVaultID: "mac-1", catalog: cat)

    #expect(n == 1)
    #expect(!FileManager.default.fileExists(atPath: drive.rootURL.appendingPathComponent("Pictures/a/x.jpg").path))
    let binned = drive.rootURL.appendingPathComponent(".openphoto/bin/Pictures/a/x.jpg")
    #expect(FileManager.default.fileExists(atPath: binned.path))
    #expect(try BinStore(vault: drive).list().first?.origin == .user)               // direct UI deletion
    #expect(try cat.vaultPresenceHashes(forVault: drive.descriptor.vaultID) == [keepHash])  // bystander kept
    let paths = try Manifest.read(from: drive.manifestURL).map(\.path)
    #expect(paths == ["Pictures/a/y.jpg"])                                          // gone path removed
    #expect(try cat.pendingDeletions().isEmpty)                                     // no queue involved
    let log = String(data: try Data(contentsOf: drive.syncLogURL), encoding: .utf8) ?? ""
    #expect(log.contains("\"delete\""))
}
```

- [ ] **Step 2: Run — expect failure** (`deleteDriveOnly` not found).

Run: `swift test --filter deleteDriveOnlyMovesToDriveBinAndClearsPresence` → FAIL.

- [ ] **Step 3: Implement `deleteDriveOnly`**

Add to `DeletionPropagator` in `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`:

```swift
    /// Delete photos that exist ONLY on the drive (no local copy, no pending queue): move each
    /// drive file into the drive's bin (`origin: .user` — deleted directly in this vault's UI),
    /// then one atomic manifest rewrite + presence removal + a "delete" sync-log event. Mirrors
    /// `propagate` minus the queue. Returns the count actually binned.
    @discardableResult
    public func deleteDriveOnly(drive: Vault, entries: [(hash: String, driveRelPath: String)],
                                macVaultID: String, catalog: Catalog) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        let bin = BinStore(vault: drive)
        let fm = FileManager.default
        var clearedHashes: [String] = []
        var clearedDrivePaths = Set<String>()
        var moved = 0
        for e in entries {
            let src = drive.absoluteURL(forRelativePath: e.driveRelPath)
            if !fm.fileExists(atPath: src.path) {
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath); continue
            }
            do {
                try bin.moveToBin(relPath: e.driveRelPath,
                                  hash: ContentHash(stringValue: e.hash), origin: .user)
                moved += 1
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath)
            } catch { /* leave it; not cleared */ }
        }
        let remaining = try Manifest.read(from: drive.manifestURL)
            .filter { !clearedDrivePaths.contains($0.path) }
        try Manifest.write(remaining, to: drive.manifestURL)
        try catalog.removeVaultPresence(vaultID: drive.descriptor.vaultID, hashes: clearedHashes)
        if moved > 0 {
            SyncLog.append(event: "delete", summary: "\(moved) deleted from drive",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return moved
    }
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter deleteDriveOnlyMovesToDriveBinAndClearsPresence` → PASS.
Run: `swift build 2>&1 | grep -i warning` → none.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/DeletionPropagator.swift Tests/OpenPhotoCoreTests/DeletionPropagatorTests.swift
git commit -m "feat(sync): DeletionPropagator.deleteDriveOnly (drive-bin move, no local, no queue)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: AppState.deleteDriveOnly + enable Delete for drive-only-when-present

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`
- Modify: `Sources/OpenPhotoApp/Viewer/ViewerView.swift`, `Inspector/InspectorView.swift`, `Timeline/TimelineView.swift`, `Folders/FolderGridView.swift`

App task — build-verified.

- [ ] **Step 1: AppState.deleteDriveOnly + eligibility helper**

In `Sources/OpenPhotoApp/AppState.swift`:

```swift
    /// Drive-only items in `items` whose drive is currently connected (deletable on the drive).
    func driveOnlyDeletable(_ items: [TimelineItem]) -> [TimelineItem] {
        items.filter { item in
            item.driveRelPath != nil &&
            canonicalVaults.contains { $0.id == item.vaultID && driveIsPresent($0) }
        }
    }

    func deleteDriveOnly(_ items: [TimelineItem]) async {
        guard let lib = library else { return }
        let macID = lib.vaults.first?.descriptor.vaultID ?? ""
        var byDrive: [String: [(hash: String, driveRelPath: String)]] = [:]
        for it in items where it.driveRelPath != nil { byDrive[it.vaultID, default: []].append((it.hash, it.driveRelPath!)) }
        for (driveID, entries) in byDrive {
            guard let vr = canonicalVaults.first(where: { $0.id == driveID }), driveIsPresent(vr),
                  let drive = openVault(for: vr) else { continue }
            _ = try? DeletionPropagator().deleteDriveOnly(drive: drive, entries: entries, macVaultID: macID, catalog: lib.catalog)
            _ = driftScan(drive)
        }
        try? refreshQueries()
    }
```

- [ ] **Step 2: Route drive-only deletions through the existing Delete affordances**

Currently Delete is gated `!state.isDriveOnly(item)`. Change the gates so a drive-only item whose drive is present is deletable, routing to `deleteDriveOnly`:

- **ViewerView `deleteCurrent`:**
```swift
    private func deleteCurrent() {
        guard let item = state.openedItem else { return }
        if state.isDriveOnly(item) {
            guard !state.driveOnlyDeletable([item]).isEmpty else { return }   // drive must be present
            state.removeOpenedItem { await state.deleteDriveOnly($0) }
        } else {
            state.removeOpenedItem { await state.delete($0) }
        }
    }
```
- **InspectorView** `deleteEvictActions`: when `state.isDriveOnly(item)` AND `!state.driveOnlyDeletable([item]).isEmpty`, show a **Delete** button alongside Rehydrate; its confirm calls `state.removeOpenedItem { await state.deleteDriveOnly($0) }`. (Keep the existing local-only Delete/Evict branch unchanged.)
- **Selection (`TimelineView`/`FolderGridView`):** the Delete confirm path additionally handles drive-only-deletable items: split the selection into `evictableItems` (local) handled by `state.delete`, and `state.driveOnlyDeletable(selectedItems)` handled by `state.deleteDriveOnly`. Wire both in the Delete confirm action. Enable the Delete button when either subset is non-empty.

- [ ] **Step 3: Build + verify** — `swift build` ok; no warnings; `swift test 2>&1 | tail -2` all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Viewer/ViewerView.swift \
        Sources/OpenPhotoApp/Inspector/InspectorView.swift Sources/OpenPhotoApp/Timeline/TimelineView.swift \
        Sources/OpenPhotoApp/Folders/FolderGridView.swift
git commit -m "feat(app): delete drive-only photos (drive present) via the existing Delete affordances

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## M5 — Progress, summaries, docs

### Task 9: Evict/Rehydrate outcome summaries + progress

**Files:**
- Modify: `Sources/OpenPhotoApp/Timeline/TimelineView.swift`, `Folders/FolderGridView.swift` (surface `EvictOutcome`/`RehydrateOutcome` via a brief result alert)

App task — build-verified + manual. (Keep it lightweight: a result alert summarizing evicted/refused; a determinate progress bar is optional polish — if added, thread a `(done,total)` closure through `evict`/`rehydrate`; not required for this task.)

- [ ] **Step 1: Show an outcome summary after evict**

In `TimelineView` and `FolderGridView`, capture the evict result and present a summary. Change the evict confirm action to:
```swift
            Button("Move to Bin", role: .destructive) {       // label stays familiar; action is the real evict
                let items = evictableItems
                Task {
                    let r = await state.evict(items)
                    evictSummary = r.refused > 0
                        ? "Evicted \(r.evicted) · \(r.refused) kept (not verified on a connected drive)"
                        : "Evicted \(r.evicted) to free space."
                    selection.clear(); selectMode = false
                }
            }
```
Add `@State private var evictSummary: String?` and a `.alert("Evict", isPresented: Binding(get: { evictSummary != nil }, set: { if !$0 { evictSummary = nil } })) { Button("OK") { evictSummary = nil } } message: { Text(evictSummary ?? "") }`. Update the evict confirm dialog title/message copy from the Stage-A "Move to Bin"/only-copy wording to evict-to-Trash + "items not on a connected drive are kept" (use `evictAlertMessage` replacement text).

- [ ] **Step 2: Build + verify** — `swift build` ok; no warnings; `swift test 2>&1 | tail -2` pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Timeline/TimelineView.swift Sources/OpenPhotoApp/Folders/FolderGridView.swift
git commit -m "feat(app): evict outcome summary (evicted/refused); evict-to-Trash copy

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Full suite + manual smoke

**Files:** none (verification).

- [ ] **Step 1:** `swift test 2>&1 | tail -3` → all pass.
- [ ] **Step 2:** `swift build 2>&1 | grep -i warning` → none.
- [ ] **Step 3: Manual smoke** (build + run the app): sync a folder to a drive → select photos → **Evict** → verify progress/summary, originals leave the folder, they remain visible as drive-only; the local file is in macOS Trash. **Rehydrate** them → originals return, byte-identical. Unplug the drive → **Evict** is refused (or only **Force Evict** via the overflow, ack-gated, works). **Delete** a drive-only photo (drive plugged) → it leaves the library and the drive file is in the drive's bin.
- [ ] **Step 4:** No commit (verification). Fix any failure in the owning task's files.

---

### Task 11: Master-spec changelog

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1: Add the changelog entry** (after the existing 2026-06-09 Slice 3 entry):

```markdown
- **2026-06-09** — Phase 3 **Slice 4 (Evict / Rehydrate / Drive-only deletion)** implemented on `phase3-drives`. Real evict replaces the Stage-A bin shortcut: a selection's local originals are released to **macOS Trash** only after each is verified on a **connected** canonical drive (default re-hashes the drive copy; a `Force Evict` override behind an acknowledgment-gated overflow trusts the recorded hash and permits an absent drive). Evicted assets stay browsable as **drive-only**. **Rehydrate** copies originals back with `VerifiedCopy`. **Drive-only deletion** (deferred from Slice 3) moves a drive-only photo's copy into the drive's `.openphoto/bin/` via `DeletionPropagator.deleteDriveOnly` (no local bin, no queue). Live pairs evict/rehydrate/delete as a unit. Format `vault-format-v1` §9 gained the `"rehydrate"` event. Deferred: send-from-drive → Slice 4.5; editing drive-only assets stays view-only. Spec: `docs/superpowers/specs/2026-06-09-phase3-slice4-evict-rehydrate-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: record Slice 4 (evict/rehydrate/drive-only delete) in master changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final review

After all tasks: dispatch a whole-slice review covering the evict safety chain (never release without a verified/forced-acknowledged canonical copy; evict→Trash never hard-deletes; Live-pair all-or-nothing; forced-mode gating), rehydrate's `VerifiedCopy` + path-mapping inverse, and drive-only deletion's manifest/presence consistency. Then surface (don't auto-merge) the Phase-3 → `main` decision.

## Self-Review

**Spec coverage:** §3 verified evict → Tasks 1–2; §3.2 forced → Task 3; force-evict UI → Task 4; §4 rehydrate → Tasks 5–6; §5 drive-only deletion → Tasks 7–8; §6 format §9 → Task 5; §7 UI (evict real, force-evict overflow, rehydrate, drive-only delete) → Tasks 4,6,8,9; §10 testing → Tasks 1–8,10; §11 milestones M1–M5 all covered. Out-of-scope (send-from-drive, drive-only editing) correctly excluded.

**Placeholder scan:** none — every code/doc step has literal content + exact commands.

**Type consistency:** `EvictMode{verified,forced}`, `EvictOutcome{evicted,refused}`, `RehydrateOutcome{rehydrated,failed}` defined in Task 1/5 and used identically in Tasks 2,3,5,6 + AppState; `evict(_:mode:connectedCanonical:canonicalPresence:)`, `rehydrate(_:connectedCanonical:)`, `deleteDriveOnly(drive:entries:macVaultID:catalog:)` signatures consistent across Core + AppState wrappers; `verifyOnCanonical`/`localTarget` helpers used where defined; `rehydratableItems`/`driveOnlyDeletable` consistent across AppState + views.
