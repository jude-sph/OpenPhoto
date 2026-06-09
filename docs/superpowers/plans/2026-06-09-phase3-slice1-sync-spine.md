# Phase 3 Slice 1 — Sync Spine (Mac → Canonical, Additive) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt a canonical drive, preview a sync plan, and apply an additive, hash-verified, resumable one-way sync (new originals + XMP sidecars) from the Mac's local vaults to the drive — then show per-asset "backed up on canonical" presence.

**Architecture:** A new `OpenPhotoCore/Sync/` module mirrors the existing `Send/` subsystem: a `DriveVolume` capability abstraction (so a folder, an exFAT disk image, and a real volume are interchangeable), a pure `SyncEngine` with a `plan(...)` step (zero writes) and an `apply(...)` step (atomic copy → fsync → re-hash verify → manifest rewrite → sync-log). Drive presence is recorded in a new isolated catalog table `vault_presence`; the existing `vaults`/`instances` tables and `timelineItems()` browse query are left unchanged so nothing double-counts. The App layer adds a **Drives** sidebar entry, an **Add Drive** picker, a **Sync plan** sheet (mirroring `SendSheet`), and a presence badge.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (CLT only), GRDB (SQLite), CryptoKit (SHA-256), Swift Testing (`@Test`/`#expect`). macOS 15.

---

## Intentional deviations from the design spec (§7), justified by the codebase

These refine the spec to match how the code actually works. They do **not** change Slice 1's scope or safety properties.

1. **No security-scoped bookmarks.** The app stores plain paths (`UserDefaults` for library roots; `NSOpenPanel` pickers) and never calls `startAccessingSecurityScopedResource`. So the spec's `RealVolume` (bookmark-backed) and `FolderVolume` collapse into **one** path-based `FileSystemVolume`, plus a test-only `FakeVolume` for injecting free-space. Drive persistence rides on the **catalog `vaults` table** (already persistent), keyed by `vault_id` read from `vault.json`; the mount path is updated on each connect.
2. **`vaults` table already exists** (`Catalog.swift` migration `v1`: `id, role, rootPath, lastSeenMs`) and `LibraryService` already calls `catalog.registerVault(...)`. We reuse it; migration **`v2`** only adds the new `vault_presence` table.
3. **Drive presence is isolated.** Drive contents are recorded in `vault_presence(vaultID, hash)` (from the drive's manifest) — **not** as rows in `instances` — so `timelineItems()` (one row per instance) is untouched and no browse row is duplicated. Drive-only/thumbnail-only browsing (assets with no local instance) is explicitly out of scope here; it arrives with eviction (Slice 4).
4. **No on-disk format change.** Slice 1 writes only existing structures: drive `vault.json` (format §3), drive `manifest.jsonl` (§4), `sync-log.jsonl` `sync` events (§9). `vault_presence` lives only in the rebuildable catalog. So `docs/format/vault-format-v1.md` needs no schema change (Task 11 adds one clarifying sentence only).

---

## File structure

**Create (Core):**
- `Sources/OpenPhotoCore/Sync/DriveVolume.swift` — `DriveVolume` protocol + `FileSystemVolume` concrete type + free-space helper.
- `Sources/OpenPhotoCore/Sync/SyncPlan.swift` — `PlanItem`, `SyncPlan`, `SyncResult`, `SyncError` value types.
- `Sources/OpenPhotoCore/Sync/SyncEngine.swift` — `plan(...)` (reconcile, zero writes) and `apply(...)` (atomic verified copy, manifest rewrite, sync-log).

**Create (App):**
- `Sources/OpenPhotoApp/Drives/DrivesView.swift` — the Drives screen (list, Add Drive, free space, Sync button).
- `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift` — plan preview → progress → result (mirrors `SendSheet`).

**Create (Tests):**
- `Tests/OpenPhotoCoreTests/DriveVolumeTests.swift`
- `Tests/OpenPhotoCoreTests/SyncPlanTests.swift`
- `Tests/OpenPhotoCoreTests/SyncApplyTests.swift`
- `Tests/OpenPhotoCoreTests/VaultPresenceTests.swift`
- `Tests/OpenPhotoCoreTests/SyncExfatImageTests.swift` — Tier-2 exFAT `.dmg` integration (skips if `hdiutil` unavailable).
- `Tests/OpenPhotoCoreTests/Helpers/makeFixtureLibrary.swift` — shared helper to build a scanned temp library (only if not already factored; otherwise reuse inline pattern).

**Modify (Core):**
- `Sources/OpenPhotoCore/Catalog/Catalog.swift` — add migration `v2` (`vault_presence`) + `replaceVaultPresence`, `vaultPresenceHashes`, `registeredVaults`, `setVaultLastSeen`.
- `Sources/OpenPhotoCore/Catalog/Queries.swift` — none required (presence methods live in `Catalog.swift` next to other writers); add read helpers here if preferred.
- `Sources/OpenPhotoCore/Presence/PresenceService.swift` — add drive vaults as `confirmed` locations; make `isOnlyOnThisMac` account for drive presence.

**Modify (App):**
- `Sources/OpenPhotoApp/AppState.swift` — `SidebarItem.drives`; drive list/adopt/sync API; canonical-presence cache + `isBackedUpOnCanonical(_:)`.
- `Sources/OpenPhotoApp/Sidebar/SidebarView.swift` — render `.drives`; route to `DrivesView`.
- `Sources/OpenPhotoApp/ContentView` (the main detail switch — confirm exact file during Task 7) — show `DrivesView` for `.drives`.
- `Sources/OpenPhotoApp/Timeline/PhotoCellView.swift` — optional `backedUp: Bool` → badge.
- `Sources/OpenPhotoApp/Timeline/TimelineView.swift` and `Sources/OpenPhotoApp/Folders/FolderGridView.swift` — pass `backedUp:` into the cell.

**Modify (Docs):**
- `docs/format/vault-format-v1.md` — one clarifying sentence (no schema change).
- `README.md`, `docs/superpowers/specs/2026-06-07-openphoto-design.md` — status/changelog.

---

## Conventions (every task)

- **TDD**: write the failing test first, run it red, implement minimally, run it green, commit.
- **Generated mock media only.** Never read `~/Pictures`, `~/Movies`, or any personal folder. All fixtures are made under `TestDirs` (system temp) via `makeJPEG`/`makeMOV` or raw `Data`.
- **0 compiler warnings.** After each task: `swift build 2>&1 | grep -i warning` must be empty.
- **Commit message** ends with the repo trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Run the whole suite before committing a task: `swift test 2>&1 | tail -5` (all pass).

---

## Task 1: `DriveVolume` abstraction + `FileSystemVolume`

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/DriveVolume.swift`
- Test: `Tests/OpenPhotoCoreTests/DriveVolumeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OpenPhotoCoreTests/DriveVolumeTests.swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func fileSystemVolumeReportsMountedAndFreeSpace() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let vol = FileSystemVolume(rootURL: root)
    #expect(vol.rootURL == root)
    #expect(vol.isMounted == true)
    #expect(try vol.freeSpaceBytes() > 0)
}

@Test func fileSystemVolumeNotMountedWhenMissing() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("openphoto-absent-" + UUID().uuidString)
    let vol = FileSystemVolume(rootURL: missing)
    #expect(vol.isMounted == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DriveVolumeTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'FileSystemVolume' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/OpenPhotoCore/Sync/DriveVolume.swift
import Foundation

/// A mounted location that may host an OpenPhoto vault. Abstracted so a plain
/// folder (CI), an attached exFAT disk image (realism), and a real removable
/// volume are interchangeable to the sync engine.
public protocol DriveVolume: Sendable {
    var rootURL: URL { get }
    var isMounted: Bool { get }
    func freeSpaceBytes() throws -> Int64
}

/// Path-backed volume — used for real volumes, attached `.dmg`s, and plain folders.
/// (This app uses plain paths, not security-scoped bookmarks, so one type covers all.)
public struct FileSystemVolume: DriveVolume {
    public let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL }

    public var isMounted: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func freeSpaceBytes() throws -> Int64 {
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage { return Int64(important) }
        if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        return 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DriveVolumeTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/DriveVolume.swift Tests/OpenPhotoCoreTests/DriveVolumeTests.swift
git commit -m "feat(sync): DriveVolume abstraction + FileSystemVolume

Path-backed volume capability (rootURL/isMounted/freeSpaceBytes) so a folder,
an exFAT disk image, and a real volume are interchangeable to the sync engine.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Catalog `vault_presence` table + accessors

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Test: `Tests/OpenPhotoCoreTests/VaultPresenceTests.swift`

**Context:** `Catalog.swift` already has migration `v1` and `registerVault(id:role:rootPath:)`. Add migration `v2` for `vault_presence` and accessors. Identity of a drive is its `vault_id`; the mount path is updated on connect via `setVaultLastSeen`/`registerVault`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OpenPhotoCoreTests/VaultPresenceTests.swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func makeCatalog(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}

@Test func registerAndListVaults() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    try c.registerVault(id: "v-local", role: "local", rootPath: "/tmp/pics")
    try c.registerVault(id: "v-canon", role: "canonical", rootPath: "/Volumes/Canonical")
    let all = try c.registeredVaults()
    #expect(Set(all.map(\.id)) == ["v-local", "v-canon"])
    #expect(all.first { $0.id == "v-canon" }?.role == "canonical")
}

@Test func replaceAndReadVaultPresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let h2 = "sha256:" + String(repeating: "2", count: 64)
    try c.replaceVaultPresence(vaultID: "v-canon", hashes: [h1, h2])
    #expect(try c.vaultPresenceHashes(forVault: "v-canon") == [h1, h2])
    // replace is a full swap, not append
    try c.replaceVaultPresence(vaultID: "v-canon", hashes: [h1])
    #expect(try c.vaultPresenceHashes(forVault: "v-canon") == [h1])
    #expect(try c.vaultPresenceHashes(forVault: "absent").isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VaultPresenceTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'Catalog' has no member 'registeredVaults'` (and `replaceVaultPresence`/`vaultPresenceHashes`).

- [ ] **Step 3: Write minimal implementation**

In `Catalog.swift`, add migration `v2` immediately after the `v1` registration (before `try migrator.migrate(dbQueue)`):

```swift
        migrator.registerMigration("v2") { db in
            // Presence of an asset hash in a NON-local vault (a drive), derived from
            // that vault's manifest. Local-vault presence already lives in `instances`.
            try db.create(table: "vault_presence") { t in
                t.column("vaultID", .text).notNull()
                t.column("hash", .text).notNull().indexed()
                t.primaryKey(["vaultID", "hash"])
            }
        }
```

Add these methods to `Catalog` (next to `registerVault`):

```swift
    public func registeredVaults() throws -> [VaultRecord] {
        try dbQueue.read { db in try VaultRecord.fetchAll(db) }
    }

    public func setVaultLastSeen(id: String, ms: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE vaults SET lastSeenMs = ? WHERE id = ?", arguments: [ms, id])
        }
    }

    /// Full swap of a vault's presence set (mirrors `replaceInstances`).
    public func replaceVaultPresence(vaultID: String, hashes: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [vaultID])
            for h in hashes {
                try db.execute(sql: "INSERT OR IGNORE INTO vault_presence (vaultID, hash) VALUES (?, ?)",
                               arguments: [vaultID, h])
            }
        }
    }

    public func vaultPresenceHashes(forVault vaultID: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db,
                sql: "SELECT hash FROM vault_presence WHERE vaultID = ?", arguments: [vaultID]))
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VaultPresenceTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift Tests/OpenPhotoCoreTests/VaultPresenceTests.swift
git commit -m "feat(catalog): vault_presence table + accessors (migration v2)

Records an asset hash's presence in a non-local (drive) vault, derived from
its manifest, isolated from instances so timeline browse never double-counts.
Adds registeredVaults/setVaultLastSeen/replaceVaultPresence/vaultPresenceHashes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `SyncPlan` types + `SyncEngine.plan(...)` (reconcile, zero writes)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/SyncPlan.swift`
- Create: `Sources/OpenPhotoCore/Sync/SyncEngine.swift`
- Test: `Tests/OpenPhotoCoreTests/SyncPlanTests.swift`

**Context — path mapping:** each source `Vault`'s assets mirror onto the drive under a top-level directory named by the source root's basename. For source vault at `…/Pictures`, asset `rome2022/IMG.heic` → drive path `Pictures/rome2022/IMG.heic`. Sidecars mirror to `Pictures/rome2022/.openphoto/IMG.heic.xmp`.

**Context — classification (additive, never overwrites):** for each source manifest entry (hash `H`, relPath `R`) with destRelPath `D`:
- `D` absent from the drive manifest **and** no file at `D` on disk → **copy**.
- `D` in the drive manifest with hash `== H` → **skip** (already present).
- `D` in the drive manifest with hash `!= H` → **conflict** (never overwritten; drift, Slice 2).
- `D` not in the drive manifest but a file exists at `D` on disk → hash it: `== H` → skip; else → conflict. (Only happens on resume after an interrupted run; keeps plan consistent with apply.)
- Sidecars: if the source sidecar exists and the dest sidecar is missing or byte-different → **sidecarUpdate**.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OpenPhotoCoreTests/SyncPlanTests.swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func scannedLibrary(_ t: TestDirs, _ name: String = "Pictures") throws -> LibraryService {
    let pics = try t.sub(name)
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as-" + name))
    return lib
}

@Test func planOnFreshDriveCopiesEverything() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.copies.count == 2)
    #expect(plan.conflicts.isEmpty)
    #expect(plan.totalCopyBytes > 0)
    // path mapping: basename prefix applied
    #expect(Set(plan.copies.map(\.destRelPath)) == ["Pictures/rome2022/IMG_1.jpg",
                                                     "Pictures/lisbon25/IMG_2.jpg"])
}

@Test func planAfterApplySkipsAll() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    _ = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                           destinationVault: drive, volume: vol)
    let plan2 = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan2.copies.isEmpty)
    #expect(plan2.conflicts.isEmpty)
}

@Test func planFlagsConflictOnDifferentBytesAtSamePath() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    // Pre-place a DIFFERENT file at one mapped dest path.
    let clash = drive.rootURL.appendingPathComponent("Pictures/rome2022/IMG_1.jpg")
    try FileManager.default.createDirectory(at: clash.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("not the same bytes".utf8).write(to: clash)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.conflicts.count == 1)
    #expect(plan.copies.count == 1) // the other file still copies
}

@Test func planIncludesSidecarUpdate() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    // Author a sidecar on one asset in the source vault.
    let v = lib.vaults.first!
    let store = SidecarStore(vault: v)
    try store.write(SidecarData(rating: 5, favorite: true, caption: "hi", tags: ["x"]),
                    forMediaRelPath: "rome2022/IMG_1.jpg")
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.sidecarUpdates.count == 1)
    #expect(plan.sidecarUpdates[0].destRelPath == "Pictures/rome2022/.openphoto/IMG_1.jpg.xmp")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SyncPlanTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SyncEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/OpenPhotoCore/Sync/SyncPlan.swift
import Foundation

public struct PlanItem: Sendable, Equatable {
    public let hash: String          // "" for sidecar items
    public let sourceURL: URL
    public let destRelPath: String   // drive-root-relative, "/" separators, NFC
    public let size: Int64
    public init(hash: String, sourceURL: URL, destRelPath: String, size: Int64) {
        self.hash = hash; self.sourceURL = sourceURL; self.destRelPath = destRelPath; self.size = size
    }
}

public struct SyncPlan: Sendable, Equatable {
    public var copies: [PlanItem] = []          // new originals (hash-verified on apply)
    public var sidecarUpdates: [PlanItem] = []  // XMP added/replaced (no hash gate)
    public var conflicts: [PlanItem] = []       // path exists with different bytes — reported, never touched
    public var totalCopyBytes: Int64 = 0
    public init() {}
}

public struct SyncResult: Sendable, Equatable {
    public var copied: Int = 0
    public var sidecarsWritten: Int = 0
    public var skipped: Int = 0
    public var conflicts: Int = 0
    public var failed: [PlanItem] = []
    public init() {}
}

public enum SyncError: Error, Equatable { case insufficientSpace(needed: Int64, free: Int64) }
```

```swift
// Sources/OpenPhotoCore/Sync/SyncEngine.swift
import Foundation

public struct SyncEngine: Sendable {
    let library: LibraryService
    public init(library: LibraryService) { self.library = library }

    /// Drive-relative path for a source asset: "<sourceRootBasename>/<relPath>", NFC.
    static func driveRelPath(forSourceVault v: Vault, relPath: String) -> String {
        (v.rootURL.lastPathComponent + "/" + relPath).precomposedStringWithCanonicalMapping
    }

    // MARK: Plan (zero writes)

    public func plan(sources: [Vault], destinationVault drive: Vault) throws -> SyncPlan {
        let fm = FileManager.default
        let driveEntries = try Manifest.read(from: drive.manifestURL)
        var driveByPath: [String: String] = [:]   // destRelPath -> hash
        for e in driveEntries { driveByPath[e.path] = e.hash.stringValue }

        var plan = SyncPlan()
        for v in sources {
            let entries = try Manifest.read(from: v.manifestURL)
            let store = SidecarStore(vault: v)
            for e in entries {
                let dest = Self.driveRelPath(forSourceVault: v, relPath: e.path)
                let srcURL = v.absoluteURL(forRelativePath: e.path)
                let destURL = drive.rootURL.appendingPathComponent(dest)

                if let known = driveByPath[dest] {
                    if known == e.hash.stringValue { plan.skippedClassify() }
                    else { plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                          destRelPath: dest, size: e.size)) }
                } else if fm.fileExists(atPath: destURL.path) {
                    // On disk but not in manifest (interrupted run): hash to classify.
                    let onDisk = (try? ContentHash.ofFile(at: destURL).stringValue) ?? ""
                    if onDisk == e.hash.stringValue { plan.skippedClassify() }
                    else { plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                          destRelPath: dest, size: e.size)) }
                } else {
                    plan.copies.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                destRelPath: dest, size: e.size))
                    plan.totalCopyBytes += e.size
                }

                // Sidecar (mirror if present and missing/different on the drive).
                let srcSidecar = v.sidecarURL(forMediaAt: srcURL)
                guard fm.fileExists(atPath: srcSidecar.path) else { continue }
                let destSidecarRel = Self.driveRelPath(forSourceVault: v,
                    relPath: (e.path as NSString).deletingLastPathComponent.isEmpty
                        ? ".openphoto/" + (e.path as NSString).lastPathComponent + ".xmp"
                        : (e.path as NSString).deletingLastPathComponent + "/.openphoto/"
                            + (e.path as NSString).lastPathComponent + ".xmp")
                let destSidecar = drive.rootURL.appendingPathComponent(destSidecarRel)
                let srcData = (try? Data(contentsOf: srcSidecar)) ?? Data()
                let destData = (try? Data(contentsOf: destSidecar))
                if destData != srcData {
                    plan.sidecarUpdates.append(PlanItem(hash: "", sourceURL: srcSidecar,
                        destRelPath: destSidecarRel, size: Int64(srcData.count)))
                }
            }
        }
        return plan
    }
}

private extension SyncPlan {
    mutating func skippedClassify() { /* counted at apply time; plan keeps copies/conflicts only */ }
}
```

> Note: `plan.copies` / `plan.conflicts` / `plan.sidecarUpdates` are the actionable lists; "skipped" is counted during `apply` (it's the difference between source entries and copies+conflicts). `skippedClassify()` is a no-op marker kept for readability.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SyncPlanTests 2>&1 | tail -20`
Expected: PASS (4 tests). (`planAfterApplySkipsAll` depends on `apply` from Task 4 — if implementing strictly in order, temporarily `#expect(true)` its body or run it after Task 4. Prefer: add a stub `apply` now (no `progress:` param, so `SyncProgress` need not exist until Task 4), then replace it in Task 4. The stub: `public func apply(_ plan: SyncPlan, destinationVault: Vault, volume: DriveVolume) async -> SyncResult { SyncResult() }`. Task 4 replaces it with the full implementation that adds a defaulted `progress:` parameter — source-compatible with this test's call site, which passes no progress.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/SyncPlan.swift Sources/OpenPhotoCore/Sync/SyncEngine.swift Tests/OpenPhotoCoreTests/SyncPlanTests.swift
git commit -m "feat(sync): SyncPlan types + SyncEngine.plan reconcile (zero writes)

Additive classification (copy/skip/conflict) with basename path mapping and
sidecar diffing; never proposes overwriting an existing drive file.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `SyncEngine.apply(...)` — atomic verified copy + manifest + sync-log (happy path)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/SyncEngine.swift`
- Modify: `Sources/OpenPhotoCore/Sync/SyncPlan.swift` (add `SyncProgress`)
- Test: `Tests/OpenPhotoCoreTests/SyncApplyTests.swift`

**Context:** mirror `VolumeCopyDestination`'s copy → `FileHandle.synchronize()` (fsync) → re-hash → verify → cleanup-on-mismatch. After the copy pass, rewrite the drive manifest atomically as (surviving prior entries whose files still exist) + (newly verified copies). Append a `sync` event to **both** the drive vault's and the Mac primary vault's `sync-log.jsonl` via `library.appendSyncLog`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OpenPhotoCoreTests/SyncApplyTests.swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func scannedLibrary(_ t: TestDirs, _ name: String = "Pictures") throws -> LibraryService {
    let pics = try t.sub(name)
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    return try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as-" + name))
}

@Test func applyCopiesVerifiesAndUpdatesManifest() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let result = await engine.apply(plan, destinationVault: drive, volume: vol)

    #expect(result.copied == 2)
    #expect(result.failed.isEmpty)
    // Files landed and verify byte-identical.
    let a = drive.rootURL.appendingPathComponent("Pictures/rome2022/IMG_1.jpg")
    let src = lib.vaults[0].rootURL.appendingPathComponent("rome2022/IMG_1.jpg")
    #expect(try Data(contentsOf: a) == (try Data(contentsOf: src)))
    // Drive manifest now lists both, with mapped paths.
    let entries = try Manifest.read(from: drive.manifestURL)
    #expect(Set(entries.map(\.path)) == ["Pictures/rome2022/IMG_1.jpg", "Pictures/lisbon25/IMG_2.jpg"])
    // sync-log written on the drive AND the Mac primary vault.
    #expect(FileManager.default.fileExists(atPath: drive.syncLogURL.path))
    #expect(FileManager.default.fileExists(atPath: lib.vaults[0].syncLogURL.path))
}

@Test func applyWritesSidecar() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    try SidecarStore(vault: lib.vaults[0]).write(
        SidecarData(rating: 4, favorite: false, caption: nil, tags: []),
        forMediaRelPath: "rome2022/IMG_1.jpg")
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let result = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                    destinationVault: drive, volume: vol)
    #expect(result.sidecarsWritten == 1)
    let destSidecar = drive.rootURL.appendingPathComponent("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: destSidecar.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SyncApplyTests 2>&1 | tail -20`
Expected: FAIL — `apply` returns empty stub `SyncResult` (`result.copied == 0`).

- [ ] **Step 3: Write minimal implementation**

Add `SyncProgress` to `SyncPlan.swift`:

```swift
public struct SyncProgress: Sendable {
    public enum Stage: String, Sendable { case copying, verifying, finishing }
    public let stage: Stage
    public let done: Int
    public let total: Int
    public let currentName: String
    public init(stage: Stage, done: Int, total: Int, currentName: String) {
        self.stage = stage; self.done = done; self.total = total; self.currentName = currentName
    }
}
```

Replace the `apply` stub in `SyncEngine.swift`:

```swift
    // MARK: Apply

    public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                      progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()
        result.conflicts = plan.conflicts.count

        // Free-space guard — never start a copy that will ENOSPC.
        if let free = try? volume.freeSpaceBytes(), free < plan.totalCopyBytes {
            result.failed = plan.copies
            return result
        }

        // Map of verified entries to write into the manifest (path -> ManifestEntry).
        var verified: [String: ManifestEntry] = [:]
        // Seed with prior manifest entries whose files still exist (additive).
        if let prior = try? Manifest.read(from: drive.manifestURL) {
            for e in prior where fm.fileExists(
                atPath: drive.rootURL.appendingPathComponent(e.path).path) {
                verified[e.path] = e
            }
        }

        let total = plan.copies.count
        for (i, item) in plan.copies.enumerated() {
            progress?(SyncProgress(stage: .copying, done: i, total: total,
                                   currentName: (item.destRelPath as NSString).lastPathComponent))
            let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
            do {
                // Resume pre-check: a file already at dest?
                if fm.fileExists(atPath: destURL.path) {
                    let onDisk = try ContentHash.ofFile(at: destURL).stringValue
                    if onDisk == item.hash {
                        verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                        result.skipped += 1; continue
                    } else {
                        result.failed.append(item); result.conflicts += 1; continue // never overwrite
                    }
                }
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                let tmp = destURL.deletingLastPathComponent()
                    .appendingPathComponent(".tmp-" + UUID().uuidString)
                defer { try? fm.removeItem(at: tmp) }  // no-op once moved into place
                try fm.copyItem(at: item.sourceURL, to: tmp)
                if let fh = try? FileHandle(forUpdating: tmp) {
                    _ = try? fh.synchronize(); try? fh.close()
                }
                let writtenHash = try ContentHash.ofFile(at: tmp).stringValue
                guard writtenHash == item.hash else { result.failed.append(item); continue }
                try fm.moveItem(at: tmp, to: destURL)  // atomic rename; dest is guaranteed absent here
                verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                result.copied += 1
            } catch {
                try? fm.removeItem(at: destURL) // cleanup partial
                result.failed.append(item)
            }
        }

        // Sidecars (no hash gate; not listed in the manifest).
        for item in plan.sidecarUpdates {
            let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
            do {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try AtomicFile.write(try Data(contentsOf: item.sourceURL), to: destURL)
                result.sidecarsWritten += 1
            } catch { result.failed.append(item) }
        }

        // Atomic manifest rewrite.
        progress?(SyncProgress(stage: .finishing, done: total, total: total, currentName: ""))
        try? Manifest.write(verified.values.sorted { $0.path < $1.path }, to: drive.manifestURL)

        // Sync-log on both ends.
        let summary = "\(result.copied) copied, \(result.skipped) skipped, " +
                      "\(result.sidecarsWritten) sidecars, \(result.conflicts) conflicts, " +
                      "\(result.failed.count) failed"
        library.appendSyncLog(vault: drive, event: "sync", summary: summary,
                              counterpartyKey: library.vaults.first?.descriptor.vaultID ?? "")
        if let mac = library.vaults.first {
            library.appendSyncLog(vault: mac, event: "sync", summary: summary,
                                  counterpartyKey: drive.descriptor.vaultID)
        }
        return result
    }

    static func manifestEntry(for item: PlanItem, at url: URL) throws -> ManifestEntry {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mDate = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return ManifestEntry(hash: ContentHash(stringValue: item.hash), path: item.destRelPath,
                             size: item.size, mtime: ISO8601Millis.string(from: mDate))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SyncApplyTests 2>&1 | tail -20`
Expected: PASS (2 tests). Also re-run Task 3: `swift test --filter SyncPlanTests` (the `planAfterApplySkipsAll` test now passes for real).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/SyncEngine.swift Sources/OpenPhotoCore/Sync/SyncPlan.swift Tests/OpenPhotoCoreTests/SyncApplyTests.swift
git commit -m "feat(sync): SyncEngine.apply — atomic verified copy, manifest, sync-log

Copy → fsync → re-hash → verify (cleanup on mismatch); sidecar mirror; atomic
manifest rewrite (surviving + verified); sync event on both drive and Mac vaults.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `apply` robustness — verify-mismatch cleanup, idempotency, resume, free-space guard

**Files:**
- Test: `Tests/OpenPhotoCoreTests/SyncApplyTests.swift` (add tests; impl already exists from Task 4)
- Create (test helper): a `FakeVolume` in the test file.

**Context:** these tests lock in the safety behaviors. Verify-mismatch is exercised by crafting a `PlanItem` with a deliberately wrong `hash`. The free-space guard uses a `FakeVolume` reporting tiny capacity.

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/OpenPhotoCoreTests/SyncApplyTests.swift

struct FakeVolume: DriveVolume {
    let rootURL: URL
    let free: Int64
    var isMounted: Bool { true }
    func freeSpaceBytes() throws -> Int64 { free }
}

@Test func applyVerifyMismatchIsCleanedAndFailed() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    var plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    // Corrupt one copy item's claimed hash so verify fails.
    let bad = plan.copies[0]
    plan.copies[0] = PlanItem(hash: "sha256:" + String(repeating: "f", count: 64),
                              sourceURL: bad.sourceURL, destRelPath: bad.destRelPath, size: bad.size)
    let result = await engine.apply(plan, destinationVault: drive, volume: vol)
    #expect(result.failed.contains(plan.copies[0]))
    // mismatched file removed, not left behind
    #expect(!FileManager.default.fileExists(
        atPath: drive.rootURL.appendingPathComponent(bad.destRelPath).path))
}

@Test func applyIsIdempotent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    _ = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                           destinationVault: drive, volume: vol)
    let again = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                   destinationVault: drive, volume: vol)
    #expect(again.copied == 0)
    #expect(again.failed.isEmpty)
}

@Test func applyResumesWithMatchingPartialAndNeverOverwritesDifferent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    // Pre-place the correct bytes for copies[0] (simulates a prior interrupted run, no manifest).
    let good = plan.copies[0]
    let goodDest = drive.rootURL.appendingPathComponent(good.destRelPath)
    try FileManager.default.createDirectory(at: goodDest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: good.sourceURL, to: goodDest)
    // Pre-place DIFFERENT bytes for copies[1].
    let other = plan.copies[1]
    let otherDest = drive.rootURL.appendingPathComponent(other.destRelPath)
    try FileManager.default.createDirectory(at: otherDest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("different".utf8).write(to: otherDest)

    let result = await engine.apply(plan, destinationVault: drive, volume: vol)
    #expect(result.skipped == 1)                 // good one recognised as done
    #expect(result.failed.contains(other))       // different one refused
    #expect(try Data(contentsOf: otherDest) == Data("different".utf8)) // untouched
}

@Test func applyBlocksOnInsufficientSpace() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let tiny = FakeVolume(rootURL: drive.rootURL, free: 1)
    let result = await engine.apply(plan, destinationVault: drive, volume: tiny)
    #expect(result.copied == 0)
    #expect(result.failed.count == plan.copies.count)
    // nothing written
    #expect(!FileManager.default.fileExists(
        atPath: drive.rootURL.appendingPathComponent(plan.copies[0].destRelPath).path))
}
```

- [ ] **Step 2: Run test to verify it fails/passes**

Run: `swift test --filter SyncApplyTests 2>&1 | tail -25`
Expected: the four new tests PASS against the Task-4 implementation. If any fails, fix `apply` minimally (do not weaken the never-overwrite rule). The likely fix points: ensure the resume pre-check `continue`s before any copy, and the free-space guard returns before the loop.

- [ ] **Step 3: (only if a test failed) adjust implementation** — see note above; otherwise skip.

- [ ] **Step 4: Run full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all pass; `swift build 2>&1 | grep -i warning` empty.

- [ ] **Step 5: Commit**

```bash
git add Tests/OpenPhotoCoreTests/SyncApplyTests.swift Sources/OpenPhotoCore/Sync/SyncEngine.swift
git commit -m "test(sync): apply safety — mismatch cleanup, idempotency, resume, ENOSPC

Locks in: verify mismatch is removed + failed; double-run is a no-op; a matching
partial resumes while differing bytes are never overwritten; tiny free space
blocks before any write.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: PresenceService — drive vaults as confirmed locations

**Files:**
- Modify: `Sources/OpenPhotoCore/Presence/PresenceService.swift`
- Test: `Tests/OpenPhotoCoreTests/PresenceServiceTests.swift` (add tests)

**Context:** `PresenceService` already holds `catalog`. Extend `locations(forHash:)` to append, for each registered non-local vault (`role != "local"`) whose `vault_presence` contains the hash, a `Location(place: .device(key: vaultID, name: <rootPath basename>, kind: .volume), confidence: .confirmed, detail: role)`. Make `isOnlyOnThisMac` return `false` when any such drive presence exists.

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/OpenPhotoCoreTests/PresenceServiceTests.swift
@Test func presenceIncludesDriveVaultAsConfirmed() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    let v = try Vault.openOrCreate(at: try t.sub("pics"), role: .local)
    let sends = SendRegistry(vault: v); let devices = DeviceRegistry(vault: v)
    let imports = ImportRegistry(vault: v)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try c.registerVault(id: "v-canon", role: "canonical", rootPath: "/Volumes/Canonical")
    try c.replaceVaultPresence(vaultID: "v-canon", hashes: [h])

    let svc = PresenceService(catalog: c, imports: imports, sends: sends, devices: devices)
    let locs = svc.locations(forHash: h)
    #expect(locs.contains { loc in
        if case .device(let key, _, _) = loc.place { return key == "v-canon" && loc.confidence == .confirmed }
        return false
    })
    #expect(svc.isOnlyOnThisMac(hash: h) == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PresenceServiceTests 2>&1 | tail -20`
Expected: FAIL — no drive location is produced; `isOnlyOnThisMac` returns `true`.

- [ ] **Step 3: Write minimal implementation**

In `PresenceService.locations(forHash:)`, after the catalog "This Mac" block and before/after the sends/imports blocks, add:

```swift
        // Registered drive vaults (confirmed) — presence derived from their manifests.
        if let vaults = try? catalog.registeredVaults() {
            for vr in vaults where vr.role != "local" {
                guard let present = try? catalog.vaultPresenceHashes(forVault: vr.id),
                      present.contains(hash), !seenDevices.contains(vr.id) else { continue }
                seenDevices.insert(vr.id)
                let name = (vr.rootPath as NSString).lastPathComponent
                out.append(Location(place: .device(key: vr.id, name: name, kind: .volume),
                                    confidence: .confirmed, detail: vr.role))
            }
        }
```

In `isOnlyOnThisMac(hash:)`, add a short-circuit: if any registered non-local vault's `vault_presence` contains the hash, return `false`. Implement by reusing the loop logic, e.g. before the existing return:

```swift
        if let vaults = try? catalog.registeredVaults() {
            for vr in vaults where vr.role != "local" {
                if let present = try? catalog.vaultPresenceHashes(forVault: vr.id),
                   present.contains(hash) { return false }
            }
        }
```

(Ensure `seenDevices` is declared before the new block in `locations`; it already exists in the current implementation.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PresenceServiceTests 2>&1 | tail -20`
Expected: PASS. Run full suite: `swift test 2>&1 | tail -5`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Presence/PresenceService.swift Tests/OpenPhotoCoreTests/PresenceServiceTests.swift
git commit -m "feat(presence): drive vaults appear as confirmed locations

locations(forHash:) includes registered non-local vaults whose vault_presence
holds the hash; isOnlyOnThisMac accounts for drive presence.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: AppState drive management + Drives sidebar + DrivesView

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`
- Modify: `Sources/OpenPhotoApp/Sidebar/SidebarView.swift`
- Modify: the main detail switch (find with `grep -rn "case .timeline" Sources/OpenPhotoApp` — likely `ContentView.swift` or `SidebarView`'s companion)
- Create: `Sources/OpenPhotoApp/Drives/DrivesView.swift`

**Context:** App-layer SwiftUI (built + manually verified, like the rest of the App layer — not unit-tested). Persistence of adopted drives rides on the catalog `vaults` table: `AppState` lists `library.catalog.registeredVaults()` filtered to `role == "canonical"`, and on Add-Drive opens/creates the vault, registers it, and loads its presence.

- [ ] **Step 1: Add the sidebar case**

In `AppState.swift`, extend `SidebarItem`:

```swift
enum SidebarItem: String, Hashable, CaseIterable {
    case timeline, folders, drives, bin
    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .folders: "Folders"
        case .drives: "Drives"
        case .bin: "Bin"
        }
    }
    var symbol: String {
        switch self {
        case .timeline: "photo.on.rectangle.angled"
        case .folders: "folder"
        case .drives: "externaldrive"
        case .bin: "trash"
        }
    }
}
```

- [ ] **Step 2: Add drive API to AppState**

Add to `AppState` (near the send/evict helpers):

```swift
    /// Adopted canonical drives, newest mount path from the catalog.
    var canonicalVaults: [VaultRecord] {
        (try? library?.catalog.registeredVaults().filter { $0.role == "canonical" }) ?? []
    }

    /// Cached presence set for the (single, Slice-1) canonical drive — drives the badge.
    private(set) var canonicalPresence: Set<String> = []

    func driveIsPresent(_ vr: VaultRecord) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: vr.rootPath, isDirectory: &isDir) && isDir.boolValue
    }

    func isBackedUpOnCanonical(_ item: TimelineItem) -> Bool { canonicalPresence.contains(item.hash) }

    /// Pick a folder/volume and adopt it as the canonical drive.
    func addDriveViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Canonical Drive"
        panel.message = "Choose a drive or folder to hold your canonical library."
        guard panel.runModal() == .OK, let url = panel.url, let lib = library else { return }
        do {
            let vault = try Vault.openOrCreate(at: url, role: .canonical)
            try lib.catalog.registerVault(id: vault.descriptor.vaultID,
                                          role: vault.descriptor.role.rawValue, rootPath: url.path)
            try refreshCanonicalPresence(driveVault: vault)
        } catch { NSLog("addDrive failed: \(error)") }
    }

    /// Read the drive's manifest into vault_presence and refresh the badge cache.
    func refreshCanonicalPresence(driveVault: Vault) throws {
        guard let lib = library else { return }
        let hashes = (try? Manifest.read(from: driveVault.manifestURL))?.map { $0.hash.stringValue } ?? []
        try lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID, hashes: hashes)
        canonicalPresence = Set(hashes)
    }

    func openVault(for vr: VaultRecord) -> Vault? {
        try? Vault.openOrCreate(at: URL(fileURLWithPath: vr.rootPath), role: .canonical)
    }
```

Load the badge cache when the library opens (in `openLibrary`/after `scanAll`):

```swift
        if let canon = canonicalVaults.first, let v = openVault(for: canon), driveIsPresent(canon) {
            try? refreshCanonicalPresence(driveVault: v)
        }
```

- [ ] **Step 3: Create DrivesView**

```swift
// Sources/OpenPhotoApp/Drives/DrivesView.swift
import SwiftUI
import OpenPhotoCore

struct DrivesView: View {
    @Bindable var state: AppState
    @State private var showSync = false
    @State private var syncDrive: Vault?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drives").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Add Drive…") { state.addDriveViaPanel() }.controlSize(.small)
            }
            .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if state.canonicalVaults.isEmpty {
                ContentUnavailableView("No canonical drive yet",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("Add a drive or folder to hold your canonical library."))
            } else {
                List(state.canonicalVaults, id: \.id) { vr in
                    row(vr)
                }.listStyle(.inset)
            }
        }
        .sheet(isPresented: $showSync) {
            if let drive = syncDrive { SyncPlanSheet(state: state, drive: drive) }
        }
    }

    @ViewBuilder private func row(_ vr: VaultRecord) -> some View {
        let present = state.driveIsPresent(vr)
        HStack(spacing: 12) {
            Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(Theme.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text((vr.rootPath as NSString).lastPathComponent).font(.system(size: 13.5, weight: .semibold))
                Text(present ? "Connected · \(vr.rootPath)" : "Not connected")
                    .font(.system(size: 11)).foregroundStyle(present ? Theme.textDim : Theme.textFaint)
            }
            Spacer()
            Button("Sync…") {
                if let v = state.openVault(for: vr) { syncDrive = v; showSync = true }
            }.controlSize(.small).disabled(!present)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 4: Route the sidebar to DrivesView**

In `SidebarView` the `SidebarItem.allCases` loop already renders `.drives`. In the detail switch (the file found via grep in Files above), add:

```swift
            case .drives: DrivesView(state: state)
```

- [ ] **Step 5: Build & manual verify**

Run: `swift build 2>&1 | grep -i warning` → empty. `swift build` succeeds.
Manual: `scripts/make-app.sh && open build/OpenPhoto.app` — Drives entry appears; "Add Drive…" opens a picker; choosing an empty temp folder lists it as a connected canonical drive with a Sync button. (SyncPlanSheet is wired in Task 8 — until then the button may present an empty sheet; acceptable mid-slice.)

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Sidebar/SidebarView.swift Sources/OpenPhotoApp/Drives/DrivesView.swift Sources/OpenPhotoApp/*ContentView*.swift
git commit -m "feat(app): Drives sidebar + Add Drive adoption + presence cache

SidebarItem.drives; AppState adopts a canonical drive (open/create vault.json,
register in catalog, load vault_presence) and caches the badge presence set.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: SyncPlanSheet — plan preview → progress → result

**Files:**
- Create: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`

**Context:** mirrors `SendSheet`. Computes the plan on appear (zero writes), shows counts + bytes + free-space check + conflicts, runs `apply` on confirm with progress, then a result summary. On success it calls `state.refreshCanonicalPresence` so badges update.

- [ ] **Step 1: Create SyncPlanSheet**

```swift
// Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift
import SwiftUI
import OpenPhotoCore

struct SyncPlanSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var plan: SyncPlan?
    @State private var freeBytes: Int64 = 0
    @State private var progress: SyncProgress?
    @State private var result: SyncResult?
    @State private var running = false

    private var volume: FileSystemVolume { FileSystemVolume(rootURL: drive.rootURL) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync to \((drive.rootURL.lastPathComponent))")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }.disabled(running)
            }.padding(16)
            Divider().overlay(Theme.hairline)
            Group {
                if let result { resultView(result) }
                else if let p = progress { progressView(p) }
                else if let plan { planView(plan) }
                else { ProgressView().padding(24) }
            }.frame(maxHeight: .infinity)
        }
        .frame(width: 540, height: 360)
        .task { await computePlan() }
    }

    private func computePlan() async {
        let engine = SyncEngine(library: state.library!)
        let p = try? engine.plan(sources: state.library!.vaults, destinationVault: drive)
        plan = p ?? SyncPlan()
        freeBytes = (try? volume.freeSpaceBytes()) ?? 0
    }

    @ViewBuilder private func planView(_ plan: SyncPlan) -> some View {
        let enough = freeBytes >= plan.totalCopyBytes
        VStack(alignment: .leading, spacing: 10) {
            Text("\(plan.copies.count) new photos · \(byteString(plan.totalCopyBytes))")
                .font(.system(size: 14, weight: .medium))
            Text("\(plan.sidecarUpdates.count) metadata sidecars")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            if plan.conflicts.count > 0 {
                Label("\(plan.conflicts.count) conflicts skipped (different file already on drive)",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Text("Free space: \(byteString(freeBytes))")
                .font(.system(size: 12)).foregroundStyle(enough ? Theme.textDim : .red)
            Spacer()
            HStack {
                Spacer()
                Button("Sync") { Task { await runApply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enough || (plan.copies.isEmpty && plan.sidecarUpdates.isEmpty))
            }
        }.padding(24)
    }

    @ViewBuilder private func progressView(_ p: SyncProgress) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(Theme.accent)
            Text("\(p.stage.rawValue.capitalized)… \(p.done)/\(p.total) · \(p.currentName)")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
        }.padding(24)
    }

    @ViewBuilder private func resultView(_ r: SyncResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync complete").font(.system(size: 14, weight: .semibold))
            Text("\(r.copied) copied · \(r.skipped) already there · \(r.sidecarsWritten) sidecars")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            if r.conflicts > 0 || !r.failed.isEmpty {
                Text("\(r.conflicts) conflicts · \(r.failed.count) failed")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24)
    }

    private func runApply() async {
        guard !running, let plan else { return }
        running = true
        let engine = SyncEngine(library: state.library!)
        let r = await engine.apply(plan, destinationVault: drive, volume: volume) { p in
            Task { @MainActor in progress = p }
        }
        try? state.refreshCanonicalPresence(driveVault: drive)
        result = r
        running = false
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
```

- [ ] **Step 2: Build & manual verify**

Run: `swift build 2>&1 | grep -i warning` → empty.
Manual: `scripts/make-app.sh && open build/OpenPhoto.app`. With a scanned library and an empty temp folder added as a drive: Drives → Sync… shows "N new photos · size", Free space line, Sync button; after Sync the result summary appears and the temp folder now contains `Pictures/…` plus `.openphoto/manifest.jsonl`. Re-opening Sync… shows 0 new photos (idempotent).

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift
git commit -m "feat(app): SyncPlanSheet — dry-run preview, free-space check, apply

Mirrors SendSheet: shows copies/bytes/conflicts + free space, runs the verified
apply with progress, refreshes canonical presence on completion.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: "Backed up on canonical" badge

**Files:**
- Modify: `Sources/OpenPhotoApp/Timeline/PhotoCellView.swift`
- Modify: `Sources/OpenPhotoApp/Timeline/TimelineView.swift`
- Modify: `Sources/OpenPhotoApp/Folders/FolderGridView.swift`

**Context:** add an optional `backedUp: Bool` to `PhotoCellView` and render a small glyph; cell builders pass `state.isBackedUpOnCanonical(item)`.

- [ ] **Step 1: Add the badge param + overlay to PhotoCellView**

```swift
struct PhotoCellView: View {
    let item: TimelineItem
    let library: LibraryService
    var targetPixel: Int = ThumbnailStore.maxPixel
    var backedUp: Bool = false

    var body: some View {
        ThumbView(item: item, library: library, targetPixel: targetPixel)
            // …existing live/video/favorite overlays unchanged…
            .overlay(alignment: .bottomLeading) {
                if backedUp {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 2).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))
            .contentShape(Rectangle())
    }
    // …badge(...) helper unchanged…
}
```

- [ ] **Step 2: Pass `backedUp:` from the cell builders**

In `TimelineView.cell(_:)` and `FolderGridView`'s cell builder, update the `PhotoCellView(...)` call:

```swift
            .overlay { PhotoCellView(item: item, library: state.library!,
                                     targetPixel: thumbPixels,
                                     backedUp: state.isBackedUpOnCanonical(item)) }
```

- [ ] **Step 3: Build & manual verify**

Run: `swift build 2>&1 | grep -i warning` → empty.
Manual: after a sync, timeline + folder cells for synced photos show the small drive-check glyph; unsynced ones don't. (The cache `canonicalPresence` is refreshed by Task 8's apply and at library open.)

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Timeline/PhotoCellView.swift Sources/OpenPhotoApp/Timeline/TimelineView.swift Sources/OpenPhotoApp/Folders/FolderGridView.swift
git commit -m "feat(app): backed-up-on-canonical badge on grid cells

PhotoCellView gains a backedUp flag; timeline/folder cells pass
state.isBackedUpOnCanonical(item) to show a small drive-check glyph.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Tier-2 exFAT disk-image integration test

**Files:**
- Create: `Tests/OpenPhotoCoreTests/SyncExfatImageTests.swift`

**Context:** a real attached exFAT filesystem (via `hdiutil`) exercises mount, exFAT semantics, and a real `apply`. It must **skip cleanly** where `hdiutil`/attach is unavailable (restricted CI) rather than fail. Use a small helper that creates + attaches a `.dmg`, returns the mount point, and detaches in `defer`.

- [ ] **Step 1: Write the test (self-skipping)**

```swift
// Tests/OpenPhotoCoreTests/SyncExfatImageTests.swift
import Testing
import Foundation
@testable import OpenPhotoCore

@discardableResult
private func run(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

/// Create + attach a small exFAT image; returns (mountPoint, devNode) or nil if unavailable.
private func attachExfatImage(_ t: TestDirs, sizeMB: Int = 48) throws -> (URL, String)? {
    let dmg = t.root.appendingPathComponent("drive.dmg")
    let create = run(["hdiutil", "create", "-size", "\(sizeMB)m", "-fs", "ExFAT",
                      "-volname", "OPCanon", "-ov", dmg.path])
    guard create.status == 0 else { return nil }
    let attach = run(["hdiutil", "attach", dmg.path, "-nobrowse"])
    guard attach.status == 0 else { return nil }
    // Parse "/dev/diskNsM ... /Volumes/OPCanon"
    for line in attach.out.split(separator: "\n") {
        if line.contains("/Volumes/") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let mount = cols.last, mount.hasPrefix("/Volumes/"),
               let dev = cols.first(where: { $0.hasPrefix("/dev/") }) {
                return (URL(fileURLWithPath: mount), dev)
            }
        }
    }
    return nil
}

@Test func syncToRealExfatImage() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    guard let (mount, dev) = try attachExfatImage(t) else { return } // skip if unavailable
    defer { _ = run(["hdiutil", "detach", dev, "-force"]) }

    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()

    let driveRoot = mount.appendingPathComponent("OpenPhoto")
    let drive = try Vault.openOrCreate(at: driveRoot, role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: driveRoot)
    let result = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                    destinationVault: drive, volume: vol)
    #expect(result.copied == 1)
    #expect(result.failed.isEmpty)
    let dest = driveRoot.appendingPathComponent("Pictures/rome/IMG_1.jpg")
    #expect(try Data(contentsOf: dest) == (try Data(contentsOf:
        pics.appendingPathComponent("rome/IMG_1.jpg"))))
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter SyncExfatImageTests 2>&1 | tail -20`
Expected: PASS locally (creates/attaches a real exFAT image, syncs one verified file, detaches). In an environment without `hdiutil`/attach permission it returns early and still PASSES (skip).

- [ ] **Step 3: Commit**

```bash
git add Tests/OpenPhotoCoreTests/SyncExfatImageTests.swift
git commit -m "test(sync): Tier-2 exFAT disk-image integration (self-skipping)

Creates+attaches a real exFAT .dmg, runs a verified plan+apply against it,
detaches. Skips cleanly where hdiutil/attach is unavailable.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Docs — format clarification + status

**Files:**
- Modify: `docs/format/vault-format-v1.md`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

**Context:** Slice 1 introduces no new on-disk structure, but it makes the Mac a writer of a canonical drive vault. Add one clarifying sentence; update status/changelog. (Catalog `vault_presence` is rebuildable — not normative format — so it is *not* added to the format doc.)

- [ ] **Step 1: Format doc clarification**

In `docs/format/vault-format-v1.md` §1, after the sentence about a drive carrying one vault mirroring source roots, add:

```markdown
The Mac writes a canonical drive's vault following the third-party-writer rules in §10:
each top-level directory mirrors a Mac vault root by its basename (`Pictures/`, `Movies/`),
originals are added but never overwritten, and the manifest is rewritten atomically after
each sync. No fields beyond those already specified here are used.
```

- [ ] **Step 2: README + design-spec status**

In `README.md` Status section, add a Phase 3 line:

```markdown
- **Phase 3 — Drives (in progress):** Slice 1 — additive one-way sync (Mac → canonical drive): adopt a drive, preview a plan, hash-verified resumable copy, "backed up on canonical" presence. See `docs/superpowers/specs/2026-06-09-phase3-drives-design.md`.
```

In `docs/superpowers/specs/2026-06-07-openphoto-design.md` §10, change the Phase 3 line to mark Slice 1 underway, and add a changelog entry:

```markdown
- **2026-06-09** — Phase 3 (Drives) started. Slice 1 (sync spine) implemented: `DriveVolume` abstraction, `SyncEngine` plan/apply (additive Mac→canonical, atomic + hash-verified + resumable, never overwrites), catalog `vault_presence` (migration v2), drive vaults as confirmed locations in `PresenceService`, Drives sidebar + Add-Drive + Sync plan sheet + "backed up on canonical" badge. Three-tier tests (temp-dir + exFAT dmg). Detailed plan: `docs/superpowers/plans/2026-06-09-phase3-slice1-sync-spine.md`.
```

- [ ] **Step 3: Verify build/tests still green, commit**

Run: `swift test 2>&1 | tail -5` (all pass); `swift build 2>&1 | grep -i warning` (empty).

```bash
git add docs/format/vault-format-v1.md README.md docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: Phase 3 Slice 1 — format writer note + status/changelog

Clarifies that the Mac writes a canonical drive per the §10 third-party-writer
rules (no new fields); marks Slice 1 in README + design-spec changelog.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review (run after implementing)

1. **Spec coverage (§7):** M0 DriveVolume → Task 1; identity/adoption → Tasks 2,7; path mapping → Task 3; reconcile/plan + free-space → Tasks 3,8; atomic verified resumable apply → Tasks 4,5; manifest rewrite + sync-log → Task 4; catalog vaults/presence → Tasks 2,6; UI (Drives, plan sheet, badge) → Tasks 7,8,9; test matrix (temp-dir + exFAT) → Tasks 1–6,10; format-doc impact → Task 11. All §7.9 milestones covered.
2. **No silent caps:** the plan reports conflicts in the UI (Task 8) and never overwrites; nothing is truncated silently.
3. **Type consistency:** `SyncEngine.plan(sources:destinationVault:)`, `apply(_:destinationVault:volume:progress:)`, `SyncPlan{copies,sidecarUpdates,conflicts,totalCopyBytes}`, `SyncResult{copied,sidecarsWritten,skipped,conflicts,failed}`, `PlanItem{hash,sourceURL,destRelPath,size}`, `DriveVolume{rootURL,isMounted,freeSpaceBytes()}`, `FileSystemVolume`, `FakeVolume`, catalog `replaceVaultPresence/vaultPresenceHashes/registeredVaults/setVaultLastSeen`, `AppState.isBackedUpOnCanonical/canonicalPresence/refreshCanonicalPresence/addDriveViaPanel`, `PhotoCellView.backedUp` — all used consistently across tasks.
4. **Out of scope (verify not crept in):** rename detection, deletion propagation, drift repair, evict/rehydrate, send-from-drive, clone/migration, catalog snapshot, Sources filter, drive-only browsing — none implemented here.
