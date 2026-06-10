# Phase 3 Slice 2 — Drift & Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect when a passive canonical drive's real contents have drifted from its manifest (files added/removed outside OpenPhoto, or silent bit-rot), report it with recoverability, and offer only non-destructive repairs (adopt unknown, restore missing) — keeping the "backed up" badge honest.

**Architecture:** A new drive-scoped `DriftReconciler` (Core) reuses `Manifest`/`ContentHash`/`DriveVolume` and mirrors the `Scanner`'s file-walk, but never touches the catalog's `instances`/timeline. A fast `scan` (existence + size + mtime, no hashing) runs on connect; an explicit `verify` re-hashes everything to catch bit-rot. Recoverability is answered via the existing `PresenceService`. The atomic copy-verify block is factored out of `SyncEngine.apply` into a shared `VerifiedCopy` used by both sync and restore. Presence is re-derived from each scan so the badge can't lie.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (CLT), GRDB, CryptoKit, Swift Testing. macOS 15.

---

## Design notes (how this maps to the codebase)

- **Reuse, don't reinvent the walk:** `Scanner.scan` already enumerates media via `FileManager.enumerator(at:options:[.skipsHiddenFiles])`, skipping `.openphoto` dirs (`enumerator.skipDescendants()` when `url.lastPathComponent == Vault.stateDirName`) and filtering with `MediaKind.of(filename:) != nil`. `DriftReconciler` mirrors this. Relative paths via `Vault.relativePath(of:)`; mtime strings via `ISO8601Millis.string(from:)` (matches manifest `mtime` format).
- **Presence is re-derived, never hand-patched:** every `scan`/`verify` returns `presentHashes` (manifest hashes whose file exists with the expected size — or, for `verify`, whose bytes hash correctly). The App layer sets `vault_presence` to exactly that set after each scan and after each repair. So manifest edits + disk reality are the single source of truth; the badge follows.
- **Non-destructive only:** the sole mutations are additive — `adopt` (new manifest line for a file already on disk) and `restore` (copy good bytes into an *empty* path via `VerifiedCopy`, which never overwrites). `acknowledgeGone` drops a manifest line for an already-absent file (deletes nothing). Corrupt/changed files are report-only.
- **No new on-disk format and no new catalog tables.** Reuses `manifest.jsonl` and the Slice-1 `vault_presence` table.

## File structure

**Create (Core):**
- `Sources/OpenPhotoCore/Sync/VerifiedCopy.swift` — atomic copy→fsync→re-hash→verify helper (extracted from `SyncEngine`).
- `Sources/OpenPhotoCore/Sync/DriftReport.swift` — `DriftFinding`, `DriftReport`, `Recoverability`, `DriftProgress`, `DriftError`.
- `Sources/OpenPhotoCore/Sync/DriftReconciler.swift` — `scan`, `verify`, `recoverability(...)`, `adopt`, `restore`, `acknowledgeGone`.

**Create (App):**
- `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift` — grouped findings + safe-fix actions.

**Create (Tests):**
- `Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`, `DriftScanTests.swift`, `DriftRecoverabilityTests.swift`, `DriftRepairTests.swift`, `VerifyIntegrityTests.swift`.

**Modify:**
- `Sources/OpenPhotoCore/Sync/SyncEngine.swift` — call `VerifiedCopy.copy` (Slice 1 `SyncApplyTests` stay green).
- `Sources/OpenPhotoApp/AppState.swift` — `driftScan`/`verifyIntegrity`/repairs + presence refresh.
- `Sources/OpenPhotoApp/Drives/DrivesView.swift` — status line + "Check for changes" / "Verify Integrity" buttons + drift sheet.

## Conventions (every task)

- **TDD**: failing test first → red → implement → green → commit.
- **Generated mock media only** (`makeJPEG`, `TestDirs`); never `~/Pictures` or any personal folder.
- **0 warnings**: `swift build 2>&1 | grep -i warning` empty. Full suite green before commit: `swift test 2>&1 | tail -3`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Task 1 (M0): Extract `VerifiedCopy` and refactor `SyncEngine.apply`

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/VerifiedCopy.swift`
- Modify: `Sources/OpenPhotoCore/Sync/SyncEngine.swift`
- Test: `Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`

**Context:** `SyncEngine.apply` currently inlines: create dir → temp → `copyItem` → `FileHandle.synchronize` (fsync) → re-hash → verify → `moveItem`. Extract that into `VerifiedCopy.copy(from:to:expectedHash:) -> Bool` and call it from `apply`. Slice 1's `SyncApplyTests` are the regression guard — they MUST stay green (mismatch→failed+no file, idempotency, resume, ENOSPC, sidecar, manifest).

- [ ] **Step 1: Write the failing test** `Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func verifiedCopySucceedsAndVerifies() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.file("src/a.bin", Data("hello".utf8))
    let hash = try ContentHash.ofFile(at: src).stringValue
    let dest = t.root.appendingPathComponent("drive/x/a.bin")
    #expect(VerifiedCopy.copy(from: src, to: dest, expectedHash: hash) == true)
    #expect(try Data(contentsOf: dest) == Data("hello".utf8))
}

@Test func verifiedCopyFailsOnHashMismatchAndLeavesNoFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.file("src/a.bin", Data("hello".utf8))
    let dest = t.root.appendingPathComponent("drive/x/a.bin")
    let wrong = "sha256:" + String(repeating: "f", count: 64)
    #expect(VerifiedCopy.copy(from: src, to: dest, expectedHash: wrong) == false)
    #expect(!FileManager.default.fileExists(atPath: dest.path))
    // no orphan temp files in the dest dir
    let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []
    #expect(siblings.allSatisfy { !$0.hasPrefix(".tmp-") })
}

@Test func verifiedCopyNeverOverwritesExistingDest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.file("src/a.bin", Data("new".utf8))
    let hash = try ContentHash.ofFile(at: src).stringValue
    let dest = try t.file("drive/x/a.bin", Data("original".utf8))
    #expect(VerifiedCopy.copy(from: src, to: dest, expectedHash: hash) == false)
    #expect(try Data(contentsOf: dest) == Data("original".utf8)) // untouched
}
```

- [ ] **Step 2: Run red:** `swift test --filter VerifiedCopyTests 2>&1 | tail -20` → FAIL (`cannot find 'VerifiedCopy'`).

- [ ] **Step 3: Implement** `Sources/OpenPhotoCore/Sync/VerifiedCopy.swift`:

```swift
import Foundation

/// Atomic, hash-verified file copy: temp → fsync → re-hash → rename. Never overwrites an
/// existing destination, and leaves no partial/temp file behind on failure.
public enum VerifiedCopy {
    /// Copy `source` to `dest` and confirm the written bytes hash to `expectedHash`.
    /// Returns true only when the verified file is in place. Returns false (writing nothing
    /// at `dest`) on any failure, hash mismatch, or if `dest` already exists.
    @discardableResult
    public static func copy(from source: URL, to dest: URL, expectedHash: String) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return false } // never overwrite
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
            defer { try? fm.removeItem(at: tmp) }                      // no-op once renamed
            try fm.copyItem(at: source, to: tmp)
            if let fh = try? FileHandle(forUpdating: tmp) { _ = try? fh.synchronize(); try? fh.close() }
            guard (try? ContentHash.ofFile(at: tmp).stringValue) == expectedHash else { return false }
            try fm.moveItem(at: tmp, to: dest)                         // atomic; dest is absent
            return true
        } catch { return false }
    }
}
```

- [ ] **Step 4: Refactor `SyncEngine.apply`.** In `Sources/OpenPhotoCore/Sync/SyncEngine.swift`, replace the copy block inside the `for` loop's `do { … }` (the part from `try fm.createDirectory(...)` through `result.copied += 1`) with:

```swift
                guard VerifiedCopy.copy(from: item.sourceURL, to: destURL, expectedHash: item.hash) else {
                    result.failed.append(item); continue
                }
                verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                result.copied += 1
```

Keep everything else in `apply` unchanged: the free-space guard, the manifest-seed, the resume pre-check (`if fm.fileExists(atPath: destURL.path) { … skip/conflict … }`), the sidecar loop, the manifest rewrite, and the sync-log. The `do/catch` stays (the resume pre-check and `manifestEntry` still throw). `fm` remains in use for `fileExists`.

- [ ] **Step 5: Run green:** `swift test --filter "VerifiedCopyTests" 2>&1 | tail -5` (3 pass) and `swift test --filter "SyncApplyTests" 2>&1 | tail -5` (6 pass, unchanged). Full suite: `swift test 2>&1 | tail -3`. `swift build 2>&1 | grep -i warning` empty.

- [ ] **Step 6: Commit:**

```bash
git add Sources/OpenPhotoCore/Sync/VerifiedCopy.swift Sources/OpenPhotoCore/Sync/SyncEngine.swift Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift
git commit -m "refactor(sync): extract VerifiedCopy from SyncEngine.apply

Shared atomic copy→fsync→re-hash→verify→rename helper (never overwrites, no
orphan temp). apply now calls it; Slice 1 SyncApplyTests unchanged and green.
Reused by drift-restore in Slice 2.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2 (M1): `DriftReport` types + `DriftReconciler.scan` (fast)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/DriftReport.swift`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`
- Test: `Tests/OpenPhotoCoreTests/DriftScanTests.swift`

- [ ] **Step 1: Write the failing test** `Tests/OpenPhotoCoreTests/DriftScanTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// A drive vault with two media files already in its manifest.
private func driveWithManifest(_ t: TestDirs) throws -> Vault {
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    try makeJPEG(at: root.appendingPathComponent("Pictures/a.jpg").creatingParent(),
                 dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
    try makeJPEG(at: root.appendingPathComponent("Pictures/b.jpg").creatingParent(),
                 dateTimeOriginal: "2022:01:02 00:00:00", lat: nil, lon: nil)
    // Build a manifest matching the two files.
    let entries = try ["Pictures/a.jpg", "Pictures/b.jpg"].map { rel -> ManifestEntry in
        let url = root.appendingPathComponent(rel)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return ManifestEntry(hash: try ContentHash.ofFile(at: url),
                             path: rel, size: (a[.size] as? Int64) ?? 0,
                             mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date()))
    }
    try Manifest.write(entries, to: drive.manifestURL)
    return drive
}

@Test func scanCleanDriveHasNoFindings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWithManifest(t)
    let report = try DriftReconciler().scan(drive: drive)
    #expect(report.isClean)
    #expect(report.presentHashes.count == 2)
}

@Test func scanDetectsMissingUnknownAndChanged() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWithManifest(t)
    let root = drive.rootURL
    // missing: delete b.jpg
    try FileManager.default.removeItem(at: root.appendingPathComponent("Pictures/b.jpg"))
    // unknown: drop a media file not in the manifest
    try makeJPEG(at: root.appendingPathComponent("Pictures/c.jpg"),
                 dateTimeOriginal: "2022:01:03 00:00:00", lat: nil, lon: nil)
    // changed: append bytes to a.jpg so its size differs from the manifest
    let a = root.appendingPathComponent("Pictures/a.jpg")
    let fh = try FileHandle(forWritingTo: a); try fh.seekToEnd()
    try fh.write(contentsOf: Data([0,1,2,3])); try fh.close()

    let report = try DriftReconciler().scan(drive: drive)
    #expect(report.missing.map(\.relPath) == ["Pictures/b.jpg"])
    #expect(report.unknown.map(\.relPath) == ["Pictures/c.jpg"])
    #expect(report.changed.map(\.relPath) == ["Pictures/a.jpg"])
    #expect(report.presentHashes.isEmpty) // a changed, b missing → neither "present"
    #expect(!report.isClean)
}
```

- [ ] **Step 2: Run red:** `swift test --filter DriftScanTests 2>&1 | tail -20` → FAIL (`cannot find 'DriftReconciler'`).

- [ ] **Step 3: Implement types** `Sources/OpenPhotoCore/Sync/DriftReport.swift`:

```swift
import Foundation

public enum Recoverability: Sendable, Equatable {
    case recoverable(source: String)   // a verified-good copy exists elsewhere
    case lostNoCopy                    // no good copy known anywhere
    case unknown                       // not yet evaluated
}

public struct DriftFinding: Sendable, Equatable {
    public enum Kind: String, Sendable { case unknown, missing, changed, corrupt }
    public let kind: Kind
    public let relPath: String
    public let recordedHash: String?   // manifest hash (missing/changed/corrupt)
    public let onDiskHash: String?     // re-hashed value (verify only)
    public let recordedSize: Int64?
    public let onDiskSize: Int64?
    public var recoverability: Recoverability
    public init(kind: Kind, relPath: String, recordedHash: String? = nil, onDiskHash: String? = nil,
                recordedSize: Int64? = nil, onDiskSize: Int64? = nil,
                recoverability: Recoverability = .unknown) {
        self.kind = kind; self.relPath = relPath; self.recordedHash = recordedHash
        self.onDiskHash = onDiskHash; self.recordedSize = recordedSize
        self.onDiskSize = onDiskSize; self.recoverability = recoverability
    }
}

public struct DriftReport: Sendable, Equatable {
    public var unknown: [DriftFinding] = []
    public var missing: [DriftFinding] = []
    public var changed: [DriftFinding] = []
    public var corrupt: [DriftFinding] = []
    public var presentHashes: Set<String> = []   // manifest hashes confirmed present (drives vault_presence)
    public var verified: Bool = false            // true when produced by a full re-hash
    public init() {}
    public var isClean: Bool { unknown.isEmpty && missing.isEmpty && changed.isEmpty && corrupt.isEmpty }
}

public struct DriftProgress: Sendable {
    public let done: Int
    public let total: Int
    public let currentName: String
    public init(done: Int, total: Int, currentName: String) {
        self.done = done; self.total = total; self.currentName = currentName
    }
}

public enum DriftError: Error, Equatable { case restoreFailed, notOnDisk }
```

- [ ] **Step 4: Implement scan** `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`:

```swift
import Foundation

public struct DriftReconciler: Sendable {
    public init() {}

    /// Enumerate the drive's media files (rel → (size, mtimeString)), mirroring Scanner's walk.
    static func walk(_ drive: Vault) -> [String: (size: Int64?, mtime: String)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var out: [String: (size: Int64?, mtime: String)] = [:]
        guard let en = fm.enumerator(at: drive.rootURL, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if url.lastPathComponent == Vault.stateDirName { en.skipDescendants() }
                continue
            }
            guard MediaKind.of(filename: url.lastPathComponent) != nil else { continue }
            out[drive.relativePath(of: url)] = (v.fileSize.map(Int64.init),
                ISO8601Millis.string(from: v.contentModificationDate ?? Date()))
        }
        return out
    }

    /// Fast drift scan — existence + size + mtime vs the manifest. No hashing.
    public func scan(drive: Vault) throws -> DriftReport {
        let manifest = try Manifest.read(from: drive.manifestURL)
        let onDisk = Self.walk(drive)
        let manifestPaths = Set(manifest.map(\.path))

        var report = DriftReport()
        for e in manifest {
            if let d = onDisk[e.path] {
                if let s = d.size, s == e.size, d.mtime == e.mtime {
                    report.presentHashes.insert(e.hash.stringValue)
                } else {
                    report.changed.append(DriftFinding(kind: .changed, relPath: e.path,
                        recordedHash: e.hash.stringValue, recordedSize: e.size, onDiskSize: d.size))
                }
            } else {
                report.missing.append(DriftFinding(kind: .missing, relPath: e.path,
                    recordedHash: e.hash.stringValue, recordedSize: e.size))
            }
        }
        for (rel, d) in onDisk where !manifestPaths.contains(rel) {
            report.unknown.append(DriftFinding(kind: .unknown, relPath: rel, onDiskSize: d.size))
        }
        // Stable order for deterministic UI/tests.
        report.missing.sort { $0.relPath < $1.relPath }
        report.unknown.sort { $0.relPath < $1.relPath }
        report.changed.sort { $0.relPath < $1.relPath }
        return report
    }
}
```

- [ ] **Step 5: Run green:** `swift test --filter DriftScanTests 2>&1 | tail -10` (2 pass). Full suite + warnings clean.

- [ ] **Step 6: Commit:**

```bash
git add Sources/OpenPhotoCore/Sync/DriftReport.swift Sources/OpenPhotoCore/Sync/DriftReconciler.swift Tests/OpenPhotoCoreTests/DriftScanTests.swift
git commit -m "feat(drift): DriftReport types + fast drift scan

Drive-scoped scan diffs manifest vs filesystem by existence+size+mtime (no
hashing) → unknown/missing/changed, plus presentHashes for honest presence.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3 (M2a): Recoverability via `PresenceService`

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`
- Test: `Tests/OpenPhotoCoreTests/DriftRecoverabilityTests.swift`

**Context:** for a missing/changed/corrupt finding with `recordedHash`, decide whether a good copy exists elsewhere. Reuse `PresenceService.locations(forHash:)` (Slice 1 made drives appear as `.confirmed` `.device` locations; the Mac appears as `.thisMac` confirmed from `catalog.instances`). Exclude this drive's own vault id.

- [ ] **Step 1: Write the failing test** `Tests/OpenPhotoCoreTests/DriftRecoverabilityTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func recoverableWhenHashIsOnAnotherVault() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    let v = try Vault.openOrCreate(at: try t.sub("pics"), role: .local)
    let imports = ImportRegistry(vault: v); let sends = SendRegistry(vault: v); let devices = DeviceRegistry(vault: v)
    let h = "sha256:" + String(repeating: "a", count: 64)
    // The hash also lives on another canonical drive (verified present there).
    try c.registerVault(id: "v-other", role: "canonical", rootPath: "/Volumes/Other")
    try c.replaceVaultPresence(vaultID: "v-other", hashes: [h])
    let presence = PresenceService(catalog: c, imports: imports, sends: sends, devices: devices)

    let r = DriftReconciler()
    #expect(r.recoverability(forHash: h, excludingVault: "v-this", presence: presence)
            == .recoverable(source: "Other"))
    #expect(r.recoverability(forHash: "sha256:" + String(repeating: "0", count: 64),
                             excludingVault: "v-this", presence: presence) == .lostNoCopy)
}
```

- [ ] **Step 2: Run red:** `swift test --filter DriftRecoverabilityTests 2>&1 | tail -20` → FAIL (`no member 'recoverability'`).

- [ ] **Step 3: Implement** — add to `DriftReconciler`:

```swift
    /// Is `hash` restorable from somewhere other than `excludingVault`?
    public func recoverability(forHash hash: String, excludingVault driveID: String,
                               presence: PresenceService) -> Recoverability {
        for loc in presence.locations(forHash: hash) where loc.confidence == .confirmed {
            switch loc.place {
            case .thisMac: return .recoverable(source: "This Mac")
            case .device(let key, let name, _): if key != driveID { return .recoverable(source: name) }
            }
        }
        return .lostNoCopy
    }

    /// Fill in `recoverability` on every missing/changed/corrupt finding in `report`.
    public func annotateRecoverability(_ report: inout DriftReport, driveID: String,
                                       presence: PresenceService) {
        func annotate(_ list: inout [DriftFinding]) {
            list = list.map { f in
                guard let h = f.recordedHash else { return f }
                var c = f
                c.recoverability = recoverability(forHash: h, excludingVault: driveID, presence: presence)
                return c
            }
        }
        annotate(&report.missing); annotate(&report.changed); annotate(&report.corrupt)
    }
```

- [ ] **Step 4: Run green:** `swift test --filter DriftRecoverabilityTests 2>&1 | tail -10` (1 pass). Full suite + warnings clean.

- [ ] **Step 5: Commit:**

```bash
git add Sources/OpenPhotoCore/Sync/DriftReconciler.swift Tests/OpenPhotoCoreTests/DriftRecoverabilityTests.swift
git commit -m "feat(drift): recoverability via PresenceService

Annotate missing/changed/corrupt findings as recoverable(source:) when a
confirmed copy exists on the Mac or another drive, else lostNoCopy.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4 (M2b): Safe repairs — adopt / restore / acknowledgeGone

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`
- Test: `Tests/OpenPhotoCoreTests/DriftRepairTests.swift`

**Context:** the only mutations in Slice 2. All edit the manifest atomically (`Manifest.read` → modify → `Manifest.write`) and never overwrite/remove a file. `restore` uses `VerifiedCopy` (Task 1) into an empty slot.

- [ ] **Step 1: Write the failing test** `Tests/OpenPhotoCoreTests/DriftRepairTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func driveWith(_ t: TestDirs, files: [String]) throws -> Vault {
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    var entries: [ManifestEntry] = []
    for rel in files {
        try makeJPEG(at: root.appendingPathComponent(rel).creatingParent(),
                     dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
        let url = root.appendingPathComponent(rel)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        entries.append(ManifestEntry(hash: try ContentHash.ofFile(at: url), path: rel,
            size: (a[.size] as? Int64) ?? 0,
            mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date())))
    }
    try Manifest.write(entries, to: drive.manifestURL)
    return drive
}

@Test func adoptAddsUnknownFileToManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg"])
    // a stray file on disk, not in the manifest
    try makeJPEG(at: drive.rootURL.appendingPathComponent("Pictures/stray.jpg"),
                 dateTimeOriginal: "2022:02:02 00:00:00", lat: nil, lon: nil)
    let hash = try DriftReconciler().adopt(relPath: "Pictures/stray.jpg", on: drive)
    let entries = try Manifest.read(from: drive.manifestURL)
    #expect(entries.contains { $0.path == "Pictures/stray.jpg" && $0.hash.stringValue == hash })
}

@Test func restoreCopiesGoodBytesIntoEmptySlot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg"])
    // the good source (e.g. on the Mac) and the recorded hash
    let recorded = try Manifest.read(from: drive.manifestURL).first { $0.path == "Pictures/a.jpg" }!
    let source = try t.file("mac/a.jpg", try Data(contentsOf:
        drive.rootURL.appendingPathComponent("Pictures/a.jpg")))
    // simulate "missing": delete it from the drive
    try FileManager.default.removeItem(at: drive.rootURL.appendingPathComponent("Pictures/a.jpg"))

    try DriftReconciler().restore(relPath: "Pictures/a.jpg", expectedHash: recorded.hash.stringValue,
                                  from: source, on: drive)
    let dest = drive.rootURL.appendingPathComponent("Pictures/a.jpg")
    #expect(try ContentHash.ofFile(at: dest).stringValue == recorded.hash.stringValue)
    #expect(try Manifest.read(from: drive.manifestURL).contains { $0.path == "Pictures/a.jpg" })
}

@Test func restoreThrowsWhenSourceBytesDontMatch() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg"])
    let recorded = try Manifest.read(from: drive.manifestURL).first!
    try FileManager.default.removeItem(at: drive.rootURL.appendingPathComponent("Pictures/a.jpg"))
    let badSource = try t.file("mac/bad.jpg", Data("not the right bytes".utf8))
    #expect(throws: DriftError.self) {
        try DriftReconciler().restore(relPath: "Pictures/a.jpg",
            expectedHash: recorded.hash.stringValue, from: badSource, on: drive)
    }
    #expect(!FileManager.default.fileExists(atPath:
        drive.rootURL.appendingPathComponent("Pictures/a.jpg").path))
}

@Test func acknowledgeGoneDropsManifestLine() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg", "Pictures/b.jpg"])
    try FileManager.default.removeItem(at: drive.rootURL.appendingPathComponent("Pictures/b.jpg"))
    try DriftReconciler().acknowledgeGone(relPath: "Pictures/b.jpg", on: drive)
    #expect(try Manifest.read(from: drive.manifestURL).map(\.path) == ["Pictures/a.jpg"])
}
```

- [ ] **Step 2: Run red:** `swift test --filter DriftRepairTests 2>&1 | tail -20` → FAIL (`no member 'adopt'`).

- [ ] **Step 3: Implement** — add to `DriftReconciler`:

```swift
    /// Add an on-disk file to the manifest (its content is recorded as authoritative). Returns the hash.
    @discardableResult
    public func adopt(relPath: String, on drive: Vault) throws -> String {
        let url = drive.absoluteURL(forRelativePath: relPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DriftError.notOnDisk }
        let hash = try ContentHash.ofFile(at: url).stringValue
        try writeManifestEntry(hash: hash, relPath: relPath, fileURL: url, on: drive)
        return hash
    }

    /// Copy a verified-good copy back into a missing slot, then record it. Never overwrites.
    public func restore(relPath: String, expectedHash: String, from source: URL, on drive: Vault) throws {
        let dest = drive.absoluteURL(forRelativePath: relPath)
        guard VerifiedCopy.copy(from: source, to: dest, expectedHash: expectedHash) else {
            throw DriftError.restoreFailed
        }
        try writeManifestEntry(hash: expectedHash, relPath: relPath, fileURL: dest, on: drive)
    }

    /// Drop an already-absent file from the manifest (records reality; deletes nothing).
    public func acknowledgeGone(relPath: String, on drive: Vault) throws {
        var entries = try Manifest.read(from: drive.manifestURL)
        entries.removeAll { $0.path == relPath }
        try Manifest.write(entries, to: drive.manifestURL)
    }

    private func writeManifestEntry(hash: String, relPath: String, fileURL: URL, on drive: Vault) throws {
        let a = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let entry = ManifestEntry(hash: ContentHash(stringValue: hash), path: relPath,
            size: (a[.size] as? Int64) ?? 0,
            mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date()))
        var entries = try Manifest.read(from: drive.manifestURL)
        entries.removeAll { $0.path == relPath }   // replace any stale line for this path
        entries.append(entry)
        try Manifest.write(entries, to: drive.manifestURL)
    }
```

- [ ] **Step 4: Run green:** `swift test --filter DriftRepairTests 2>&1 | tail -10` (4 pass). Full suite + warnings clean.

- [ ] **Step 5: Commit:**

```bash
git add Sources/OpenPhotoCore/Sync/DriftReconciler.swift Tests/OpenPhotoCoreTests/DriftRepairTests.swift
git commit -m "feat(drift): safe repairs — adopt, restore, acknowledgeGone

Additive only: adopt records an on-disk file; restore VerifiedCopy's a good copy
into an empty slot; acknowledgeGone drops a line for an already-absent file.
Nothing overwritten or deleted.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5 (M3): Verify Integrity (full re-hash → corrupt)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`
- Test: `Tests/OpenPhotoCoreTests/VerifyIntegrityTests.swift`

**Context:** re-hash every file; a path whose bytes don't match the recorded hash is `corrupt` if size+mtime still match (true bit-rot) or `changed` otherwise. `presentHashes` includes only hashes that verified. The bit-rot test must change bytes **without** changing size or mtime.

- [ ] **Step 1: Write the failing test** `Tests/OpenPhotoCoreTests/VerifyIntegrityTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func verifyDetectsBitRotWithUnchangedSizeAndMtime() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    let url = root.appendingPathComponent("Pictures/a.jpg")
    try makeJPEG(at: url.creatingParent(), dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
    let a0 = try FileManager.default.attributesOfItem(atPath: url.path)
    let savedMtime = (a0[.modificationDate] as? Date) ?? Date()
    let entry = ManifestEntry(hash: try ContentHash.ofFile(at: url), path: "Pictures/a.jpg",
        size: (a0[.size] as? Int64) ?? 0, mtime: ISO8601Millis.string(from: savedMtime))
    try Manifest.write([entry], to: drive.manifestURL)

    // Flip one byte in place WITHOUT changing length, then restore the mtime.
    let fh = try FileHandle(forUpdatingAtPath: url.path)!
    try fh.seek(toOffset: 0); let first = try fh.read(upToCount: 1) ?? Data([0])
    try fh.seek(toOffset: 0); try fh.write(contentsOf: Data([first[0] ^ 0xFF])); try fh.close()
    try FileManager.default.setAttributes([.modificationDate: savedMtime], ofItemAtPath: url.path)

    // Fast scan can't see it (size+mtime unchanged); verify can.
    #expect(try DriftReconciler().scan(drive: drive).corrupt.isEmpty)
    let report = try DriftReconciler().verify(drive: drive)
    #expect(report.corrupt.map(\.relPath) == ["Pictures/a.jpg"])
    #expect(report.presentHashes.isEmpty)
    #expect(report.verified == true)
}

@Test func verifyCleanDriveListsAllPresent() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    let url = root.appendingPathComponent("Pictures/a.jpg")
    try makeJPEG(at: url.creatingParent(), dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    try Manifest.write([ManifestEntry(hash: try ContentHash.ofFile(at: url), path: "Pictures/a.jpg",
        size: (a[.size] as? Int64) ?? 0,
        mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date()))],
        to: drive.manifestURL)
    let report = try DriftReconciler().verify(drive: drive)
    #expect(report.isClean)
    #expect(report.presentHashes.count == 1)
}
```

- [ ] **Step 2: Run red:** `swift test --filter VerifyIntegrityTests 2>&1 | tail -20` → FAIL (`no member 'verify'`).

- [ ] **Step 3: Implement** — add to `DriftReconciler`:

```swift
    /// Full integrity check — re-hash every file vs the manifest. Catches bit-rot (corrupt) on
    /// top of the fast findings. Slow; reports progress.
    public func verify(drive: Vault, progress: (DriftProgress) -> Void = { _ in }) throws -> DriftReport {
        let manifest = try Manifest.read(from: drive.manifestURL)
        let onDisk = Self.walk(drive)
        let manifestPaths = Set(manifest.map(\.path))

        var report = DriftReport()
        report.verified = true
        let total = manifest.count
        for (i, e) in manifest.enumerated() {
            progress(DriftProgress(done: i, total: total,
                                   currentName: (e.path as NSString).lastPathComponent))
            guard onDisk[e.path] != nil else {
                report.missing.append(DriftFinding(kind: .missing, relPath: e.path,
                    recordedHash: e.hash.stringValue, recordedSize: e.size)); continue
            }
            let url = drive.absoluteURL(forRelativePath: e.path)
            let actual = (try? ContentHash.ofFile(at: url).stringValue) ?? ""
            if actual == e.hash.stringValue {
                report.presentHashes.insert(e.hash.stringValue)
            } else {
                let d = onDisk[e.path]!
                let sameSizeAndTime = (d.size == e.size) && (d.mtime == e.mtime)
                let kind: DriftFinding.Kind = sameSizeAndTime ? .corrupt : .changed
                let finding = DriftFinding(kind: kind, relPath: e.path, recordedHash: e.hash.stringValue,
                    onDiskHash: actual.isEmpty ? nil : actual, recordedSize: e.size, onDiskSize: d.size)
                if kind == .corrupt { report.corrupt.append(finding) } else { report.changed.append(finding) }
            }
        }
        for (rel, d) in onDisk where !manifestPaths.contains(rel) {
            report.unknown.append(DriftFinding(kind: .unknown, relPath: rel, onDiskSize: d.size))
        }
        report.missing.sort { $0.relPath < $1.relPath }
        report.unknown.sort { $0.relPath < $1.relPath }
        report.changed.sort { $0.relPath < $1.relPath }
        report.corrupt.sort { $0.relPath < $1.relPath }
        return report
    }
```

- [ ] **Step 4: Run green:** `swift test --filter VerifyIntegrityTests 2>&1 | tail -10` (2 pass). Full suite + warnings clean.

- [ ] **Step 5: Commit:**

```bash
git add Sources/OpenPhotoCore/Sync/DriftReconciler.swift Tests/OpenPhotoCoreTests/VerifyIntegrityTests.swift
git commit -m "feat(drift): Verify Integrity full re-hash catches bit-rot

verify() re-hashes every file; a byte-mismatch with unchanged size+mtime is
corrupt (bit-rot), else changed. presentHashes holds only verified-good hashes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6 (M4a): AppState wiring — scan, verify, repairs, honest presence

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`
- (App layer — verify by clean build; no unit tests.)

**Context:** `AppState` already has `canonicalVaults`, `canonicalPresence`, `reloadCanonicalPresence()`, `refreshCanonicalPresence(driveVault:)` (Slice 1). Add drift operations that (a) produce a `DriftReport` for the UI, (b) set `vault_presence` to the report's `presentHashes` (honest badge), and (c) resolve a restore source URL from the catalog/presence.

- [ ] **Step 1: Add drift API to `AppState`:**

```swift
    /// Run a fast drift scan, set this drive's presence to verified reality, refresh badges.
    @discardableResult
    func driftScan(_ driveVault: Vault) -> DriftReport {
        guard let lib = library else { return DriftReport() }
        var report = (try? DriftReconciler().scan(drive: driveVault)) ?? DriftReport()
        if let p = presenceService() {
            DriftReconciler().annotateRecoverability(&report, driveID: driveVault.descriptor.vaultID, presence: p)
        }
        try? lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID,
                                              hashes: Array(report.presentHashes))
        reloadCanonicalPresence()
        return report
    }

    /// Full integrity check (slow); same presence/badge refresh as driftScan.
    func verifyIntegrity(_ driveVault: Vault,
                         progress: @escaping @Sendable (DriftProgress) -> Void) async -> DriftReport {
        guard let lib = library else { return DriftReport() }
        let report = await Task.detached(priority: .userInitiated) {
            (try? DriftReconciler().verify(drive: driveVault) { p in progress(p) }) ?? DriftReport()
        }.value
        var enriched = report
        if let p = presenceService() {
            DriftReconciler().annotateRecoverability(&enriched, driveID: driveVault.descriptor.vaultID, presence: p)
        }
        try? lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID,
                                              hashes: Array(report.presentHashes))
        reloadCanonicalPresence()
        return enriched
    }

    func adoptDriftFile(relPath: String, on driveVault: Vault) {
        try? DriftReconciler().adopt(relPath: relPath, on: driveVault)
        driftScan(driveVault)
    }

    func acknowledgeGone(relPath: String, on driveVault: Vault) {
        try? DriftReconciler().acknowledgeGone(relPath: relPath, on: driveVault)
        driftScan(driveVault)
    }

    /// Restore a missing file from its best available good copy; returns true on success.
    @discardableResult
    func restoreDriftFile(_ finding: DriftFinding, on driveVault: Vault) -> Bool {
        guard let lib = library, let hash = finding.recordedHash,
              let source = goodCopyURL(forHash: hash, excluding: driveVault.descriptor.vaultID) else { return false }
        do {
            try DriftReconciler().restore(relPath: finding.relPath, expectedHash: hash,
                                          from: source, on: driveVault)
            driftScan(driveVault); return true
        } catch { NSLog("restore failed: \(error)"); return false }
    }

    /// A reachable on-disk file with `hash` outside `driveID` — currently the Mac's local copy.
    private func goodCopyURL(forHash hash: String, excluding driveID: String) -> URL? {
        guard let lib = library, let inst = (try? lib.catalog.instances(forHash: hash))?
            .first(where: { $0.vaultID != driveID }),
              let vault = lib.vault(id: inst.vaultID) else { return nil }
        let url = vault.absoluteURL(forRelativePath: inst.relPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func presenceService() -> PresenceService? {
        guard let library, let imports = importRegistry, let sends = sendRegistry,
              let devices = deviceRegistry else { return nil }
        return PresenceService(catalog: library.catalog, imports: imports, sends: sends, devices: devices)
    }
```

(If `presenceService()` already exists privately in `AppState`, reuse it instead of adding a duplicate. `lib.vault(id:)` and `importRegistry`/`sendRegistry`/`deviceRegistry` already exist.)

- [ ] **Step 2: Build & verify:** `swift build 2>&1 | grep -i warning` (empty), `swift build 2>&1 | tail -3` (success), `swift test 2>&1 | tail -3` (unchanged pass count).

- [ ] **Step 3: Commit:**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): AppState drift scan/verify/repairs with honest presence

driftScan/verifyIntegrity set vault_presence to verified reality (badge can't
lie) and annotate recoverability; adopt/restore/acknowledge wrappers re-scan;
restore resolves the Mac's good copy via the catalog.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7 (M4b): DrivesView status + Verify button + DriftReviewSheet

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`
- Create: `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift`
- (App layer — verify by clean build + manual.)

- [ ] **Step 1: DriftReviewSheet** `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift`:

```swift
import SwiftUI
import OpenPhotoCore

struct DriftReviewSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @State var report: DriftReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drive changes — \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)
            Divider().overlay(Theme.hairline)
            if report.isClean {
                ContentUnavailableView("No changes", systemImage: "checkmark.seal",
                    description: Text("The drive matches OpenPhoto's record."))
            } else {
                List {
                    group("Unknown files (added outside OpenPhoto)", report.unknown) { f in
                        Button("Adopt") { state.adoptDriftFile(relPath: f.relPath, on: drive)
                            report = state.driftScan(drive) }
                    }
                    group("Missing files", report.missing) { f in
                        HStack(spacing: 8) {
                            recoverabilityLabel(f.recoverability)
                            if case .recoverable = f.recoverability {
                                Button("Restore") { _ = state.restoreDriftFile(f, on: drive)
                                    report = state.driftScan(drive) }
                            }
                            Button("Acknowledge gone") {
                                state.acknowledgeGone(relPath: f.relPath, on: drive)
                                report = state.driftScan(drive) }
                        }
                    }
                    group("Changed / corrupt (report only)", report.changed + report.corrupt) { f in
                        recoverabilityLabel(f.recoverability)
                    }
                }.listStyle(.inset)
            }
        }.frame(width: 600, height: 460)
    }

    @ViewBuilder private func group(_ title: String, _ items: [DriftFinding],
                                    @ViewBuilder trailing: @escaping (DriftFinding) -> some View) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.relPath) { f in
                    HStack { Text(f.relPath).font(.system(size: 12)); Spacer(); trailing(f) }
                }
            }
        }
    }

    @ViewBuilder private func recoverabilityLabel(_ r: Recoverability) -> some View {
        switch r {
        case .recoverable(let src): Text("restorable from \(src)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        case .lostNoCopy: Text("⚠️ no good copy — lost").font(.system(size: 11)).foregroundStyle(.red)
        case .unknown: EmptyView()
        }
    }
}
```

- [ ] **Step 2: Extend `DrivesView`.** Add state and wire the row. Add near the other `@State`:

```swift
    @State private var driftDrive: Vault?
    @State private var driftReport: DriftReport?
    @State private var verifying = false
```

In `row(_:)`, after the "Sync…" button (only when present), add:

```swift
            Button("Check") {
                if let v = state.openVault(for: vr) { driftReport = state.driftScan(v); driftDrive = v }
            }.controlSize(.small).disabled(!present)
            Button("Verify Integrity") {
                if let v = state.openVault(for: vr) {
                    verifying = true
                    Task {
                        let r = await state.verifyIntegrity(v) { _ in }
                        driftReport = r; driftDrive = v; verifying = false
                    }
                }
            }.controlSize(.small).disabled(!present || verifying)
```

Add the sheet to the `VStack` (alongside the existing `.sheet(item: $syncDrive)`):

```swift
        .sheet(item: $driftDrive) { drive in
            DriftReviewSheet(state: state, drive: drive, report: driftReport ?? DriftReport())
        }
```

(`Vault` is already `Identifiable` from Slice 1's sheet fix, so `.sheet(item:)` works.)

- [ ] **Step 3: Build & manual verify:** `swift build 2>&1 | grep -i warning` (empty); `scripts/make-app.sh && open build/OpenPhoto.app`. With a synced drive: delete a file from it in Finder, hit **Check** → it appears under "Missing" with "restorable from This Mac" + Restore/Acknowledge; add a stray image → "Unknown" + Adopt; **Verify Integrity** runs (re-hash) and reports clean or corrupt. Badges in Timeline correct after a missing file is acknowledged.

- [ ] **Step 4: Commit:**

```bash
git add Sources/OpenPhotoApp/Drives/DrivesView.swift Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift
git commit -m "feat(app): drift review UI — Check / Verify Integrity + review sheet

DrivesView gains Check (fast scan) and Verify Integrity buttons; DriftReviewSheet
groups findings with safe actions (adopt unknown, restore/acknowledge missing)
and shows recoverability; corrupt/changed are report-only.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review

1. **Spec coverage:** fast scan → Task 2; Verify Integrity/bit-rot → Task 5; finding types (unknown/missing/changed/corrupt) → Tasks 2,5; recoverability + down-to-last-copy data → Task 3; safe repairs (adopt/restore/acknowledge), report-only corrupt → Task 4; presence honesty (vault_presence = presentHashes) → Tasks 2,5,6; `VerifiedCopy` reuse → Task 1; UI (status, buttons, review sheet) → Task 7. Out-of-scope items (in-place replace, move-to-bin, local-vault verify, rename detection, verification-recency) intentionally absent.
2. **No placeholders:** every step has full code + exact commands.
3. **Type consistency:** `DriftReconciler.scan/verify/recoverability/annotateRecoverability/adopt/restore/acknowledgeGone`; `DriftReport{unknown,missing,changed,corrupt,presentHashes,verified,isClean}`; `DriftFinding{kind,relPath,recordedHash,onDiskHash,recordedSize,onDiskSize,recoverability}`; `Recoverability.recoverable(source:)/lostNoCopy/unknown`; `VerifiedCopy.copy(from:to:expectedHash:)`; `AppState.driftScan/verifyIntegrity/adoptDriftFile/acknowledgeGone/restoreDriftFile` — consistent across tasks. `Vault.relativePath(of:)`, `Vault.absoluteURL(forRelativePath:)`, `MediaKind.of(filename:)`, `ISO8601Millis`, `Catalog.replaceVaultPresence/instances(forHash:)`, `PresenceService.locations(forHash:)` all verified against the codebase.
4. **Non-destructive guarantee:** the only file write is `VerifiedCopy` into an absent path; no overwrite, move, or delete anywhere in this slice.
