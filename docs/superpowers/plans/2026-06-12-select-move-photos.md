# Select & Move Photos (Folders screen) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Folders screen's Select mode, move the selected photos into another folder — by dragging onto the left folder tree or via a destination dropdown + Move button — with files, sidecars, and Live-pair partners physically moving in the vault and mirroring to durable drives.

**Architecture:** A new file-grain `VaultReorganizer.moveFile` primitive (atomic rename + sidecar + one manifest-entry rewrite) is batched by `LibraryService.movePhotos` (Live-pair carry), orchestrated by `AppState.movePhotos(ids:into:)` which mirrors `AppState+FolderReorg` exactly: Mac vault first, connected durable drives now (exact-target moves keep basenames aligned), offline drives queued as `"moveFile"` ops in the existing `pending_folder_ops` table, drive-only items re-keyed in `vault_presence`, one rescan at the end.

**Tech Stack:** Swift 6, SwiftPM (Command Line Tools ONLY — `swift build` / `swift test`, NO Xcode), SwiftUI (macOS 15), GRDB. Spec: `docs/superpowers/specs/2026-06-12-select-move-photos-design.md`.

---

## Hard rules (every task)

- Build/test ONLY with `swift build` / `swift test` (CLT). Never invoke Xcode or xcodebuild.
- **0 warnings**: both `swift build 2>&1 | grep -i warning` and `swift build --build-tests 2>&1 | grep -i warning` must print nothing.
- Every commit message ends with the trailer line: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- NEVER access `~/Pictures`, `~/Movies`, or any personal folder. All test media is generated (`makeJPEG` / raw `Data`) inside `TestDirs` temp dirs. `Documents/tests/OpenPhoto-drive` is REAL user data — never touch it.
- No catalog `schemaVersion` bump in this slice (currently 11 — unchanged). No vault format change.
- Branch: `phase5.5-move-photos` (already created off `main`).

## File map

| File | Change |
|---|---|
| `Sources/OpenPhotoCore/Vault/FileNaming.swift` | **Create** — shared collision-free naming |
| `Sources/OpenPhotoCore/Import/ImportEngine.swift` | Modify — use FileNaming (delete private dup) |
| `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift` | Modify — use FileNaming (delete private dup) |
| `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift` | Modify — add `moveFile` (2 variants) |
| `Sources/OpenPhotoCore/Catalog/Queries.swift` | Modify — add `items(instanceIDs:)` |
| `Sources/OpenPhotoCore/Catalog/Catalog.swift` | Modify — add `vaultPresenceRelPath`, `rewriteVaultPresencePath` |
| `Sources/OpenPhotoCore/LibraryService+Move.swift` | **Create** — `MoveResult` + `movePhotos(_:toDir:)` |
| `Sources/OpenPhotoCore/Selection/PhotoMovePayload.swift` | **Create** — drag-payload codec |
| `Sources/OpenPhotoApp/AppState.swift` | Modify — add `photoMoveToken` |
| `Sources/OpenPhotoApp/AppState+FolderReorg.swift` | Modify — `movePhotos(ids:into:)` + `"moveFile"` replay |
| `Sources/OpenPhotoApp/Selection/SelectionUI.swift` | Modify — `moveControls` slot on SelectionActionBar |
| `Sources/OpenPhotoApp/Folders/FolderGridView.swift` | Modify — move controls, drag-to-move, payload drags |
| `Sources/OpenPhotoApp/Folders/FolderTreeView.swift` | Modify — photo-payload drop branches |
| `Tests/OpenPhotoCoreTests/FileNamingTests.swift` | **Create** |
| `Tests/OpenPhotoCoreTests/VaultReorganizerTests.swift` | Modify — moveFile tests |
| `Tests/OpenPhotoCoreTests/CatalogMoveQueriesTests.swift` | **Create** |
| `Tests/OpenPhotoCoreTests/MovePhotosTests.swift` | **Create** |
| `Tests/OpenPhotoCoreTests/PhotoMovePayloadTests.swift` | **Create** |
| `docs/format/catalog-schema.md` | Modify — `"moveFile"` op kind (Task 8) |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` | Modify — §10.5 + changelog (Task 8) |

Existing context an implementer needs:
- `Vault.sidecarURL(forMediaAt:)`: `rome2022/IMG_1.heic` → `rome2022/.openphoto/IMG_1.heic.xmp` (`Sources/OpenPhotoCore/Vault/Vault.swift:20`).
- `Manifest.read/write` (atomic) in `Sources/OpenPhotoCore/Vault/Manifest.swift`; `VaultReorganizer` already has `norm(_:)` and `ReorgError`.
- `TimelineItem.instanceID == vaultID + "|" + relPath`; drive-only rows have `driveRelPath != nil` (`Sources/OpenPhotoCore/Catalog/Records.swift:86-114`).
- `TestDirs` helper (`Tests/OpenPhotoCoreTests/TestDirs.swift`); `makeJPEG(at:dateTimeOriginal:lat:lon:)` (`MetadataExtractorTests.swift:10`); `URL.creatingParent()` (`ScannerTests.swift:24`).

---

### Task 1: `FileNaming` — shared collision-free naming (Core, TDD)

The identical private `collisionFreeURL` lives in `ImportEngine.swift:153-165` and `VolumeCopyDestination.swift:91-103`. Extract it; both callers switch to the shared helper; `moveFile` (Task 2) reuses it.

**Files:**
- Create: `Sources/OpenPhotoCore/Vault/FileNaming.swift`
- Create: `Tests/OpenPhotoCoreTests/FileNamingTests.swift`
- Modify: `Sources/OpenPhotoCore/Import/ImportEngine.swift:108,152-165`
- Modify: `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift:44,90-103`

- [ ] **Step 1: Write the failing test**

`Tests/OpenPhotoCoreTests/FileNamingTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func collisionFreeNamesSuffixUntilFree() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("d")
    // Free name passes through untouched.
    #expect(FileNaming.collisionFreeURL(for: "x.jpg", in: dir).lastPathComponent == "x.jpg")
    try Data("a".utf8).write(to: dir.appendingPathComponent("x.jpg"))
    #expect(FileNaming.collisionFreeURL(for: "x.jpg", in: dir).lastPathComponent == "x (2).jpg")
    try Data("b".utf8).write(to: dir.appendingPathComponent("x (2).jpg"))
    #expect(FileNaming.collisionFreeURL(for: "x.jpg", in: dir).lastPathComponent == "x (3).jpg")
    // Extension-less names suffix the bare base.
    try Data("c".utf8).write(to: dir.appendingPathComponent("README"))
    #expect(FileNaming.collisionFreeURL(for: "README", in: dir).lastPathComponent == "README (2)")
}
```

- [ ] **Step 2: Run it — must FAIL to compile** (`FileNaming` doesn't exist)

Run: `swift test --filter FileNamingTests 2>&1 | tail -5`
Expected: compile error `cannot find 'FileNaming' in scope`

- [ ] **Step 3: Create the helper**

`Sources/OpenPhotoCore/Vault/FileNaming.swift`:

```swift
import Foundation

/// Collision-safe placement names — shared by import placement, volume send, and file moves.
enum FileNaming {
    /// IMG_1.JPG → IMG_1 (2).JPG → IMG_1 (3).JPG …
    static func collisionFreeURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(suffixed)
            n += 1
        }
        return candidate
    }
}
```

- [ ] **Step 4: Switch both existing callers; delete the duplicates**

In `Sources/OpenPhotoCore/Import/ImportEngine.swift`: change line 108 from `let target = collisionFreeURL(for: s.item.name, in: dirURL)` to `let target = FileNaming.collisionFreeURL(for: s.item.name, in: dirURL)`, and DELETE the whole private method (lines 152-165, the comment line `/// IMG_1.JPG → …` through its closing brace).

In `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift`: change line 44 from `let target = collisionFreeURL(for: item.displayName, in: folderURL)` to `let target = FileNaming.collisionFreeURL(for: item.displayName, in: folderURL)`, and DELETE the private method (lines 90-103, the comment `/// IMG_1.JPG → IMG_1 (2).JPG … (mirror of ImportEngine's collision-safe naming).` through its closing brace).

- [ ] **Step 5: Full test suite + warning check**

Run: `swift test 2>&1 | tail -3` → all tests pass (import/send behavior unchanged).
Run: `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Vault/FileNaming.swift Tests/OpenPhotoCoreTests/FileNamingTests.swift Sources/OpenPhotoCore/Import/ImportEngine.swift Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift
git commit -m "refactor: extract shared FileNaming.collisionFreeURL from ImportEngine + VolumeCopyDestination

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `VaultReorganizer.moveFile` (Core, TDD)

File-grain sibling of `moveFolder`: atomic rename + sidecar travel + ONE manifest-entry rewrite. Two variants — into-dir (collision-free basename; Mac's initial move) and exact-target (drive propagation reuses the Mac's final basename so paths stay aligned).

**Files:**
- Modify: `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift`
- Modify: `Tests/OpenPhotoCoreTests/VaultReorganizerTests.swift` (append tests; the file already has a private `seed(_:relPath:bytes:)` helper)

- [ ] **Step 1: Write the failing tests** (append to `VaultReorganizerTests.swift`)

```swift
// MARK: - moveFile (file-grain)

private func sidecarSeed(_ vault: Vault, mediaRelPath: String) throws -> URL {
    let sc = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: mediaRelPath))
    try FileManager.default.createDirectory(at: sc.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("xmp".utf8).write(to: sc)
    return sc
}

@Test func moveFileMovesMediaSidecarAndManifestEntry() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    let h = try seed(vault, relPath: "a/x.jpg")
    let other = try seed(vault, relPath: "a/y.jpg", bytes: "other")
    let oldSidecar = try sidecarSeed(vault, mediaRelPath: "a/x.jpg")
    try Manifest.write([
        ManifestEntry(hash: h, path: "a/x.jpg", size: 1, mtime: ISO8601Millis.string(from: Date())),
        ManifestEntry(hash: other, path: "a/y.jpg", size: 5, mtime: ISO8601Millis.string(from: Date())),
    ], to: vault.manifestURL)

    let newRel = try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", intoDirRelPath: "b/sub")

    #expect(newRel == "b/sub/x.jpg")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/sub/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    // Sidecar traveled into the destination's .openphoto dir.
    let newSidecar = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: "b/sub/x.jpg"))
    #expect(FileManager.default.fileExists(atPath: newSidecar.path))
    #expect(!FileManager.default.fileExists(atPath: oldSidecar.path))
    // Exactly the one manifest entry rewritten; the sibling untouched.
    let byPath = Dictionary(uniqueKeysWithValues: try Manifest.read(from: vault.manifestURL).map { ($0.path, $0) })
    #expect(byPath["b/sub/x.jpg"]?.hash == h && byPath["b/sub/x.jpg"]?.size == 1)
    #expect(byPath["a/y.jpg"]?.hash == other)
    #expect(byPath.count == 2)
}

@Test func moveFileCollisionRenamesMediaAndSidecarTogether() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    let h = try seed(vault, relPath: "a/x.jpg")
    _ = try seed(vault, relPath: "b/x.jpg", bytes: "occupied")
    _ = try sidecarSeed(vault, mediaRelPath: "a/x.jpg")
    try Manifest.write([ManifestEntry(hash: h, path: "a/x.jpg", size: 1,
                        mtime: ISO8601Millis.string(from: Date()))], to: vault.manifestURL)

    let newRel = try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", intoDirRelPath: "b")

    #expect(newRel == "b/x (2).jpg")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/x (2).jpg").path))
    // Sidecar name matches the collision-adjusted media name.
    let newSidecar = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: "b/x (2).jpg"))
    #expect(FileManager.default.fileExists(atPath: newSidecar.path))
    let entries = try Manifest.read(from: vault.manifestURL)
    #expect(entries.count == 1 && entries[0].path == "b/x (2).jpg")
}

@Test func moveFileSameDirIsNoOpAndMissingThrows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    _ = try seed(vault, relPath: "a/x.jpg")
    #expect(try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", intoDirRelPath: "a") == "a/x.jpg")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    #expect(throws: (any Error).self) {
        try VaultReorganizer.moveFile(in: vault, relPath: "a/gone.jpg", intoDirRelPath: "b")
    }
}

@Test func moveFileExactTargetKeepsAlignedNameAndRootMovesWork() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    _ = try seed(vault, relPath: "a/x.jpg")
    // Exact target: the basename is taken verbatim (drive mirrors the Mac's "(2)" rename).
    let newRel = try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", toRelPath: "b/x (2).jpg")
    #expect(newRel == "b/x (2).jpg")
    // Into the vault root ("" dir).
    _ = try seed(vault, relPath: "c/y.jpg")
    #expect(try VaultReorganizer.moveFile(in: vault, relPath: "c/y.jpg", intoDirRelPath: "") == "y.jpg")
}
```

- [ ] **Step 2: Run them — must FAIL to compile** (`moveFile` doesn't exist)

Run: `swift test --filter VaultReorganizerTests 2>&1 | tail -5`

- [ ] **Step 3: Implement** (append inside `enum VaultReorganizer`, after `moveFolder`)

```swift
    /// Move ONE media file into another folder, collision-safe. The file's
    /// `.openphoto/<name>.xmp` sidecar travels with it (renamed to match any
    /// collision-adjusted basename) and its single manifest entry is rewritten.
    /// Finder-tag xattrs ride along (same-volume rename). Returns the final relPath.
    @discardableResult
    public static func moveFile(in vault: Vault, relPath: String,
                                intoDirRelPath dir: String) throws -> String {
        let src = norm(relPath)
        guard !src.isEmpty else { throw ReorgError.invalidTarget }
        let name = (src as NSString).lastPathComponent
        let dstDir = norm(dir)
        return try moveFile(in: vault, relPath: src,
                            toRelPath: dstDir.isEmpty ? name : dstDir + "/" + name)
    }

    /// Exact-target variant — drive propagation reuses the Mac's final basename so
    /// Mac and drive paths stay aligned; collision-adjusts only if the target is
    /// occupied on THIS vault.
    @discardableResult
    public static func moveFile(in vault: Vault, relPath: String,
                                toRelPath target: String) throws -> String {
        let src = norm(relPath)
        var dst = norm(target)
        guard !src.isEmpty, !dst.isEmpty else { throw ReorgError.invalidTarget }
        if dst == src { return src }   // already there — no-op
        let fm = FileManager.default
        let srcURL = vault.absoluteURL(forRelativePath: src)
        guard fm.fileExists(atPath: srcURL.path) else { throw ReorgError.missing }
        var dstURL = vault.absoluteURL(forRelativePath: dst)
        let dstDirURL = dstURL.deletingLastPathComponent()
        try fm.createDirectory(at: dstDirURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dstURL.path) {
            dstURL = FileNaming.collisionFreeURL(for: dstURL.lastPathComponent, in: dstDirURL)
            dst = vault.relativePath(of: dstURL)
        }
        try fm.moveItem(at: srcURL, to: dstURL)
        // Sidecar travels with the media, renamed to match the final basename.
        let srcSidecar = vault.sidecarURL(forMediaAt: srcURL)
        if fm.fileExists(atPath: srcSidecar.path) {
            let dstSidecar = vault.sidecarURL(forMediaAt: dstURL)
            try fm.createDirectory(at: dstSidecar.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: dstSidecar)   // stale sidecar with no media — garbage
            try fm.moveItem(at: srcSidecar, to: dstSidecar)
        }
        try rewriteManifestEntry(vault, from: src, to: dst)
        return dst
    }

    private static func rewriteManifestEntry(_ vault: Vault, from old: String, to new: String) throws {
        let entries = try Manifest.read(from: vault.manifestURL)
        guard entries.contains(where: { $0.path == old }) else { return }  // not cataloged yet — rescan adopts it
        try Manifest.write(entries.map { e in
            e.path == old ? ManifestEntry(hash: e.hash, path: new, size: e.size, mtime: e.mtime) : e
        }, to: vault.manifestURL)
    }
```

- [ ] **Step 4: Run tests** — `swift test --filter VaultReorganizerTests 2>&1 | tail -3` → PASS. Then full `swift test 2>&1 | tail -3` + both warning greps → clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Vault/VaultReorganizer.swift Tests/OpenPhotoCoreTests/VaultReorganizerTests.swift
git commit -m "feat: VaultReorganizer.moveFile — per-photo atomic move with sidecar + manifest rewrite

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Catalog — instanceID resolution + file-grain presence rekey (Core, TDD)

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Queries.swift` (after `items(inDir:vaultID:recursive:)`, ~line 84)
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift` (after `rewriteVaultPresencePaths`, ~line 384)
- Create: `Tests/OpenPhotoCoreTests/CatalogMoveQueriesTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/OpenPhotoCoreTests/CatalogMoveQueriesTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private func hash64(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }

@Test func itemsByInstanceIDResolvesLocalAndDriveRows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let hLocal = hash64("a"); let hDrive = hash64("b")
    try cat.upsert(assets: [asset(hLocal), asset(hDrive)])
    try cat.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: hLocal, vaultID: "mac", relPath: "a/x.jpg",
                       dirPath: "a", size: 1, mtimeMs: 1)])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: hDrive, relPath: "b/y.jpg", dirPath: "b",
                           size: 1, driveRelPath: "V/b/y.jpg")])

    let items = try cat.items(instanceIDs: ["mac|a/x.jpg", "drive|b/y.jpg", "mac|nope.jpg"])
    #expect(Set(items.map(\.hash)) == [hLocal, hDrive])
    #expect(items.first { $0.hash == hDrive }?.driveRelPath == "V/b/y.jpg")
    #expect(items.first { $0.hash == hLocal }?.driveRelPath == nil)
    #expect(try cat.items(instanceIDs: []).isEmpty)
}

@Test func presenceRelPathLookupAndFileGrainRekey() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = hash64("c")
    try cat.upsert(assets: [asset(h)])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: h, relPath: "a/x.jpg", dirPath: "a",
                           size: 1, driveRelPath: "V/a/x.jpg")])

    #expect(try cat.vaultPresenceRelPath(vaultID: "drive", hash: h) == "a/x.jpg")
    #expect(try cat.vaultPresenceRelPath(vaultID: "other", hash: h) == nil)

    try cat.rewriteVaultPresencePath(vaultID: "drive", fromRelPath: "a/x.jpg", toRelPath: "b/c/x.jpg")
    let rows = try cat.vaultPresenceRows(forVault: "drive")
    #expect(rows.count == 1)
    #expect(rows[0].relPath == "b/c/x.jpg" && rows[0].dirPath == "b/c"
            && rows[0].driveRelPath == "V/b/c/x.jpg")
    // Drive-only browse rows follow immediately — no rescan needed.
    #expect(try cat.items(inDir: "b/c").map(\.hash) == [h])
    #expect(try cat.items(inDir: "a").isEmpty)
}

@Test func moveFileOpRoundTripsThroughFolderOpQueue() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    _ = try cat.enqueueFolderOp(vaultID: "drive", op: "moveFile", src: "a/x.jpg", dst: "b/x.jpg")
    let ops = try cat.pendingFolderOps(forVault: "drive")
    #expect(ops.count == 1 && ops[0].op == "moveFile"
            && ops[0].src == "a/x.jpg" && ops[0].dst == "b/x.jpg")
    try cat.clearFolderOp(id: ops[0].id)
    #expect(try cat.pendingFolderOps(forVault: "drive").isEmpty)
}
```

(The third test pins the `"moveFile"` op-kind string through the existing queue — no production change needed for it; it documents that the TEXT `op` column carries the new kind.)

- [ ] **Step 2: Run — must FAIL to compile.** `swift test --filter CatalogMoveQueriesTests 2>&1 | tail -5`

- [ ] **Step 3: Implement**

In `Queries.swift`, after `items(inDir:vaultID:recursive:)`:

```swift
    /// Resolve grid instanceIDs ("<vaultID>|<relPath>") back to browse rows — local
    /// instances and drive-only presence rows alike. Order is not preserved.
    public func items(instanceIDs: [String]) throws -> [TimelineItem] {
        guard !instanceIDs.isEmpty else { return [] }
        return try dbQueue.read { db in
            let marks = databaseQuestionMarks(count: instanceIDs.count)
            return try TimelineItem.fetchAll(db, sql: """
                SELECT * FROM (\(Self.timelineSQL)) WHERE vaultID || '|' || relPath IN (\(marks))
                """, arguments: StatementArguments(instanceIDs))
        }
    }
```

In `Catalog.swift`, directly after `rewriteVaultPresencePaths` (~line 384):

```swift
    /// The presence-row relPath for one asset on one drive — Live-pair partner
    /// resolution for drive-only moves. Nil when the drive has no row for the hash.
    public func vaultPresenceRelPath(vaultID: String, hash: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT relPath FROM vault_presence WHERE vaultID = ? AND hash = ? LIMIT 1
                """, arguments: [vaultID, hash])
        }
    }

    /// File-grain sibling of `rewriteVaultPresencePaths`: re-key ONE drive's presence row
    /// after a per-photo move (`fromRelPath` → `toRelPath`, both Mac-aligned). Pure catalog
    /// op; the drive's file is moved now (connected) or queued (offline) by the caller.
    public func rewriteVaultPresencePath(vaultID: String, fromRelPath: String,
                                         toRelPath: String) throws {
        let from = fromRelPath.precomposedStringWithCanonicalMapping
        let to = toRelPath.precomposedStringWithCanonicalMapping
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS rid, driveRelPath FROM vault_presence
                WHERE vaultID = ? AND relPath = ?
                """, arguments: [vaultID, from])
            for row in rows {
                let rid: Int64 = row["rid"]
                let oldDriveRel: String = row["driveRelPath"]
                // Same suffix-swap as the dir-grain rewrite (prefixed + unprefixed shapes).
                let newDriveRel = oldDriveRel.hasSuffix(from)
                    ? String(oldDriveRel.dropLast(from.count)) + to
                    : oldDriveRel
                try db.execute(sql: """
                    UPDATE vault_presence SET relPath = ?, dirPath = ?, driveRelPath = ?
                    WHERE rowid = ?
                    """, arguments: [to, (to as NSString).deletingLastPathComponent,
                                     newDriveRel, rid])
            }
        }
    }
```

- [ ] **Step 4: Run tests** — filter PASS, then full `swift test` + both warning greps clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Queries.swift Sources/OpenPhotoCore/Catalog/Catalog.swift Tests/OpenPhotoCoreTests/CatalogMoveQueriesTests.swift
git commit -m "feat: catalog instanceID resolution + file-grain vault_presence rekey for photo moves

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `LibraryService.movePhotos` — batch + Live-pair carry (Core, TDD)

**Files:**
- Create: `Sources/OpenPhotoCore/LibraryService+Move.swift`
- Create: `Tests/OpenPhotoCoreTests/MovePhotosTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/OpenPhotoCoreTests/MovePhotosTests.swift` (real generated JPEGs so `scanAll` catalogs them; `makeJPEG` + `creatingParent()` already exist in the test target):

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// Library over one temp vault with `n` scanned JPEGs in folder "a".
/// Distinct EXIF dates → distinct bytes → distinct hashes.
private func makeLibrary(_ t: TestDirs, files: [String]) async throws -> (LibraryService, Vault) {
    let root = try t.sub("vault")
    for (i, rel) in files.enumerated() {
        try makeJPEG(at: root.appendingPathComponent(rel).creatingParent(),
                     dateTimeOriginal: "2022:10:07 14:23:0\(i)", lat: nil, lon: nil)
    }
    let lib = try LibraryService(vaultRoots: [root], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    return (lib, lib.vaults[0])
}

@Test func movePhotosMovesFileAndCatalogFollowsAfterRescan() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg"])
    let items = try lib.items(inDir: "a")
    #expect(items.count == 1)

    let result = lib.movePhotos(items, toDir: "b")

    #expect(result.moved == ["a/x.jpg": "b/x.jpg"])
    #expect(result.failures.isEmpty)
    try await lib.rescan(vaultID: vault.descriptor.vaultID)
    #expect(try lib.items(inDir: "a").isEmpty)
    #expect(try lib.items(inDir: "b").map(\.relPath) == ["b/x.jpg"])
}

@Test func movePhotosCarriesLivePairPartnerWithSidecars() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    // Two scanned assets; we declare them a Live pair in the catalog (the carry logic
    // only follows livePairHash — media kind is irrelevant to the move mechanics).
    let (lib, vault) = try await makeLibrary(t, files: ["a/IMG_1.jpg", "a/IMG_1X.jpg"])
    let pre = try lib.items(inDir: "a")
    let photoHash = pre.first { $0.relPath == "a/IMG_1.jpg" }!.hash
    let videoHash = pre.first { $0.relPath == "a/IMG_1X.jpg" }!.hash
    try lib.catalog.setLivePair(photoHash: photoHash, videoHash: videoHash)
    // Sidecars for both halves.
    for rel in ["a/IMG_1.jpg", "a/IMG_1X.jpg"] {
        let sc = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel))
        try FileManager.default.createDirectory(at: sc.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("xmp".utf8).write(to: sc)
    }
    // Re-fetch: the partner is now hidden; the photo row carries livePairHash.
    let item = try #require(try lib.items(inDir: "a").first { $0.hash == photoHash })
    #expect(item.livePairHash == videoHash)

    let result = lib.movePhotos([item], toDir: "b")

    #expect(result.moved["a/IMG_1.jpg"] == "b/IMG_1.jpg")
    #expect(result.moved["a/IMG_1X.jpg"] == "b/IMG_1X.jpg")   // partner traveled
    for rel in ["b/IMG_1.jpg", "b/IMG_1X.jpg"] {
        #expect(FileManager.default.fileExists(
            atPath: vault.absoluteURL(forRelativePath: rel).path))
        #expect(FileManager.default.fileExists(
            atPath: vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel)).path))
    }
    try await lib.rescan(vaultID: vault.descriptor.vaultID)
    #expect(try lib.items(inDir: "b").count == 1)   // pair shows as one browse row
}

@Test func movePhotosSkipsInDestCollectsFailuresAndContinues() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg", "a/y.jpg", "b/z.jpg"])
    // Make a/x.jpg vanish behind the catalog's back.
    try FileManager.default.removeItem(at: vault.absoluteURL(forRelativePath: "a/x.jpg"))
    let items = try lib.items(inDir: "a") + (try lib.items(inDir: "b"))

    let result = lib.movePhotos(items, toDir: "b")

    #expect(result.moved == ["a/y.jpg": "b/y.jpg"])          // z already in dest → skipped
    #expect(result.failures.keys.contains("a/x.jpg"))         // vanished → failure, batch continued
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/z.jpg").path))
}
```

- [ ] **Step 2: Run — must FAIL to compile.** `swift test --filter MovePhotosTests 2>&1 | tail -5`

- [ ] **Step 3: Implement**

`Sources/OpenPhotoCore/LibraryService+Move.swift`:

```swift
import Foundation

/// Outcome of a per-photo move batch.
public struct MoveResult: Sendable, Equatable {
    /// old relPath → new relPath, for every file actually moved (incl. Live partners).
    public var moved: [String: String] = [:]
    /// relPath → human-readable reason, for files that could not move.
    public var failures: [String: String] = [:]
    public init() {}
}

extension LibraryService {
    /// Move local instances into `dest` (vault-root-relative dir, "" = root), each within
    /// its own vault. Carries each Live pair's hidden video half (and both sidecars),
    /// mirroring `delete()`. Items already in `dest` and drive-only items are skipped.
    /// Collects failures and keeps going. Does NOT rescan — the caller orchestrates
    /// (drive propagation first, then one rescan).
    public func movePhotos(_ items: [TimelineItem], toDir dest: String) -> MoveResult {
        var result = MoveResult()
        let destDir = dest.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for item in items {
            guard item.driveRelPath == nil else { continue }     // drive-only: caller's job
            guard item.dirPath != destDir else { continue }      // already there
            guard let vault = vault(id: item.vaultID) else {
                result.failures[item.relPath] = "vault not open"; continue
            }
            do {
                result.moved[item.relPath] = try VaultReorganizer.moveFile(
                    in: vault, relPath: item.relPath, intoDirRelPath: destDir)
            } catch {
                result.failures[item.relPath] = String(describing: error); continue
            }
            // Best-effort: the Live pair's video travels too (mirrors delete()).
            if let pairHash = item.livePairHash,
               let pair = try? catalog.instanceItem(hash: pairHash, vaultID: item.vaultID),
               pair.dirPath != destDir,
               let newRel = try? VaultReorganizer.moveFile(in: vault, relPath: pair.relPath,
                                                           intoDirRelPath: destDir) {
                result.moved[pair.relPath] = newRel
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests** — filter PASS, then full `swift test` + both warning greps clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService+Move.swift Tests/OpenPhotoCoreTests/MovePhotosTests.swift
git commit -m "feat: LibraryService.movePhotos — batch per-photo move with Live-pair carry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `PhotoMovePayload` drag codec (Core, TDD)

Folder rows accept `String` drops (folder paths). Photo drags share that channel: `"photos:" + JSON([instanceID])`. Decode succeeding ⇒ photo drop; nil ⇒ treat as folder path.

**Files:**
- Create: `Sources/OpenPhotoCore/Selection/PhotoMovePayload.swift`
- Create: `Tests/OpenPhotoCoreTests/PhotoMovePayloadTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func photoMovePayloadRoundTripsAndRejectsFolderPaths() throws {
    let ids = ["vault-1|2025/rome/IMG_1.jpg", "vault-1|2025/rome/IMG 2 (2).jpg", "v|émojí📷.jpg"]
    let encoded = PhotoMovePayload.encode(ids)
    #expect(PhotoMovePayload.decode(encoded) == ids)
    // A plain folder path (what folder drags carry) is NOT a photo payload.
    #expect(PhotoMovePayload.decode("2025/rome") == nil)
    #expect(PhotoMovePayload.decode("") == nil)
    // Marker without valid JSON is rejected, not crashed on.
    #expect(PhotoMovePayload.decode("photos:notjson") == nil)
    #expect(PhotoMovePayload.decode(PhotoMovePayload.encode([])) == [])
}
```

- [ ] **Step 2: Run — must FAIL to compile.** `swift test --filter PhotoMovePayloadTests 2>&1 | tail -5`

- [ ] **Step 3: Implement**

`Sources/OpenPhotoCore/Selection/PhotoMovePayload.swift`:

```swift
import Foundation

/// Drag payload for moving photos onto the folder tree. Folder rows accept String
/// drops (folder paths) — photo drags share that one channel behind a marker prefix
/// + JSON id list, so a single `dropDestination(for: String.self)` serves both.
public enum PhotoMovePayload {
    private static let marker = "photos:"

    public static func encode(_ instanceIDs: [String]) -> String {
        let json = (try? JSONEncoder().encode(instanceIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return marker + json
    }

    /// Nil when `string` isn't a photo payload (i.e. it's a plain folder path).
    public static func decode(_ string: String) -> [String]? {
        guard string.hasPrefix(marker) else { return nil }
        return try? JSONDecoder().decode([String].self,
                                         from: Data(string.dropFirst(marker.count).utf8))
    }
}
```

- [ ] **Step 4: Run tests** — filter PASS, full suite PASS, warning greps clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Selection/PhotoMovePayload.swift Tests/OpenPhotoCoreTests/PhotoMovePayloadTests.swift
git commit -m "feat: PhotoMovePayload — photo-drag payload codec sharing the folder-drop String channel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `AppState.movePhotos(ids:into:)` + `"moveFile"` queue replay (App, build-verified)

Mirrors `moveFolder(from:into:)` in the same file. App target has no unit tests (the core pieces are TDD'd; this is orchestration glue) — build-verify only.

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift:81` (token)
- Modify: `Sources/OpenPhotoApp/AppState+FolderReorg.swift`

- [ ] **Step 1: Add the refresh token**

In `Sources/OpenPhotoApp/AppState.swift`, directly under `var refreshToken = 0` (line 81), add:

```swift
    /// Bumped after a per-photo move so the folder grid clears its (now-stale) selection.
    var photoMoveToken = 0
```

- [ ] **Step 2: Add `movePhotos` to `AppState+FolderReorg.swift`** (insert a new `// MARK: - Move photos (file-grain)` section after the `moveFolder` function)

```swift
    // MARK: - Move photos (file-grain)

    /// Move the photos behind `ids` (grid instanceIDs) into folder `dest` ("" = library
    /// root). Local files move in the Mac primary vault; the moves propagate to connected
    /// durable drives now (exact targets keep basenames aligned) and queue ("moveFile")
    /// for offline ones. Drive-only items re-key their presence row immediately and move
    /// on (or queue for) their drive. One rescan at the end; the user stays in the folder.
    func movePhotos(ids: [String], into dest: String) async {
        guard let library, !ids.isEmpty else { return }
        let items = (try? library.catalog.items(instanceIDs: ids)) ?? []
        guard !items.isEmpty else { return }
        let destDir = dest.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 1. Mac primary vault (local instances; movePhotos skips drive-only + in-dest).
        let result = library.movePhotos(items.filter { $0.driveRelPath == nil }, toDir: destDir)

        // 2. Propagate the Mac moves: connected durable drives now, offline drives queued.
        if let basename = driveBasename(), !result.moved.isEmpty {
            let drives = connectedDurableDrives()
            if !drives.isEmpty {
                let moved = result.moved
                await Task.detached(priority: .userInitiated) {
                    for d in drives {
                        for (old, new) in moved {
                            _ = try? VaultReorganizer.moveFile(in: d.vault,
                                relPath: mapToDriveStatic(old, basename: basename),
                                toRelPath: mapToDriveStatic(new, basename: basename))
                        }
                    }
                }.value
            }
            for driveID in offlineDurableDriveIDs() {
                for (old, new) in result.moved {
                    _ = try? library.catalog.enqueueFolderOp(vaultID: driveID, op: "moveFile",
                                                             src: old, dst: new)
                }
            }
        }

        // 3. Drive-only items: re-key the presence row now (instant UI), then move the
        //    drive file now if that drive is connected, else queue. Live partners follow
        //    via their presence row.
        let driveOnly = items.filter { $0.driveRelPath != nil && $0.dirPath != destDir }
        if !driveOnly.isEmpty, let basename = driveBasename() {
            let connected = Dictionary(uniqueKeysWithValues:
                connectedDurableDrives().map { ($0.id, $0.vault) })
            var driveFileMoves: [(vault: Vault, old: String, new: String)] = []
            for item in driveOnly {
                var relPaths = [item.relPath]
                if let pairHash = item.livePairHash,
                   let pairRel = try? library.catalog.vaultPresenceRelPath(
                        vaultID: item.vaultID, hash: pairHash) {
                    relPaths.append(pairRel)
                }
                for old in relPaths {
                    let name = (old as NSString).lastPathComponent
                    let new = destDir.isEmpty ? name : destDir + "/" + name
                    guard new != old else { continue }
                    try? library.catalog.rewriteVaultPresencePath(vaultID: item.vaultID,
                                                                  fromRelPath: old, toRelPath: new)
                    if let dv = connected[item.vaultID] {
                        driveFileMoves.append((dv, old, new))
                    } else {
                        _ = try? library.catalog.enqueueFolderOp(vaultID: item.vaultID,
                                op: "moveFile", src: old, dst: new)
                    }
                }
            }
            if !driveFileMoves.isEmpty {
                let moves = driveFileMoves
                await Task.detached(priority: .userInitiated) {
                    for m in moves {
                        _ = try? VaultReorganizer.moveFile(in: m.vault,
                            relPath: mapToDriveStatic(m.old, basename: basename),
                            toRelPath: mapToDriveStatic(m.new, basename: basename))
                    }
                }.value
            }
        }

        reloadCanonicalPresence()
        await rescan()
        photoMoveToken += 1

        // 4. Failures: one aggregate alert (successes are silent, like folder moves).
        if !result.failures.isEmpty {
            let alert = NSAlert()
            let n = result.failures.count
            alert.messageText = "Couldn't move \(n) item\(n == 1 ? "" : "s")"
            alert.informativeText = result.failures
                .sorted { $0.key < $1.key }.prefix(4)
                .map { "\(($0.key as NSString).lastPathComponent): \($0.value)" }
                .joined(separator: "\n") + (n > 4 ? "\n…" : "")
            alert.runModal()
        }
    }
```

- [ ] **Step 3: Add the `"moveFile"` replay case**

In `applyPendingFolderOps(forDriveID:driveVault:)`, inside the `switch op.op` (after the `"delete"` case, before `default`):

```swift
                    case "moveFile":
                        guard let src = op.src, let dst = op.dst else { continue }
                        do {
                            try VaultReorganizer.moveFile(in: driveVault,
                                relPath: mapToDriveStatic(src, basename: basename),
                                toRelPath: mapToDriveStatic(dst, basename: basename))
                        } catch VaultReorganizer.ReorgError.missing {
                            // The drive never held this file — nothing to move; op is moot.
                        }
```

(The surrounding `do/catch` already leaves genuinely-failed ops queued for retry and `done.append(op.id)` clears handled ones — the `.missing` catch deliberately falls through to "handled".)

- [ ] **Step 4: Build-verify**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -3` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/AppState+FolderReorg.swift
git commit -m "feat: AppState.movePhotos — drive-parity photo moves (connected now, offline queued, presence rekey)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: UI — move controls, drag-to-move, tree drop branches (App, build-verified)

**Files:**
- Modify: `Sources/OpenPhotoApp/Selection/SelectionUI.swift` (SelectionActionBar)
- Modify: `Sources/OpenPhotoApp/Folders/FolderGridView.swift`
- Modify: `Sources/OpenPhotoApp/Folders/FolderTreeView.swift`

- [ ] **Step 1: SelectionActionBar gains an optional move-controls slot**

In `SelectionUI.swift`, `struct SelectionActionBar`: add a property directly after `let count: Int`:

```swift
    var moveControls: AnyView? = nil    // Folders screen injects its move cluster here
```

and render it in `body` directly after `Spacer()` (before the Deselect button):

```swift
            Spacer()
            if let moveControls { moveControls }
```

(`TimelineView`'s call site omits the argument — untouched, still compiles. NOTE: the memberwise init requires labeled arguments in property-declaration order, so `FolderGridView` passes `moveControls:` right after `count:`.)

- [ ] **Step 2: FolderGridView — state, controls, drag behavior**

In `FolderGridView.swift`:

(a) Add state after `@State private var showSend = false`:

```swift
    @State private var dragToMove = false
    @State private var moveDest = ""
    @State private var newMoveFolderName = ""
```

(b) In `body`'s `.task(id: state.selectedFolder)` closure, extend the reset line:

```swift
            selection.clear(); selectMode = false; dragToMove = false
```

(also leave the existing `reload()` call). Then add one more task alongside the existing ones:

```swift
        .task(id: state.photoMoveToken) { selection.clear() }   // moved items left this folder
```

(c) Replace `private var selectionBar` with:

```swift
    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            moveControls: AnyView(moveControls),
            sendTargetName: state.connectedSendTarget()?.name,
            onSend: { showSend = true },
            onDelete: { if !evictableItems.isEmpty { showDelete = true } },
            onEvict: { if !evictableItems.isEmpty { showEvict = true } },
            onForceEvict: { if !evictableItems.isEmpty { showForceEvict = true } },
            showRehydrate: !rehydratableItems.isEmpty,
            onRehydrate: { let items = rehydratableItems
                           Task { _ = await state.rehydrate(items); selection.clear(); selectMode = false } },
            onDeselect: { selection.clear() },
            onDone: { selection.clear(); selectMode = false; dragToMove = false })
    }

    /// Destination dropdown + "New folder…" + Move (the import screen's pattern), plus
    /// the drag-to-move toggle that flips grid dragging from rubber-band to drag-out.
    private var moveControls: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $dragToMove) {
                Label("Drag to Move", systemImage: "hand.draw")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Drag selected photos onto a folder in the sidebar. Turn off to rubber-band select again.")
            Picker(selection: $moveDest) {
                Text("Move to…").tag("")
                ForEach(pickerFolders, id: \.self) { f in
                    Text(f).tag(f)
                }
            } label: { EmptyView() }
            .frame(maxWidth: 180)
            TextField("New folder…", text: $newMoveFolderName)
                .frame(width: 110)
                .onSubmit {
                    let t = newMoveFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { moveDest = t; newMoveFolderName = "" }
                }
            Button("Move") {
                let ids = Array(selection.selected)
                let dest = moveDest
                Task { await state.movePhotos(ids: ids, into: dest) }
            }
            .disabled(selection.count == 0 || moveDest.isEmpty || moveDest == state.selectedFolder)
            .controlSize(.small)
        }
    }

    private var allFolders: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { paths.append(n.path); walk(n.children) } }
        walk(state.folderTree)
        return paths.sorted()
    }
    /// Picker options including a just-typed new folder, so selecting it never blanks the menu.
    private var pickerFolders: [String] {
        var fs = allFolders
        if !moveDest.isEmpty, !fs.contains(moveDest) { fs.insert(moveDest, at: 0) }
        return fs
    }
```

(d) Rubber band yields to drag-to-move — in `content`, change the modifier line to:

```swift
            .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                         space: "foldergrid", enabled: selectMode && !dragToMove))
```

(e) Tiles become draggable in drag-to-move — replace `private func cell(_ item: TimelineItem)`'s body wrapper:

```swift
    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        if selectMode && dragToMove {
            tile(item).draggable(dragPayload(for: item))
        } else {
            tile(item)
        }
    }

    /// Dragging a selected tile carries the whole selection; an unselected tile just itself.
    private func dragPayload(for item: TimelineItem) -> String {
        PhotoMovePayload.encode(selection.contains(item.instanceID)
                                ? Array(selection.selected) : [item.instanceID])
    }

    private func tile(_ item: TimelineItem) -> some View {
        MediaTile(
            id: item.instanceID,
            selectMode: selectMode,
            selected: selection.contains(item.instanceID),
            rubberBandSpace: "foldergrid",
            thumbnail: ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: thumbPixels),
            badges: { TimelineTileBadges(item: item, backedUp: state.isBackedUpOnCanonical(item)) },
            onTap: {
                if selectMode {
                    if let idx = items.firstIndex(where: { $0.instanceID == item.instanceID }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: items)
                }
            })
    }
```

(the `tile(_:)` body is the existing `cell(_:)` body verbatim — only renamed).

- [ ] **Step 3: FolderTreeView — photo-payload branches**

(a) In `FolderRow`, replace the `.dropDestination` closure (lines 149-158) with:

```swift
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                if let ids = PhotoMovePayload.decode(payload) {
                    guard !ids.isEmpty else { return false }
                    Task { await state.movePhotos(ids: ids, into: node.path) }
                    return true
                }
                guard payload != node.path,
                      !payload.isEmpty,
                      !node.path.hasPrefix(payload + "/") else { return false }
                Task { await state.moveFolder(from: payload, into: node.path) }
                return true
            } isTargeted: { targeted in
                dropTargeted = targeted
            }
```

(b) In `FolderTreeView`, replace `moveToRoot(_:)` with:

```swift
    /// Header + empty-space drops: photos move to the library root; a dragged folder
    /// un-nests to the root (rejected if it's already there).
    private func moveToRoot(_ payload: String?) -> Bool {
        guard let payload, !payload.isEmpty else { return false }
        if let ids = PhotoMovePayload.decode(payload) {
            guard !ids.isEmpty else { return false }
            Task { await state.movePhotos(ids: ids, into: "") }
            return true
        }
        guard !(payload as NSString).deletingLastPathComponent.isEmpty else { return false }
        Task { await state.moveFolder(from: payload, into: "") }
        return true
    }
```

- [ ] **Step 4: Build-verify + bundle**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -3` → all pass.
Run: `./scripts/make-app.sh 2>&1 | tail -2` → bundle rebuilt.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/Selection/SelectionUI.swift Sources/OpenPhotoApp/Folders/FolderGridView.swift Sources/OpenPhotoApp/Folders/FolderTreeView.swift
git commit -m "feat: Folders select mode gains move controls — destination picker + Move, drag-to-move onto the folder tree

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Docs — catalog-schema op kind + master spec (Docs)

**Files:**
- Modify: `docs/format/catalog-schema.md` (§`pending_folder_ops`, ~lines 97-112)
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md` (§10.5 Phase 5.5 roadmap + backlog item + changelog)

- [ ] **Step 1: catalog-schema.md** — in the `pending_folder_ops` section:

Change the `op` row of the table to:

```markdown
| `op` | TEXT | `"move"` \| `"create"` \| `"delete"` \| `"moveFile"`. |
```

Change the `srcRelPath` / `dstRelPath` rows' notes to mention file ops:

```markdown
| `srcRelPath` | TEXT? | Source vault-root-relative path. Required for `"move"`, `"delete"`, and `"moveFile"`; null for `"create"`. For `"moveFile"` it is a FILE path. |
| `dstRelPath` | TEXT? | Destination vault-root-relative path. Required for `"move"`, `"create"`, and `"moveFile"`; null for `"delete"`. For `"moveFile"` it includes the final basename (the Mac's collision-adjusted name). |
```

And append to the prose paragraph below the table (the one beginning "This table is the **source Mac's private reconcile queue**"), after its last sentence:

```markdown
Since 2026-06-12 the queue also records **per-photo file moves** (`op = "moveFile"`, file-grain `srcRelPath` → `dstRelPath`): the same replay applies them with the file-move primitive (file + sidecar + manifest entry), and a source file missing on the drive makes the op moot (cleared, not retried). No schema change — `op` was always free-form TEXT; readers of older queues simply never see the new kind.
```

- [ ] **Step 2: master design spec** — in `docs/superpowers/specs/2026-06-07-openphoto-design.md`:

1. In the §10.5 **Phase 5.5 roadmap** block, mark item 1 (select & move photos in the Folders screen) as **DONE (2026-06-12)** — keep items 2 and 3 as-is.
2. In the backlog item **"Move photos between folders"**, prepend: `**Shipped 2026-06-12** (spec: 2026-06-12-select-move-photos-design.md) — ` keeping the original description for the record.
3. Add a changelog entry at the bottom of the changelog section:

```markdown
- **2026-06-12 — Select & move photos shipped (Phase 5.5 slice 1).** Folders-screen Select mode gains move affordances: a destination dropdown + Move button (import-screen pattern) and a "Drag to Move" toggle (drag the selection onto the left folder tree; rows + root header accept photo drops). Underneath: file-grain `VaultReorganizer.moveFile` (atomic rename + sidecar + single manifest-entry rewrite, collision-safe via shared `FileNaming`), `LibraryService.movePhotos` (Live-pair carry), full drive parity mirroring folder reorg (connected drives move now with exact-target basenames; offline drives queue `"moveFile"` ops in `pending_folder_ops` — no schema change; drive-only items re-key `vault_presence` and appear in the new folder immediately). One rescan reconciles; failures aggregate into one alert. See `docs/superpowers/specs/2026-06-12-select-move-photos-design.md`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/format/catalog-schema.md docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: record moveFile op kind in catalog-schema; mark select & move photos shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

1. `swift test 2>&1 | tail -3` → all pass (expect ~350 tests).
2. `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → empty.
3. Whole-slice review subagent (spec: `docs/superpowers/specs/2026-06-12-select-move-photos-design.md`).
4. Merge `phase5.5-move-photos` → `main` with `--no-ff` using a message FILE (`git merge --no-ff phase5.5-move-photos -F /tmp/merge-msg.txt` — NEVER `-F -`), push origin main, delete the branch. (User pre-approved.)
