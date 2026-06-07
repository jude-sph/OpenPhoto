# OpenPhoto Phase 1 (Browse) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working macOS app that indexes the user's `~/Pictures` + `~/Movies` vaults (hash, manifest, catalog, thumbnails) and browses them via Timeline, Folder tree, Viewer, Inspector (with XMP sidecar edits), and Bin — plus the ImageCaptureCore deletion spike.

**Architecture:** Pure SwiftPM (no Xcode project — only CLT is installed): `OpenPhotoCore` library (vault/manifest/hash/catalog/scanner/sidecars, headless, fully tested) + `OpenPhotoApp` SwiftUI executable + `ICCSpike` executable. `scripts/make-app.sh` wraps the release binary into `OpenPhoto.app`. Visual truth: `UI-Design/design_handoff_openphoto/` (README has tokens & SF Symbol map).

**Tech Stack:** Swift 6.0.3, SwiftUI (macOS 15), GRDB 7 (SQLite), CryptoKit (SHA-256), ImageIO/AVFoundation (metadata & thumbs), FSEvents, Swift Testing (`import Testing`), MapKit (inspector mini-map), ImageCaptureCore (spike).

**Authoritative docs:** `docs/superpowers/specs/2026-06-07-openphoto-design.md` (design), `docs/format/vault-format-v1.md` (on-disk format — **update it in the same commit as any format change**).

---

## Conventions for every task

- Run tests: `swift test` (all) or `swift test --filter <TestName>` (one suite). Build app: `swift build`. Run app: `swift run OpenPhotoApp`.
- Tests use Swift Testing: `import Testing`, `@Test func …`, `#expect(…)`. Each Core test creates throwaway dirs via `TestDirs` helper (Task 3) — never touch the real `~/Pictures`.
- Commit after every task (message given per task). Never commit with failing tests.
- **Format-doc discipline:** Tasks 2 and 13 change/pin on-disk format details; they edit `docs/format/vault-format-v1.md` in the same commit. Any deviation you make during execution that touches the format must do the same.

## File structure (end state of Phase 1)

```
Package.swift
Sources/OpenPhotoCore/
  Hashing/ContentHash.swift          SHA-256 streaming hash → "sha256:<hex>"
  IO/AtomicFile.swift                temp → fsync → rename writes
  IO/TestDirs.swift                  (in Tests target, listed here for visibility)
  Vault/VaultDescriptor.swift        vault.json model + load/create
  Vault/Vault.swift                  vault layout (paths, sidecar/bin locations, media walk)
  Vault/Manifest.swift               manifest.jsonl read/write
  Vault/BinStore.swift               bin/ + bin.jsonl, delete/restore/list
  Media/MediaKind.swift              photo/video detection by extension
  Media/MediaMetadata.swift          extracted fields struct
  Media/MetadataExtractor.swift      ImageIO + AVFoundation extraction
  Media/LivePhotoPairer.swift        contentIdentifier + basename/time heuristic
  Catalog/Catalog.swift              GRDB queue, migrations, transactions
  Catalog/Records.swift              AssetRecord, InstanceRecord, VaultRecord
  Catalog/Queries.swift              timeline sections, folder tree, folder grid, counts
  Sidecar/SidecarData.swift          rating/caption/tags model
  Sidecar/XMP.swift                  serialize/parse XMP packet
  Sidecar/SidecarStore.swift         read/write sidecars in folder-level .openphoto/
  Scanner/Scanner.swift              walk + fast-path + hash + reconcile manifest/catalog
  Scanner/FolderWatcher.swift        FSEvents → debounced rescan
  Thumbnails/ThumbnailStore.swift    content-addressed JPEG thumbs
  LibraryService.swift               facade the app talks to; scan progress stream
Sources/OpenPhotoApp/
  OpenPhotoApp.swift                 @main, AppState, window
  Theme.swift                        design tokens from UI-Design README
  Sidebar/SidebarView.swift          Library section + activity indicator
  Welcome/WelcomeView.swift          first-launch folder picker
  Timeline/TimelineView.swift        sectioned LazyVGrid + grid-size slider
  Timeline/PhotoCellView.swift       cell + badges (live/video/fav) + hover
  Timeline/ThumbView.swift           async thumbnail loading view
  Folders/FolderTreeView.swift       DisclosureGroup tree + status badges
  Folders/FolderGridView.swift       grid + breadcrumb + Reveal in Finder
  Viewer/ViewerView.swift            full-bleed stage + filmstrip + keys
  Inspector/InspectorView.swift      metadata, edits→sidecars, mini-map, presence, path
  Bin/BinView.swift                  deleted grid, restore, empty to Trash
Sources/ICCSpike/main.swift          ImageCaptureCore deletion spike CLI
Tests/OpenPhotoCoreTests/            one file per Core unit (named <Unit>Tests.swift)
scripts/make-app.sh
docs/spikes/2026-06-07-icc-deletion.md   (created by Task 24)
```

UI deltas already decided in the spec: no Albums section, no "Schedule for later", bin keeps items until manually emptied (no "30 days" copy). People & Map sidebar items are **hidden** in Phase 1 (they arrive in Phase 4); the inspector's People section is omitted for now.

---

# Part A — OpenPhotoCore

### Task 1: SwiftPM scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/OpenPhotoCore/Hashing/ContentHash.swift` (placeholder type so the target compiles)
- Create: `Sources/OpenPhotoApp/OpenPhotoApp.swift` (minimal window)
- Create: `Tests/OpenPhotoCoreTests/SmokeTests.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenPhoto",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "OpenPhotoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "OpenPhotoApp",
            dependencies: ["OpenPhotoCore"]
        ),
        .executableTarget(name: "ICCSpike"),
        .testTarget(
            name: "OpenPhotoCoreTests",
            dependencies: ["OpenPhotoCore"]
        ),
    ]
)
```

- [ ] **Step 2: Minimal compiling sources**

`Sources/OpenPhotoCore/Hashing/ContentHash.swift`:

```swift
/// Content-addressed identity of a media file. Replaced with the real
/// implementation in Task 2.
public struct ContentHash: Hashable, Sendable {
    public let stringValue: String
    public init(stringValue: String) { self.stringValue = stringValue }
}
```

`Sources/OpenPhotoApp/OpenPhotoApp.swift`:

```swift
import SwiftUI

@main
struct OpenPhotoApp: App {
    var body: some Scene {
        WindowGroup("OpenPhoto") {
            Text("OpenPhoto — Phase 1 scaffold")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
```

`Sources/ICCSpike/main.swift`:

```swift
print("ICC spike — implemented in Task 24")
```

`Tests/OpenPhotoCoreTests/SmokeTests.swift`:

```swift
import Testing
@testable import OpenPhotoCore

@Test func smoke() {
    #expect(ContentHash(stringValue: "x").stringValue == "x")
}
```

- [ ] **Step 3: Build & test**

Run: `swift build && swift test`
Expected: GRDB resolves & builds; `Test run with 1 test passed`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "build: SwiftPM scaffold — Core lib, App + ICCSpike executables, GRDB 7"
```

### Task 2: ContentHash (streaming SHA-256) — and pin the hash algorithm in the format doc

The spec drafted BLAKE3; we ship **SHA-256 via CryptoKit** instead: zero third-party dependency (sovereignty), hardware-accelerated on Apple Silicon (I/O-bound anyway), and the format's `<alg>:` prefix keeps the door open. **This is a format change → update the format doc in this commit.**

**Files:**
- Modify: `Sources/OpenPhotoCore/Hashing/ContentHash.swift` (replace placeholder)
- Test: `Tests/OpenPhotoCoreTests/ContentHashTests.swift`
- Modify: `docs/format/vault-format-v1.md` §2

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func hashesKnownVector() throws {
    // SHA-256("abc") is a published NIST vector.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: f)
    let h = try ContentHash.ofFile(at: f)
    #expect(h.stringValue ==
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func streamsLargeFileWithoutLoadingIntoMemory() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("big.bin")
    let chunk = Data(repeating: 0xAB, count: 1_000_000)
    let created = FileManager.default.createFile(atPath: f.path, contents: nil)
    #expect(created)
    let fh = try FileHandle(forWritingTo: f)
    for _ in 0..<8 { try fh.write(contentsOf: chunk) }   // 8 MB
    try fh.close()
    let a = try ContentHash.ofFile(at: f)
    let b = try ContentHash.ofFile(at: f)
    #expect(a == b)
    #expect(a.stringValue.hasPrefix("sha256:"))
    #expect(a.stringValue.count == "sha256:".count + 64)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ContentHashTests`
Expected: FAIL — `ofFile` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation
import CryptoKit

/// Content-addressed identity: "sha256:" + 64 lowercase hex chars.
/// The algorithm prefix is part of the on-disk format (vault-format-v1 §2).
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let stringValue: String
    public var description: String { stringValue }

    public init(stringValue: String) { self.stringValue = stringValue }

    /// Streaming hash — constant memory regardless of file size.
    public static func ofFile(at url: URL) throws -> ContentHash {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            guard let data = try fh.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ContentHash(stringValue: "sha256:" + hex)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ContentHashTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Update the format doc** — in `docs/format/vault-format-v1.md` §2, replace the BLAKE3 paragraph with:

> The identity of an asset is the **SHA-256 hash of its file bytes**, serialized as `sha256:` + 64 lowercase hex chars. The algorithm prefix is mandatory; readers MUST treat unknown prefixes as unknown-but-distinct identities, allowing future algorithm migration. (v1 ships SHA-256 — hardware-accelerated on Apple Silicon and dependency-free; BLAKE3 remains a possible future prefix.)

Also update the example hash strings in §2, §4 and §8 from `b3:9f42…` to `sha256:9f42…`.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Hashing Tests/OpenPhotoCoreTests/ContentHashTests.swift docs/format/vault-format-v1.md
git commit -m "feat: streaming SHA-256 ContentHash; pin sha256: prefix in format doc"
```

### Task 3: AtomicFile + TestDirs helper

**Files:**
- Create: `Sources/OpenPhotoCore/IO/AtomicFile.swift`
- Create: `Tests/OpenPhotoCoreTests/TestDirs.swift`
- Test: `Tests/OpenPhotoCoreTests/AtomicFileTests.swift`

- [ ] **Step 1: TestDirs helper** (used by every later test)

```swift
import Foundation

/// Throwaway directory per test, auto-cleaned.
struct TestDirs {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openphoto-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func sub(_ name: String) throws -> URL {
        let u = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Write a file (creating intermediate dirs) and return its URL.
    @discardableResult
    func file(_ relPath: String, _ contents: Data) throws -> URL {
        let u = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u)
        return u
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
```

- [ ] **Step 2: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func atomicWriteCreatesFileWithContents() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dest = t.root.appendingPathComponent("a/b/manifest.jsonl")
    try AtomicFile.write(Data("hello".utf8), to: dest)
    #expect(try Data(contentsOf: dest) == Data("hello".utf8))
}

@Test func atomicWriteReplacesExistingFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dest = try t.file("x.txt", Data("old".utf8))
    try AtomicFile.write(Data("new".utf8), to: dest)
    #expect(try String(contentsOf: dest, encoding: .utf8) == "new")
}

@Test func leavesNoTempFilesBehind() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dest = t.root.appendingPathComponent("y.txt")
    try AtomicFile.write(Data("z".utf8), to: dest)
    let names = try FileManager.default.contentsOfDirectory(atPath: t.root.path)
    #expect(names == ["y.txt"])
}
```

- [ ] **Step 3: Run** `swift test --filter AtomicFileTests` — Expected: FAIL (AtomicFile undefined).

- [ ] **Step 4: Implement**

```swift
import Foundation

/// All vault-state writes go through this: temp file in the same directory,
/// fsync, then rename over the destination (vault-format-v1 §4, §10).
public enum AtomicFile {
    public static func write(_ data: Data, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-" + UUID().uuidString)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        do {
            try fh.write(contentsOf: data)
            try fh.synchronize()           // fsync
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }
}
```

- [ ] **Step 5: Run** `swift test --filter AtomicFileTests` — Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/IO Tests/OpenPhotoCoreTests/TestDirs.swift Tests/OpenPhotoCoreTests/AtomicFileTests.swift
git commit -m "feat: atomic temp→fsync→rename file writes + test dirs helper"
```

### Task 4: VaultDescriptor (vault.json) and Vault layout

**Files:**
- Create: `Sources/OpenPhotoCore/Vault/VaultDescriptor.swift`
- Create: `Sources/OpenPhotoCore/Vault/Vault.swift`
- Test: `Tests/OpenPhotoCoreTests/VaultTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func createsVaultStateOnFirstOpen() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let vault = try Vault.openOrCreate(at: root, role: .local)
    #expect(vault.descriptor.formatVersion == 1)
    #expect(vault.descriptor.role == .local)
    let vjson = root.appendingPathComponent(".openphoto/vault.json")
    #expect(FileManager.default.fileExists(atPath: vjson.path))
    // Reopen → same vault_id.
    let again = try Vault.openOrCreate(at: root, role: .local)
    #expect(again.descriptor.vaultID == vault.descriptor.vaultID)
}

@Test func refusesNewerFormatVersion() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/.openphoto/vault.json", Data("""
    {"format_version": 99, "vault_id": "X", "role": "local", "created_at": "2026-01-01T00:00:00.000Z", "app": "Other/9"}
    """.utf8))
    #expect(throws: VaultError.self) { try Vault.openOrCreate(at: root, role: .local) }
}

@Test func pathHelpersFollowFormat() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let media = root.appendingPathComponent("rome2022/IMG_1.heic")
    #expect(vault.sidecarURL(forMediaAt: media).path
        == root.appendingPathComponent("rome2022/.openphoto/IMG_1.heic.xmp").path)
    #expect(vault.manifestURL.path == root.appendingPathComponent(".openphoto/manifest.jsonl").path)
    #expect(vault.binDirURL.path == root.appendingPathComponent(".openphoto/bin").path)
    #expect(vault.relativePath(of: media) == "rome2022/IMG_1.heic")
}
```

- [ ] **Step 2: Run** `swift test --filter VaultTests` — Expected: FAIL.

- [ ] **Step 3: Implement `VaultDescriptor.swift`**

```swift
import Foundation

public enum VaultRole: String, Codable, Sendable {
    case local, canonical, backup
}

public enum VaultError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case notADirectory(String)
}

/// Mirrors vault.json — vault-format-v1 §3. snake_case keys are part of the format.
public struct VaultDescriptor: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let vaultID: String
    public let role: VaultRole
    public let createdAt: String
    public let app: String

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case vaultID = "vault_id"
        case role
        case createdAt = "created_at"
        case app
    }

    public static func new(role: VaultRole) -> VaultDescriptor {
        VaultDescriptor(
            formatVersion: currentFormatVersion,
            vaultID: UUID().uuidString.lowercased(),
            role: role,
            createdAt: ISO8601Millis.string(from: Date()),
            app: "OpenPhoto/0.1")
    }
}

/// ISO-8601 UTC with milliseconds — the timestamp format used across the vault format.
public enum ISO8601Millis {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    public static func string(from date: Date) -> String { formatter.string(from: date) }
    public static func date(from string: String) -> Date? { formatter.date(from: string) }
}
```

- [ ] **Step 4: Implement `Vault.swift`**

```swift
import Foundation

/// A self-describing library location — vault-format-v1 §1.
public struct Vault: Sendable {
    public let rootURL: URL
    public let descriptor: VaultDescriptor

    public static let stateDirName = ".openphoto"

    public var stateDirURL: URL { rootURL.appendingPathComponent(Self.stateDirName) }
    public var manifestURL: URL { stateDirURL.appendingPathComponent("manifest.jsonl") }
    public var syncLogURL: URL { stateDirURL.appendingPathComponent("sync-log.jsonl") }
    public var binDirURL: URL { stateDirURL.appendingPathComponent("bin") }
    public var binLogURL: URL { stateDirURL.appendingPathComponent("bin.jsonl") }

    /// rome2022/IMG_1.heic → rome2022/.openphoto/IMG_1.heic.xmp  (format §5)
    public func sidecarURL(forMediaAt media: URL) -> URL {
        media.deletingLastPathComponent()
            .appendingPathComponent(Self.stateDirName)
            .appendingPathComponent(media.lastPathComponent + ".xmp")
    }

    /// Vault-root-relative path with "/" separators, NFC-normalized (format §4).
    public func relativePath(of url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        let rel = p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : p
        return rel.precomposedStringWithCanonicalMapping
    }

    public func absoluteURL(forRelativePath rel: String) -> URL {
        rootURL.appendingPathComponent(rel)
    }

    public static func openOrCreate(at root: URL, role: VaultRole) throws -> Vault {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw VaultError.notADirectory(root.path)
        }
        let vjson = root.appendingPathComponent(stateDirName).appendingPathComponent("vault.json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: vjson) {
            let desc = try decoder.decode(VaultDescriptor.self, from: data)
            guard desc.formatVersion <= VaultDescriptor.currentFormatVersion else {
                throw VaultError.unsupportedFormatVersion(desc.formatVersion)
            }
            return Vault(rootURL: root, descriptor: desc)
        }
        let desc = VaultDescriptor.new(role: role)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(desc), to: vjson)
        return Vault(rootURL: root, descriptor: desc)
    }
}
```

- [ ] **Step 5: Run** `swift test --filter VaultTests` — Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Vault Tests/OpenPhotoCoreTests/VaultTests.swift
git commit -m "feat: vault.json descriptor + vault layout/path helpers per format v1"
```

### Task 5: Manifest (manifest.jsonl)

**Files:**
- Create: `Sources/OpenPhotoCore/Vault/Manifest.swift`
- Test: `Tests/OpenPhotoCoreTests/ManifestTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func roundTripsEntries() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    let entries = [
        ManifestEntry(hash: ContentHash(stringValue: "sha256:" + String(repeating: "a", count: 64)),
                      path: "rome2022/IMG_1.heic", size: 123,
                      mtime: "2022-10-07T14:23:01.512Z"),
        ManifestEntry(hash: ContentHash(stringValue: "sha256:" + String(repeating: "b", count: 64)),
                      path: "canada23/IMG_2.mov", size: 456_789,
                      mtime: "2023-02-01T09:00:00.000Z"),
    ]
    try Manifest.write(entries, to: url)
    let read = try Manifest.read(from: url)
    #expect(read == entries)
}

@Test func emptyOrMissingManifestReadsAsEmpty() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    #expect(try Manifest.read(from: url) == [])
}

@Test func linesAreStableSingleObjects() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    let e = ManifestEntry(hash: ContentHash(stringValue: "sha256:" + String(repeating: "c", count: 64)),
                          path: "a/b.jpg", size: 1, mtime: "2026-01-01T00:00:00.000Z")
    try Manifest.write([e], to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("{") && lines[0].hasSuffix("}"))
    #expect(text.hasSuffix("\n"))
}
```

- [ ] **Step 2: Run** `swift test --filter ManifestTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One line of manifest.jsonl — vault-format-v1 §4. Keys are the format.
public struct ManifestEntry: Codable, Equatable, Sendable {
    public let hash: ContentHash
    public let path: String   // vault-root-relative, "/", NFC
    public let size: Int64
    public let mtime: String  // ISO-8601 UTC, milliseconds

    public init(hash: ContentHash, path: String, size: Int64, mtime: String) {
        self.hash = hash
        self.path = path
        self.size = size
        self.mtime = mtime
    }

    enum CodingKeys: String, CodingKey { case hash, path, size, mtime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = ContentHash(stringValue: try c.decode(String.self, forKey: .hash))
        path = try c.decode(String.self, forKey: .path)
        size = try c.decode(Int64.self, forKey: .size)
        mtime = try c.decode(String.self, forKey: .mtime)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hash.stringValue, forKey: .hash)
        try c.encode(path, forKey: .path)
        try c.encode(size, forKey: .size)
        try c.encode(mtime, forKey: .mtime)
    }
}

public enum Manifest {
    /// Atomic full rewrite (format §4). Sorted by path for stable diffs.
    public static func write(_ entries: [ManifestEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in entries.sorted(by: { $0.path < $1.path }) {
            out.append(try encoder.encode(e))
            out.append(0x0A)
        }
        try AtomicFile.write(out, to: url)
    }

    public static func read(from url: URL) throws -> [ManifestEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A)
            .filter { !$0.isEmpty }
            .map { try decoder.decode(ManifestEntry.self, from: $0) }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter ManifestTests` — Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Vault/Manifest.swift Tests/OpenPhotoCoreTests/ManifestTests.swift
git commit -m "feat: manifest.jsonl read/atomic-write per format v1 §4"
```

### Task 6: MediaKind detection

**Files:**
- Create: `Sources/OpenPhotoCore/Media/MediaKind.swift`
- Test: `Tests/OpenPhotoCoreTests/MediaKindTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import OpenPhotoCore

@Test func detectsKinds() {
    #expect(MediaKind.of(filename: "IMG_1.HEIC") == .photo)
    #expect(MediaKind.of(filename: "a.jpeg") == .photo)
    #expect(MediaKind.of(filename: "scan.dng") == .photo)
    #expect(MediaKind.of(filename: "shot.PNG") == .photo)
    #expect(MediaKind.of(filename: "clip.mov") == .video)
    #expect(MediaKind.of(filename: "clip.MP4") == .video)
    #expect(MediaKind.of(filename: "notes.txt") == nil)
    #expect(MediaKind.of(filename: ".DS_Store") == nil)
    #expect(MediaKind.of(filename: "IMG_1.heic.xmp") == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter MediaKindTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum MediaKind: String, Codable, Sendable {
    case photo, video

    private static let photoExts: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "tif",
        "webp", "bmp", "dng", "raw", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
    private static let videoExts: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "3gp", "webm",
    ]

    public static func of(filename: String) -> MediaKind? {
        guard !filename.hasPrefix(".") else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        if photoExts.contains(ext) { return .photo }
        if videoExts.contains(ext) { return .video }
        return nil
    }
}
```

- [ ] **Step 4: Run** `swift test --filter MediaKindTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Media/MediaKind.swift Tests/OpenPhotoCoreTests/MediaKindTests.swift
git commit -m "feat: media kind detection by extension"
```

### Task 7: MetadataExtractor (EXIF / GPS / dims / camera / video)

Test fixtures are **generated in test code** via ImageIO (image with EXIF+GPS properties) and AVAssetWriter (1-frame video) — no binary fixtures in the repo.

**Files:**
- Create: `Sources/OpenPhotoCore/Media/MediaMetadata.swift`
- Create: `Sources/OpenPhotoCore/Media/MetadataExtractor.swift`
- Test: `Tests/OpenPhotoCoreTests/MetadataExtractorTests.swift`

- [ ] **Step 1: Failing tests (with fixture generators)**

```swift
import Testing
import Foundation
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// Write a 4×4 JPEG with EXIF date, GPS, and camera model.
func makeJPEG(at url: URL, dateTimeOriginal: String?, lat: Double?, lon: Double?) throws {
    let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = ctx.makeImage()!
    var props: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam X1"],
    ]
    if let d = dateTimeOriginal {
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: d]
    }
    if let lat, let lon {
        props[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(lat),
            kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(lon),
            kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
        ]
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

/// Write a ~1-second 64×64 H.264 .mov.
func makeMOV(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    for i in 0..<2 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i * 30), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Test func extractsImageMetadata() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("test.jpg")
    try makeJPEG(at: url, dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.90, lon: 12.50)
    let m = MetadataExtractor.extract(from: url, kind: .photo)
    #expect(m.pixelWidth == 4 && m.pixelHeight == 4)
    #expect(m.cameraModel == "TestCam X1")
    #expect(m.latitude != nil && abs(m.latitude! - 41.90) < 0.01)
    #expect(m.longitude != nil && abs(m.longitude! - 12.50) < 0.01)
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month, .day], from: m.takenAt)
    #expect(comps.year == 2022 && comps.month == 10 && comps.day == 7)
}

@Test func fallsBackToFileMtimeWhenNoExif() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("noexif.jpg")
    try makeJPEG(at: url, dateTimeOriginal: nil, lat: nil, lon: nil)
    let m = MetadataExtractor.extract(from: url, kind: .photo)
    let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    #expect(abs(m.takenAt.timeIntervalSince(mtime)) < 2)
    #expect(m.latitude == nil)
}

@Test func extractsVideoMetadata() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("clip.mov")
    try await makeMOV(at: url)
    let m = MetadataExtractor.extract(from: url, kind: .video)
    #expect(m.pixelWidth == 64 && m.pixelHeight == 64)
    #expect(m.durationSeconds != nil && m.durationSeconds! > 0)
}
```

- [ ] **Step 2: Run** `swift test --filter MetadataExtractorTests` — Expected: FAIL.

- [ ] **Step 3: Implement `MediaMetadata.swift`**

```swift
import Foundation

public struct MediaMetadata: Sendable {
    public var takenAt: Date
    public var pixelWidth: Int? = nil
    public var pixelHeight: Int? = nil
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    public var cameraModel: String? = nil
    public var lensModel: String? = nil
    public var durationSeconds: Double? = nil
    /// Apple Live Photo content identifier, when present (format v1 §6).
    public var contentIdentifier: String? = nil

    public init(takenAt: Date) { self.takenAt = takenAt }
}
```

- [ ] **Step 4: Implement `MetadataExtractor.swift`**

```swift
import Foundation
import ImageIO
import AVFoundation

public enum MetadataExtractor {
    /// EXIF "yyyy:MM:dd HH:mm:ss" — interpreted in the local calendar
    /// (EXIF has no zone; this matches what every photo tool does).
    nonisolated(unsafe) private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func extract(from url: URL, kind: MediaKind) -> MediaMetadata {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? Date()
        var m = MediaMetadata(takenAt: mtime)
        switch kind {
        case .photo: extractImage(url, into: &m)
        case .video: extractVideo(url, into: &m)
        }
        return m
    }

    private static func extractImage(_ url: URL, into m: inout MediaMetadata) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return }
        m.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        m.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let d = exifDate.date(from: s) { m.takenAt = d }
            m.lensModel = exif[kCGImagePropertyExifLensModel] as? String
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            m.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            m.latitude = latRef == "S" ? -lat : lat
            m.longitude = lonRef == "W" ? -lon : lon
        }
        if let apple = props[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any] {
            // Key "17" holds the Live Photo content identifier in Apple maker notes.
            m.contentIdentifier = apple["17" as CFString] as? String
        }
    }

    private static func extractVideo(_ url: URL, into m: inout MediaMetadata) {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            if let d = try? await asset.load(.duration) {
                m.durationSeconds = CMTimeGetSeconds(d)
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                m.pixelWidth = Int(abs(size.width))
                m.pixelHeight = Int(abs(size.height))
            }
            if let meta = try? await asset.load(.metadata) {
                if let created = meta.first(where: { $0.commonKey == .commonKeyCreationDate }),
                   let s = try? await created.load(.stringValue),
                   let d = ISO8601Millis.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
                    m.takenAt = d
                }
                if let cid = meta.first(where: {
                    $0.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier"
                }), let s = try? await cid.load(.stringValue) {
                    m.contentIdentifier = s
                }
            }
        }
        sem.wait()
    }
}
```

Note: `extractVideo` bridges async AVFoundation loading to the synchronous extractor with a semaphore — acceptable because extraction always runs on scanner background threads, never the main thread. If the compiler objects to the captured `inout` in the Task, lift the loads into a small `struct VideoProbe` returned by an inner async function and assign after `sem.wait()` — keep the public signature synchronous.

- [ ] **Step 5: Run** `swift test --filter MetadataExtractorTests` — Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Media Tests/OpenPhotoCoreTests/MetadataExtractorTests.swift
git commit -m "feat: EXIF/GPS/camera/video metadata extraction with generated fixtures"
```

### Task 8: LivePhotoPairer

**Files:**
- Create: `Sources/OpenPhotoCore/Media/LivePhotoPairer.swift`
- Test: `Tests/OpenPhotoCoreTests/LivePhotoPairerTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func cand(_ path: String, _ kind: MediaKind, taken: TimeInterval,
                  cid: String? = nil) -> LivePhotoPairer.Candidate {
    // Distinct fake hash per path (only used as an identity string in tests).
    let fake = String((path.replacingOccurrences(of: "/", with: "_")
        + String(repeating: "0", count: 64)).prefix(64))
    return .init(hash: ContentHash(stringValue: "sha256:" + fake),
                 relPath: path, kind: kind,
                 takenAt: Date(timeIntervalSince1970: taken), contentIdentifier: cid)
}

@Test func pairsByContentIdentifier() {
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_1.heic", .photo, taken: 0, cid: "CID-1"),
        cand("a/IMG_1.mov", .video, taken: 0, cid: "CID-1"),
        cand("a/IMG_2.heic", .photo, taken: 50, cid: "CID-2"),
    ])
    #expect(pairs.count == 1)
    #expect(pairs[0].photoRelPath == "a/IMG_1.heic")
    #expect(pairs[0].videoRelPath == "a/IMG_1.mov")
}

@Test func pairsByBasenameAndTimeWhenNoCid() {
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_3.heic", .photo, taken: 100),
        cand("a/IMG_3.mov", .video, taken: 101),   // within 2s
    ])
    #expect(pairs.count == 1)
}

@Test func doesNotPairAcrossFoldersOrBeyondTimeWindow() {
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_4.heic", .photo, taken: 0),
        cand("b/IMG_4.mov", .video, taken: 0),      // other folder
        cand("a/IMG_5.heic", .photo, taken: 0),
        cand("a/IMG_5.mov", .video, taken: 10),     // 10s apart — unrelated video
    ])
    #expect(pairs.isEmpty)
}
```

- [ ] **Step 2: Run** `swift test --filter LivePhotoPairerTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Live Photo = still + video pairing — vault-format-v1 §6.
public enum LivePhotoPairer {
    public struct Candidate: Sendable {
        public let hash: ContentHash
        public let relPath: String
        public let kind: MediaKind
        public let takenAt: Date
        public let contentIdentifier: String?
        public init(hash: ContentHash, relPath: String, kind: MediaKind,
                    takenAt: Date, contentIdentifier: String?) {
            self.hash = hash; self.relPath = relPath; self.kind = kind
            self.takenAt = takenAt; self.contentIdentifier = contentIdentifier
        }
    }
    public struct Pair: Equatable, Sendable {
        public let photoHash: ContentHash
        public let videoHash: ContentHash
        public let photoRelPath: String
        public let videoRelPath: String
    }

    public static func pair(candidates: [Candidate]) -> [Pair] {
        let photos = candidates.filter { $0.kind == .photo }
        let videos = candidates.filter { $0.kind == .video }
        var pairedVideos = Set<String>()
        var result: [Pair] = []

        // 1. Content identifier match (authoritative).
        var videosByCid: [String: Candidate] = [:]
        for v in videos { if let c = v.contentIdentifier { videosByCid[c] = v } }
        var unpaired: [Candidate] = []
        for p in photos {
            if let c = p.contentIdentifier, let v = videosByCid[c] {
                result.append(Pair(photoHash: p.hash, videoHash: v.hash,
                                   photoRelPath: p.relPath, videoRelPath: v.relPath))
                pairedVideos.insert(v.relPath)
            } else {
                unpaired.append(p)
            }
        }

        // 2. Fallback: same folder + same basename + taken within 2 s.
        func dir(_ s: String) -> String { (s as NSString).deletingLastPathComponent }
        func base(_ s: String) -> String {
            ((s as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        }
        var videosByKey: [String: Candidate] = [:]
        for v in videos where !pairedVideos.contains(v.relPath) {
            videosByKey[dir(v.relPath) + "|" + base(v.relPath)] = v
        }
        for p in unpaired {
            guard let v = videosByKey[dir(p.relPath) + "|" + base(p.relPath)],
                  abs(p.takenAt.timeIntervalSince(v.takenAt)) <= 2 else { continue }
            result.append(Pair(photoHash: p.hash, videoHash: v.hash,
                               photoRelPath: p.relPath, videoRelPath: v.relPath))
        }
        return result
    }
}
```

- [ ] **Step 4: Run** `swift test --filter LivePhotoPairerTests` — Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Media/LivePhotoPairer.swift Tests/OpenPhotoCoreTests/LivePhotoPairerTests.swift
git commit -m "feat: Live Photo pairing by content identifier with basename/time fallback"
```

### Task 9: Catalog (GRDB schema + records + core queries)

The catalog is **rebuildable cache** (spec §3). Phase-1 schema subset: `vaults`, `assets`, `instances` (+ mirrored human metadata columns on `assets` for query speed; sidecars stay authoritative).

**Files:**
- Create: `Sources/OpenPhotoCore/Catalog/Records.swift`
- Create: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Create: `Sources/OpenPhotoCore/Catalog/Queries.swift`
- Test: `Tests/OpenPhotoCoreTests/CatalogTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func makeAsset(_ n: Int, taken: String, kind: MediaKind = .photo) -> AssetRecord {
    AssetRecord(hash: "sha256:" + String(format: "%064d", n), kind: kind.rawValue,
                takenAtMs: Int64(ISO8601Millis.date(from: taken)!.timeIntervalSince1970 * 1000),
                pixelWidth: 100, pixelHeight: 100, latitude: nil, longitude: nil,
                cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
}

@Test func upsertsAndQueriesTimeline() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("catalog.sqlite"))
    let vaultID = "v-1"
    try cat.registerVault(id: vaultID, role: "local", rootPath: "/tmp/Pictures")
    let a1 = makeAsset(1, taken: "2022-10-07T14:00:00.000Z")
    let a2 = makeAsset(2, taken: "2025-06-06T09:00:00.000Z")
    try cat.upsert(assets: [a1, a2])
    try cat.upsert(instances: [
        InstanceRecord(hash: a1.hash, vaultID: vaultID, relPath: "rome2022/IMG_1.heic",
                       dirPath: "rome2022", size: 10, mtimeMs: 0),
        InstanceRecord(hash: a2.hash, vaultID: vaultID, relPath: "lisbon25/IMG_2.heic",
                       dirPath: "lisbon25", size: 10, mtimeMs: 0),
    ])
    let items = try cat.timelineItems()
    #expect(items.count == 2)
    #expect(items.first?.hash == a2.hash)   // newest first
}

@Test func removingStaleInstancesKeepsAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    let a = makeAsset(3, taken: "2024-01-01T00:00:00.000Z")
    try cat.upsert(assets: [a])
    try cat.upsert(instances: [InstanceRecord(hash: a.hash, vaultID: "v-1",
        relPath: "x/IMG.heic", dirPath: "x", size: 1, mtimeMs: 0)])
    try cat.replaceInstances(inVault: "v-1", with: [])   // file disappeared
    #expect(try cat.timelineItems().isEmpty)             // no visible instance
    #expect(try cat.assetCount() == 1)                   // asset row kept
}

@Test func folderTreeFromInstances() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    let a = makeAsset(4, taken: "2024-01-01T00:00:00.000Z")
    let b = makeAsset(5, taken: "2024-01-02T00:00:00.000Z")
    try cat.upsert(assets: [a, b])
    try cat.upsert(instances: [
        InstanceRecord(hash: a.hash, vaultID: "v-1", relPath: "2022/rome2022/IMG_1.heic",
                       dirPath: "2022/rome2022", size: 1, mtimeMs: 0),
        InstanceRecord(hash: b.hash, vaultID: "v-1", relPath: "mac-screenshots/s.png",
                       dirPath: "mac-screenshots", size: 1, mtimeMs: 0),
    ])
    let folders = try cat.folderCounts()
    #expect(folders["2022/rome2022"] == 1)
    #expect(folders["mac-screenshots"] == 1)
}

@Test func livePairedVideoHiddenFromTimeline() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    var photo = makeAsset(6, taken: "2024-01-01T00:00:00.000Z")
    var video = makeAsset(7, taken: "2024-01-01T00:00:00.000Z", kind: .video)
    photo.livePairHash = video.hash
    video.isLivePairedVideo = true
    try cat.upsert(assets: [photo, video])
    try cat.upsert(instances: [
        InstanceRecord(hash: photo.hash, vaultID: "v-1", relPath: "a/I.heic", dirPath: "a", size: 1, mtimeMs: 0),
        InstanceRecord(hash: video.hash, vaultID: "v-1", relPath: "a/I.mov", dirPath: "a", size: 1, mtimeMs: 0),
    ])
    let items = try cat.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].livePairHash == video.hash)
}
```

- [ ] **Step 2: Run** `swift test --filter CatalogTests` — Expected: FAIL.

- [ ] **Step 3: Implement `Records.swift`**

```swift
import Foundation
import GRDB

public struct VaultRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "vaults"
    public var id: String          // vault_id from vault.json
    public var role: String
    public var rootPath: String
    public var lastSeenMs: Int64
}

public struct AssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "assets"
    public var hash: String        // primary key, "sha256:…"
    public var kind: String        // MediaKind.rawValue
    public var takenAtMs: Int64    // epoch ms — sort key
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var cameraModel: String?
    public var lensModel: String?
    public var durationSeconds: Double?
    public var livePairHash: String?      // set on the photo half of a Live Photo
    public var isLivePairedVideo: Bool    // true on the video half → hidden in browse
    // Mirrors of sidecar data (sidecars are authoritative — spec §3):
    public var favorite: Bool
    public var rating: Int
    public var caption: String?
    public var tagsJSON: String           // JSON array of strings
}

public struct InstanceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "instances"
    public var hash: String
    public var vaultID: String
    public var relPath: String
    public var dirPath: String     // dirname(relPath), "" for vault root
    public var size: Int64
    public var mtimeMs: Int64
}

/// One browseable row: asset + its (first) local instance.
public struct TimelineItem: Codable, FetchableRecord, Sendable, Equatable {
    public var hash: String
    public var kind: String
    public var takenAtMs: Int64
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var cameraModel: String?
    public var lensModel: String?
    public var durationSeconds: Double?
    public var livePairHash: String?
    public var favorite: Bool
    public var rating: Int
    public var caption: String?
    public var tagsJSON: String
    public var vaultID: String
    public var relPath: String
    public var dirPath: String
    public var size: Int64
}
```

- [ ] **Step 4: Implement `Catalog.swift`**

```swift
import Foundation
import GRDB

public final class Catalog: Sendable {
    public let dbQueue: DatabaseQueue

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .text)
                t.column("role", .text).notNull()
                t.column("rootPath", .text).notNull()
                t.column("lastSeenMs", .integer).notNull()
            }
            try db.create(table: "assets") { t in
                t.primaryKey("hash", .text)
                t.column("kind", .text).notNull()
                t.column("takenAtMs", .integer).notNull().indexed()
                t.column("pixelWidth", .integer)
                t.column("pixelHeight", .integer)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("cameraModel", .text)
                t.column("lensModel", .text)
                t.column("durationSeconds", .double)
                t.column("livePairHash", .text)
                t.column("isLivePairedVideo", .boolean).notNull().defaults(to: false)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("caption", .text)
                t.column("tagsJSON", .text).notNull().defaults(to: "[]")
            }
            try db.create(table: "instances") { t in
                t.column("hash", .text).notNull().indexed()
                t.column("vaultID", .text).notNull()
                t.column("relPath", .text).notNull()
                t.column("dirPath", .text).notNull().indexed()
                t.column("size", .integer).notNull()
                t.column("mtimeMs", .integer).notNull()
                t.primaryKey(["vaultID", "relPath"])
            }
        }
        try migrator.migrate(dbQueue)
    }

    public func registerVault(id: String, role: String, rootPath: String) throws {
        try dbQueue.write { db in
            try VaultRecord(id: id, role: role, rootPath: rootPath,
                            lastSeenMs: Int64(Date().timeIntervalSince1970 * 1000)).save(db)
        }
    }

    public func upsert(assets: [AssetRecord]) throws {
        try dbQueue.write { db in for a in assets { try a.save(db) } }
    }

    public func upsert(instances: [InstanceRecord]) throws {
        try dbQueue.write { db in for i in instances { try i.save(db) } }
    }

    /// Wholesale replacement of a vault's instances (scan reconcile).
    public func replaceInstances(inVault vaultID: String, with instances: [InstanceRecord]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM instances WHERE vaultID = ?", arguments: [vaultID])
            for i in instances { try i.save(db) }
        }
    }

    public func assetCount() throws -> Int {
        try dbQueue.read { db in try AssetRecord.fetchCount(db) }
    }

    public func knownHashes() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT hash FROM assets"))
        }
    }
}
```

- [ ] **Step 5: Implement `Queries.swift`**

```swift
import Foundation
import GRDB

extension Catalog {
    private static let timelineSQL = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight,
               a.latitude, a.longitude, a.cameraModel, a.lensModel, a.durationSeconds,
               a.livePairHash, a.favorite, a.rating, a.caption, a.tagsJSON,
               i.vaultID, i.relPath, i.dirPath, i.size
        FROM assets a
        JOIN instances i ON i.hash = a.hash
        WHERE a.isLivePairedVideo = 0
        """

    /// Whole-library browse rows, newest first. ~60k rows fetch in tens of ms.
    public func timelineItems() throws -> [TimelineItem] {
        try dbQueue.read { db in
            try TimelineItem.fetchAll(db, sql: Self.timelineSQL + " ORDER BY a.takenAtMs DESC")
        }
    }

    /// Items whose instance lives in the given folder (non-recursive).
    public func items(inDir dirPath: String) throws -> [TimelineItem] {
        try dbQueue.read { db in
            try TimelineItem.fetchAll(
                db, sql: Self.timelineSQL + " AND i.dirPath = ? ORDER BY a.takenAtMs DESC",
                arguments: [dirPath])
        }
    }

    /// dirPath → item count, across all vaults (drives the folder tree).
    public func folderCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.dirPath AS d, COUNT(*) AS n FROM instances i
                JOIN assets a ON a.hash = i.hash
                WHERE a.isLivePairedVideo = 0 GROUP BY i.dirPath
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["d"] as String, $0["n"] as Int) })
        }
    }

    public func item(hash: String) throws -> TimelineItem? {
        try dbQueue.read { db in
            try TimelineItem.fetchOne(db, sql: Self.timelineSQL + " AND a.hash = ? LIMIT 1",
                                      arguments: [hash])
        }
    }

    /// Mirror a sidecar edit into the catalog (sidecar written separately).
    public func updateHumanMetadata(hash: String, favorite: Bool, rating: Int,
                                    caption: String?, tagsJSON: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE assets SET favorite = ?, rating = ?, caption = ?, tagsJSON = ?
                WHERE hash = ?
                """, arguments: [favorite, rating, caption, tagsJSON, hash])
        }
    }
}
```

- [ ] **Step 6: Run** `swift test --filter CatalogTests` — Expected: 4 PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog Tests/OpenPhotoCoreTests/CatalogTests.swift
git commit -m "feat: GRDB catalog — vaults/assets/instances schema, timeline & folder queries"
```

### Task 10: Scanner (walk → fast-path → hash → reconcile)

The heart of Phase 1. Pure logic: walk the vault, reuse manifest hashes when `(size, mtime)` match, hash what's new/changed, extract metadata for hashes the catalog doesn't know, pair Live Photos, then atomically rewrite the manifest and replace the vault's catalog instances.

**Files:**
- Create: `Sources/OpenPhotoCore/Scanner/Scanner.swift`
- Test: `Tests/OpenPhotoCoreTests/ScannerTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func fixtureVault(_ t: TestDirs) throws -> (Vault, Catalog) {
    let root = try t.sub("Pictures")
    try makeJPEG(at: root.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: root.appendingPathComponent("rome2022/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:08 10:00:00", lat: nil, lon: nil)
    try makeJPEG(at: root.appendingPathComponent("mac-screenshots/nested/s1.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try t.file("Pictures/rome2022/notes.txt", Data("ignore me".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let cat = try Catalog(at: t.root.appendingPathComponent("catalog.sqlite"))
    try cat.registerVault(id: vault.descriptor.vaultID, role: "local", rootPath: root.path)
    return (vault, cat)
}

extension URL {
    func creatingParent() -> URL {
        try? FileManager.default.createDirectory(
            at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

@Test func initialScanIndexesMediaOnly() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    let result = try Scanner.scan(vault: vault, catalog: cat)
    #expect(result.hashed == 3)
    #expect(try cat.timelineItems().count == 3)              // .txt and .openphoto skipped
    #expect(try Manifest.read(from: vault.manifestURL).count == 3)
}

@Test func rescanIsFastPathNoop() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    _ = try Scanner.scan(vault: vault, catalog: cat)
    let second = try Scanner.scan(vault: vault, catalog: cat)
    #expect(second.hashed == 0)                              // size+mtime matched
    #expect(try cat.timelineItems().count == 3)
}

@Test func renameKeepsIdentity() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    _ = try Scanner.scan(vault: vault, catalog: cat)
    let before = try cat.timelineItems().first { $0.relPath == "rome2022/IMG_1.jpg" }!
    try FileManager.default.moveItem(
        at: vault.rootURL.appendingPathComponent("rome2022/IMG_1.jpg"),
        to: vault.rootURL.appendingPathComponent("rome2022/renamed.jpg"))
    _ = try Scanner.scan(vault: vault, catalog: cat)
    let after = try cat.timelineItems().first { $0.relPath == "rome2022/renamed.jpg" }
    #expect(after?.hash == before.hash)                      // same asset, new path
    #expect(try cat.timelineItems().count == 3)
}

@Test func deletedFileLeavesTimeline() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    _ = try Scanner.scan(vault: vault, catalog: cat)
    try FileManager.default.removeItem(
        at: vault.rootURL.appendingPathComponent("rome2022/IMG_2.jpg"))
    _ = try Scanner.scan(vault: vault, catalog: cat)
    #expect(try cat.timelineItems().count == 2)
    #expect(try cat.assetCount() == 3)                       // asset row preserved
}

@Test func reportsProgress() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    var events: [Scanner.Progress] = []
    _ = try Scanner.scan(vault: vault, catalog: cat) { events.append($0) }
    #expect(events.contains { $0.stage == .hashing })
    #expect(events.last?.done == events.last?.total)
}
```

- [ ] **Step 2: Run** `swift test --filter ScannerTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum Scanner {
    public struct Progress: Sendable {
        public enum Stage: String, Sendable { case walking, hashing, extracting, finishing }
        public let stage: Stage
        public let done: Int
        public let total: Int
    }

    public struct Result: Sendable {
        public let total: Int      // media files seen
        public let hashed: Int     // files that needed hashing (new/changed)
    }

    public static func scan(vault: Vault, catalog: Catalog,
                            progress: (Progress) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default

        // 1. Walk — skip .openphoto dirs, hidden files, non-media.
        progress(Progress(stage: .walking, done: 0, total: 0))
        var found: [(rel: String, url: URL, size: Int64, mtime: Date, kind: MediaKind)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = fm.enumerator(at: vault.rootURL, includingPropertiesForKeys: keys,
                                       options: [.skipsHiddenFiles])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if url.lastPathComponent == Vault.stateDirName { enumerator.skipDescendants() }
                continue
            }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            found.append((vault.relativePath(of: url), url,
                          Int64(values.fileSize ?? 0),
                          values.contentModificationDate ?? Date(), kind))
        }

        // 2. Fast-path against the manifest: reuse hash when size+mtime match (format §4).
        let oldByPath = Dictionary(uniqueKeysWithValues:
            try Manifest.read(from: vault.manifestURL).map { ($0.path, $0) })
        var entries: [ManifestEntry] = []
        var hashedCount = 0
        for (i, f) in found.enumerated() {
            let mtimeStr = ISO8601Millis.string(from: f.mtime)
            if let old = oldByPath[f.rel], old.size == f.size, old.mtime == mtimeStr {
                entries.append(old)
            } else {
                progress(Progress(stage: .hashing, done: i, total: found.count))
                entries.append(ManifestEntry(hash: try ContentHash.ofFile(at: f.url),
                                             path: f.rel, size: f.size, mtime: mtimeStr))
                hashedCount += 1
            }
        }

        // 3. Extract metadata for hashes the catalog doesn't know yet.
        let known = try catalog.knownHashes()
        var newAssets: [AssetRecord] = []
        var pairCandidates: [LivePhotoPairer.Candidate] = []
        for (i, (entry, f)) in zip(entries, found).enumerated() {
            let isNew = !known.contains(entry.hash.stringValue)
            var meta: MediaMetadata?
            if isNew {
                progress(Progress(stage: .extracting, done: i, total: found.count))
                let m = MetadataExtractor.extract(from: f.url, kind: f.kind)
                meta = m
                newAssets.append(AssetRecord(
                    hash: entry.hash.stringValue, kind: f.kind.rawValue,
                    takenAtMs: Int64(m.takenAt.timeIntervalSince1970 * 1000),
                    pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                    latitude: m.latitude, longitude: m.longitude,
                    cameraModel: m.cameraModel, lensModel: m.lensModel,
                    durationSeconds: m.durationSeconds,
                    livePairHash: nil, isLivePairedVideo: false,
                    favorite: false, rating: 0, caption: nil, tagsJSON: "[]"))
            }
            // Every file in the same folder participates in pairing (CID only known for new).
            pairCandidates.append(.init(
                hash: entry.hash, relPath: entry.path, kind: f.kind,
                takenAt: meta?.takenAt ?? f.mtime, contentIdentifier: meta?.contentIdentifier))
        }

        // 4. Pair Live Photos among this vault's files.
        var assetsByHash = Dictionary(uniqueKeysWithValues: newAssets.map { ($0.hash, $0) })
        for pair in LivePhotoPairer.pair(candidates: pairCandidates) {
            assetsByHash[pair.photoHash.stringValue]?.livePairHash = pair.videoHash.stringValue
            assetsByHash[pair.videoHash.stringValue]?.isLivePairedVideo = true
        }

        // 5. Persist: assets, instances (wholesale replace), manifest (atomic).
        progress(Progress(stage: .finishing, done: found.count, total: found.count))
        try catalog.upsert(assets: Array(assetsByHash.values))
        let instances = zip(entries, found).map { entry, f in
            InstanceRecord(hash: entry.hash.stringValue, vaultID: vault.descriptor.vaultID,
                           relPath: entry.path,
                           dirPath: (entry.path as NSString).deletingLastPathComponent,
                           size: entry.size,
                           mtimeMs: Int64((ISO8601Millis.date(from: entry.mtime) ?? Date())
                               .timeIntervalSince1970 * 1000))
        }
        try catalog.replaceInstances(inVault: vault.descriptor.vaultID, with: instances)
        try Manifest.write(entries, to: vault.manifestURL)
        progress(Progress(stage: .finishing, done: found.count, total: found.count))
        return Result(total: found.count, hashed: hashedCount)
    }
}
```

Note: pairing only re-evaluates **new** assets' CIDs (existing pairs persist in the catalog) — sufficient for Phase 1, where pairing is established the first time both halves are seen.

- [ ] **Step 4: Run** `swift test --filter ScannerTests` — Expected: 5 PASS.
- [ ] **Step 5: Run the whole suite** `swift test` — Expected: all green (no regressions).
- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Scanner/Scanner.swift Tests/OpenPhotoCoreTests/ScannerTests.swift
git commit -m "feat: vault scanner — walk, mtime fast-path, hash, metadata, pairing, reconcile"
```

### Task 11: BinStore (delete / restore / list — never hard-delete)

**Files:**
- Create: `Sources/OpenPhotoCore/Vault/BinStore.swift`
- Test: `Tests/OpenPhotoCoreTests/BinStoreTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func deleteMovesToBinPreservingPathAndLogs() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let media = try t.file("Pictures/rome2022/IMG_1.jpg", Data("img".utf8))
    try t.file("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp", Data("<x/>".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let bin = BinStore(vault: vault)

    try bin.moveToBin(relPath: "rome2022/IMG_1.jpg",
                      hash: ContentHash(stringValue: "sha256:" + String(repeating: "a", count: 64)),
                      origin: .user)

    #expect(!FileManager.default.fileExists(atPath: media.path))
    let binned = root.appendingPathComponent(".openphoto/bin/rome2022/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: binned.path))
    // Sidecar travels into the bin beside it (same convention).
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".openphoto/bin/rome2022/.openphoto/IMG_1.jpg.xmp").path))
    let items = try bin.list()
    #expect(items.count == 1 && items[0].path == "rome2022/IMG_1.jpg" && items[0].origin == .user)
}

@Test func restorePutsFileBack() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/a/b.jpg", Data("x".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let bin = BinStore(vault: vault)
    let h = ContentHash(stringValue: "sha256:" + String(repeating: "b", count: 64))
    try bin.moveToBin(relPath: "a/b.jpg", hash: h, origin: .user)
    try bin.restore(relPath: "a/b.jpg")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b.jpg").path))
    #expect(try bin.list().isEmpty)
}
```

- [ ] **Step 2: Run** `swift test --filter BinStoreTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Vault bin — vault-format-v1 §8. Nothing in the system hard-deletes.
public struct BinStore: Sendable {
    public enum Origin: String, Codable, Sendable { case user, propagated }

    public struct BinItem: Codable, Equatable, Sendable {
        public let hash: String
        public let path: String
        public let deletedAt: String
        public let origin: Origin
        enum CodingKeys: String, CodingKey {
            case hash, path, origin
            case deletedAt = "deleted_at"
        }
    }

    let vault: Vault
    public init(vault: Vault) { self.vault = vault }

    public func moveToBin(relPath: String, hash: ContentHash, origin: Origin) throws {
        let fm = FileManager.default
        let src = vault.absoluteURL(forRelativePath: relPath)
        let dst = vault.binDirURL.appendingPathComponent(relPath)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        // Sidecar travels with the file, same folder-level convention inside bin/.
        let sidecar = vault.sidecarURL(forMediaAt: src)
        if fm.fileExists(atPath: sidecar.path) {
            let sidecarDst = vault.sidecarURL(forMediaAt: dst)
            try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: sidecar, to: sidecarDst)
        }
        var items = try list()
        items.append(BinItem(hash: hash.stringValue, path: relPath,
                             deletedAt: ISO8601Millis.string(from: Date()), origin: origin))
        try writeLog(items)
    }

    public func restore(relPath: String) throws {
        let fm = FileManager.default
        let src = vault.binDirURL.appendingPathComponent(relPath)
        let dst = vault.absoluteURL(forRelativePath: relPath)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        let sidecarSrc = vault.sidecarURL(forMediaAt: src)
        if fm.fileExists(atPath: sidecarSrc.path) {
            let sidecarDst = vault.sidecarURL(forMediaAt: dst)
            try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: sidecarSrc, to: sidecarDst)
        }
        try writeLog(try list().filter { $0.path != relPath })
    }

    public func list() throws -> [BinItem] {
        guard let data = try? Data(contentsOf: vault.binLogURL) else { return [] }
        let dec = JSONDecoder()
        return try data.split(separator: 0x0A).filter { !$0.isEmpty }
            .map { try dec.decode(BinItem.self, from: $0) }
    }

    public func binnedFileURL(relPath: String) -> URL {
        vault.binDirURL.appendingPathComponent(relPath)
    }

    private func writeLog(_ items: [BinItem]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for i in items { out.append(try enc.encode(i)); out.append(0x0A) }
        try AtomicFile.write(out, to: vault.binLogURL)
    }
}
```

- [ ] **Step 4: Run** `swift test --filter BinStoreTests` — Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Vault/BinStore.swift Tests/OpenPhotoCoreTests/BinStoreTests.swift
git commit -m "feat: vault bin — delete/restore with sidecars, bin.jsonl per format v1 §8"
```

### Task 12: ThumbnailStore

**Files:**
- Create: `Sources/OpenPhotoCore/Thumbnails/ThumbnailStore.swift`
- Test: `Tests/OpenPhotoCoreTests/ThumbnailStoreTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

@Test func generatesAndCachesImageThumb() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let img = t.root.appendingPathComponent("p.jpg")
    try makeJPEG(at: img, dateTimeOriginal: nil, lat: nil, lon: nil)
    let store = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let h = ContentHash(stringValue: "sha256:" + String(repeating: "d", count: 64))
    let cg1 = try store.thumbnail(for: h, sourceURL: img, kind: .photo)
    #expect(cg1 != nil)
    #expect(FileManager.default.fileExists(atPath: store.cacheURL(for: h).path))
    // Second call serves from cache even if the source is gone (evicted files).
    try FileManager.default.removeItem(at: img)
    #expect(try store.thumbnail(for: h, sourceURL: img, kind: .photo) != nil)
}

@Test func generatesVideoThumb() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let mov = t.root.appendingPathComponent("c.mov")
    try await makeMOV(at: mov)
    let store = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let h = ContentHash(stringValue: "sha256:" + String(repeating: "e", count: 64))
    #expect(try store.thumbnail(for: h, sourceURL: mov, kind: .video) != nil)
}
```

- [ ] **Step 2: Run** `swift test --filter ThumbnailStoreTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation
import ImageIO
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

/// Content-addressed JPEG thumbnail cache: <cacheDir>/<hex[0..2]>/<hex>.jpg
/// Cache survives eviction — that's what keeps offline photos browsable.
public final class ThumbnailStore: Sendable {
    public static let maxPixel = 512
    private let cacheDir: URL

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

    public func cacheURL(for hash: ContentHash) -> URL {
        let hex = String(hash.stringValue.split(separator: ":").last ?? "x")
        return cacheDir.appendingPathComponent(String(hex.prefix(2)))
            .appendingPathComponent(hex + ".jpg")
    }

    /// Returns cached thumb, generating it from sourceURL if absent.
    public func thumbnail(for hash: ContentHash, sourceURL: URL, kind: MediaKind) throws -> CGImage? {
        let cached = cacheURL(for: hash)
        if let src = CGImageSourceCreateWithURL(cached as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        guard let img = generate(from: sourceURL, kind: kind) else { return nil }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(cached as CFURL,
                                                      UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return img
    }

    private func generate(from url: URL, kind: MediaKind) -> CGImage? {
        switch kind {
        case .photo:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: Self.maxPixel, height: Self.maxPixel)
            return try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600),
                                        actualTime: nil)
        }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter ThumbnailStoreTests` — Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Thumbnails Tests/OpenPhotoCoreTests/ThumbnailStoreTests.swift
git commit -m "feat: content-addressed thumbnail cache (images + video frames)"
```

### Task 13: XMP sidecars (SidecarData, XMP serialize/parse, SidecarStore)

Human-authored metadata only (spec §3): rating, favorite, caption, tags. (Title and people regions arrive in later phases.) Favorite is stored as the standard `xmp:Label` value `"Favorite"`. **Format-relevant → add the favorite/Label convention to `docs/format/vault-format-v1.md` §5 table in this commit.**

**Files:**
- Create: `Sources/OpenPhotoCore/Sidecar/SidecarData.swift`
- Create: `Sources/OpenPhotoCore/Sidecar/XMP.swift`
- Create: `Sources/OpenPhotoCore/Sidecar/SidecarStore.swift`
- Modify: `docs/format/vault-format-v1.md` (§5 table: add `Favorite | xmp:Label = "Favorite"` row)
- Test: `Tests/OpenPhotoCoreTests/SidecarTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func xmpRoundTrip() throws {
    let data = SidecarData(rating: 4, favorite: true,
                           caption: "Trevi at dusk — café & \"friends\" <3",
                           tags: ["travel", "rome", "night"])
    let xml = XMP.serialize(data)
    let parsed = try XMP.parse(Data(xml.utf8))
    #expect(parsed == data)
}

@Test func emptySidecarOmitsElements() throws {
    let xml = XMP.serialize(SidecarData(rating: 0, favorite: false, caption: nil, tags: []))
    #expect(!xml.contains("dc:subject"))
    #expect(!xml.contains("dc:description"))
    let parsed = try XMP.parse(Data(xml.utf8))
    #expect(parsed.rating == 0 && parsed.tags.isEmpty)
}

@Test func storeWritesIntoFolderLevelOpenphotoDir() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/rome2022/IMG_1.jpg", Data("x".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let store = SidecarStore(vault: vault)
    let data = SidecarData(rating: 5, favorite: false, caption: "c", tags: ["t"])
    try store.write(data, forMediaRelPath: "rome2022/IMG_1.jpg")
    let sidecar = root.appendingPathComponent("rome2022/.openphoto/IMG_1.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    #expect(try store.read(forMediaRelPath: "rome2022/IMG_1.jpg") == data)
    // Missing sidecar reads as empty.
    #expect(try store.read(forMediaRelPath: "rome2022/other.jpg") == SidecarData.empty)
}
```

- [ ] **Step 2: Run** `swift test --filter SidecarTests` — Expected: FAIL.

- [ ] **Step 3: Implement `SidecarData.swift`**

```swift
import Foundation

public struct SidecarData: Equatable, Sendable {
    public var rating: Int          // 0–5; 0 = unrated
    public var favorite: Bool
    public var caption: String?
    public var tags: [String]

    public static let empty = SidecarData(rating: 0, favorite: false, caption: nil, tags: [])

    public init(rating: Int, favorite: Bool, caption: String?, tags: [String]) {
        self.rating = rating; self.favorite = favorite
        self.caption = (caption?.isEmpty == true) ? nil : caption
        self.tags = tags
    }
}
```

- [ ] **Step 4: Implement `XMP.swift`** (XMLDocument is macOS Foundation; standard namespaces per format §5)

```swift
import Foundation

public enum XMP {
    static let nsX = "adobe:ns:meta/"
    static let nsRDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let nsXMP = "http://ns.adobe.com/xap/1.0/"
    static let nsDC = "http://purl.org/dc/elements/1.1/"

    public static func serialize(_ d: SidecarData) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var inner = ""
        if let c = d.caption {
            inner += "      <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(esc(c))</rdf:li></rdf:Alt></dc:description>\n"
        }
        if !d.tags.isEmpty {
            let lis = d.tags.map { "<rdf:li>\(esc($0))</rdf:li>" }.joined()
            inner += "      <dc:subject><rdf:Bag>\(lis)</rdf:Bag></dc:subject>\n"
        }
        let ratingAttr = d.rating > 0 ? " xmp:Rating=\"\(d.rating)\"" : ""
        let labelAttr = d.favorite ? " xmp:Label=\"Favorite\"" : ""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="\(nsX)">
         <rdf:RDF xmlns:rdf="\(nsRDF)">
          <rdf:Description rdf:about=""
            xmlns:xmp="\(nsXMP)" xmlns:dc="\(nsDC)"\(ratingAttr)\(labelAttr)>
        \(inner)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    public static func parse(_ data: Data) throws -> SidecarData {
        let doc = try XMLDocument(data: data)
        guard let desc = try doc.nodes(forXPath: "//*[local-name()='Description']").first
            as? XMLElement else { return .empty }
        let rating = Int(attr(desc, "Rating") ?? "0") ?? 0
        let favorite = (attr(desc, "Label") == "Favorite")
        let caption = (try? desc.nodes(forXPath:
            ".//*[local-name()='description']//*[local-name()='li']"))?
            .first?.stringValue
        let tags = ((try? desc.nodes(forXPath:
            ".//*[local-name()='subject']//*[local-name()='li']")) ?? [])
            .compactMap(\.stringValue)
        return SidecarData(rating: rating, favorite: favorite, caption: caption, tags: tags)
    }

    private static func attr(_ el: XMLElement, _ localName: String) -> String? {
        el.attributes?.first { $0.localName == localName }?.stringValue
    }
}
```

- [ ] **Step 5: Implement `SidecarStore.swift`**

```swift
import Foundation

/// Reads/writes sidecars at their format-v1 §5 location, atomically.
public struct SidecarStore: Sendable {
    let vault: Vault
    public init(vault: Vault) { self.vault = vault }

    public func read(forMediaRelPath rel: String) throws -> SidecarData {
        let url = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel))
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return try XMP.parse(data)
    }

    public func write(_ data: SidecarData, forMediaRelPath rel: String) throws {
        let url = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel))
        try AtomicFile.write(Data(XMP.serialize(data).utf8), to: url)
    }
}
```

- [ ] **Step 6: Run** `swift test --filter SidecarTests` — Expected: 3 PASS.

- [ ] **Step 7: Update format doc** — add to the §5 table in `docs/format/vault-format-v1.md`:

```
| Favorite | `xmp:Label` with value `"Favorite"` |
```

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenPhotoCore/Sidecar Tests/OpenPhotoCoreTests/SidecarTests.swift docs/format/vault-format-v1.md
git commit -m "feat: XMP sidecar read/write (rating, favorite, caption, tags) per format v1 §5"
```

### Task 14: LibraryService (the facade the app uses)

Owns vaults + catalog + thumbs + sidecars; exposes async scan with progress, browse queries, edits, delete/restore. `@MainActor`-published state lives in the app layer — this stays headless.

**Files:**
- Create: `Sources/OpenPhotoCore/LibraryService.swift`
- Test: `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func makeLibrary(_ t: TestDirs) throws -> LibraryService {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    return try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("appsupport"))
}

@Test func scanThenBrowse() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let sections = try lib.timelineSections()
    #expect(sections.count == 2)                       // two distinct days
    #expect(sections[0].items[0].relPath == "lisbon25/IMG_2.jpg")   // newest first
    let tree = try lib.folderTree()
    #expect(tree.map(\.name).sorted() == ["lisbon25", "rome2022"])
}

@Test func editWritesSidecarAndCatalog() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let item = try lib.timelineSections()[0].items[0]
    try lib.updateMetadata(for: item, rating: 4, favorite: true, caption: "hi", tags: ["x"])
    // Catalog mirror updated:
    let reloaded = try lib.item(hash: item.hash)
    #expect(reloaded?.rating == 4 && reloaded?.favorite == true)
    // Sidecar exists on disk at the format location:
    let sidecar = t.root.appendingPathComponent("Pictures/lisbon25/.openphoto/IMG_2.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
}

@Test func deleteToBinAndRestore() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let item = try lib.timelineSections()[0].items[0]
    try await lib.delete(item)
    #expect(try lib.timelineSections().flatMap(\.items).count == 1)
    let binned = try lib.binItems()
    #expect(binned.count == 1)
    try await lib.restore(binned[0])
    #expect(try lib.timelineSections().flatMap(\.items).count == 2)
}

@Test func scanPicksUpSidecarsFromDisk() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    // Sidecar written by another tool before our first scan:
    try t.file("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp",
               Data(XMP.serialize(SidecarData(rating: 3, favorite: false,
                                              caption: nil, tags: ["pre"])).utf8))
    try await lib.scanAll()
    let rome = try lib.items(inDir: "rome2022")
    #expect(rome[0].rating == 3 && rome[0].tagsJSON.contains("pre"))
}
```

- [ ] **Step 2: Run** `swift test --filter LibraryServiceTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct TimelineSection: Sendable, Equatable {
    public let dayStartMs: Int64
    public let title: String        // "Friday, June 6" / "March 12, 2024"
    public let items: [TimelineItem]
}

public struct FolderNode: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String         // dirPath
    public let name: String
    public let count: Int           // direct items
    public var children: [FolderNode]
}

public final class LibraryService: @unchecked Sendable {
    public let vaults: [Vault]
    public let catalog: Catalog
    public let thumbnails: ThumbnailStore
    private let sidecarStores: [String: SidecarStore]   // vaultID → store
    private let binStores: [String: BinStore]

    public init(vaultRoots: [URL], appSupportDir: URL) throws {
        var vs: [Vault] = []
        for root in vaultRoots {
            vs.append(try Vault.openOrCreate(at: root, role: .local))
        }
        vaults = vs
        catalog = try Catalog(at: appSupportDir.appendingPathComponent("catalog.sqlite"))
        thumbnails = ThumbnailStore(cacheDir: appSupportDir.appendingPathComponent("thumbs"))
        sidecarStores = Dictionary(uniqueKeysWithValues:
            vs.map { ($0.descriptor.vaultID, SidecarStore(vault: $0)) })
        binStores = Dictionary(uniqueKeysWithValues:
            vs.map { ($0.descriptor.vaultID, BinStore(vault: $0)) })
        for v in vs {
            try catalog.registerVault(id: v.descriptor.vaultID,
                                      role: v.descriptor.role.rawValue,
                                      rootPath: v.rootURL.path)
        }
    }

    public func vault(id: String) -> Vault? { vaults.first { $0.descriptor.vaultID == id } }

    public func absoluteURL(for item: TimelineItem) -> URL? {
        vault(id: item.vaultID)?.absoluteURL(forRelativePath: item.relPath)
    }

    // MARK: Scan

    /// Full scan of all vaults off the calling thread; progress on an AsyncStream.
    public func scanAll(progress: (@Sendable (Scanner.Progress) -> Void)? = nil) async throws {
        for v in vaults {
            let vault = v
            try await Task.detached(priority: .utility) { [catalog] in
                _ = try Scanner.scan(vault: vault, catalog: catalog) { progress?($0) }
            }.value
            try ingestSidecars(vault: v)
        }
    }

    /// Mirror on-disk sidecars into catalog columns (sidecars are authoritative).
    private func ingestSidecars(vault: Vault) throws {
        guard let store = sidecarStores[vault.descriptor.vaultID] else { return }
        for entry in try Manifest.read(from: vault.manifestURL) {
            let data = try store.read(forMediaRelPath: entry.path)
            guard data != .empty else { continue }
            let tags = String(data: try JSONEncoder().encode(data.tags), encoding: .utf8) ?? "[]"
            try catalog.updateHumanMetadata(hash: entry.hash.stringValue,
                                            favorite: data.favorite, rating: data.rating,
                                            caption: data.caption, tagsJSON: tags)
        }
    }

    // MARK: Browse

    public func timelineSections() throws -> [TimelineSection] {
        sections(from: try catalog.timelineItems())
    }

    public func items(inDir dir: String) throws -> [TimelineItem] {
        try catalog.items(inDir: dir)
    }

    public func item(hash: String) throws -> TimelineItem? { try catalog.item(hash: hash) }

    public func folderTree() throws -> [FolderNode] {
        let counts = try catalog.folderCounts()
        var roots: [FolderNode] = []
        // Build a nested tree from flat dirPaths ("a/b/c").
        var byPath: [String: FolderNode] = [:]
        for (path, count) in counts where !path.isEmpty {
            byPath[path] = FolderNode(path: path,
                                      name: (path as NSString).lastPathComponent,
                                      count: count, children: [])
            // Materialize intermediate dirs with 0 direct items.
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, byPath[parent] == nil {
                byPath[parent] = FolderNode(path: parent,
                                            name: (parent as NSString).lastPathComponent,
                                            count: counts[parent] ?? 0, children: [])
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for node in byPath.values.sorted(by: { $0.path > $1.path }) {  // deepest first
            let parent = (node.path as NSString).deletingLastPathComponent
            if parent.isEmpty {
                roots.append(node)
            } else {
                byPath[parent]?.children.append(node)
                byPath[parent]?.children.sort { $0.name < $1.name }
            }
        }
        return roots.sorted { $0.name < $1.name }
    }

    private func sections(from items: [TimelineItem]) -> [TimelineSection] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateStyle = .full; fmt.timeStyle = .none
        var result: [TimelineSection] = []
        for item in items {   // already newest-first
            let day = cal.startOfDay(for: Date(timeIntervalSince1970:
                Double(item.takenAtMs) / 1000))
            let dayMs = Int64(day.timeIntervalSince1970 * 1000)
            if result.last?.dayStartMs == dayMs {
                result[result.count - 1] = TimelineSection(
                    dayStartMs: dayMs, title: result[result.count - 1].title,
                    items: result[result.count - 1].items + [item])
            } else {
                result.append(TimelineSection(dayStartMs: dayMs,
                                              title: fmt.string(from: day), items: [item]))
            }
        }
        return result
    }

    // MARK: Edit

    public func updateMetadata(for item: TimelineItem, rating: Int, favorite: Bool,
                               caption: String?, tags: [String]) throws {
        let data = SidecarData(rating: rating, favorite: favorite, caption: caption, tags: tags)
        try sidecarStores[item.vaultID]?.write(data, forMediaRelPath: item.relPath)  // durable first
        let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
        try catalog.updateHumanMetadata(hash: item.hash, favorite: favorite,
                                        rating: rating, caption: caption, tagsJSON: tagsJSON)
    }

    // MARK: Delete / restore

    public struct BinEntry: Sendable, Identifiable, Equatable {
        public var id: String { vaultID + "|" + item.path }
        public let vaultID: String
        public let item: BinStore.BinItem
        public let fileURL: URL
    }

    public func delete(_ item: TimelineItem) async throws {
        guard let bin = binStores[item.vaultID] else { return }
        try bin.moveToBin(relPath: item.relPath,
                          hash: ContentHash(stringValue: item.hash), origin: .user)
        // If this is a Live Photo, the paired video goes too.
        if let pairHash = item.livePairHash,
           let pairItem = try catalog.instanceItem(hash: pairHash, vaultID: item.vaultID) {
            try bin.moveToBin(relPath: pairItem.relPath,
                              hash: ContentHash(stringValue: pairHash), origin: .user)
        }
        try await rescan(vaultID: item.vaultID)
    }

    public func restore(_ entry: BinEntry) async throws {
        try binStores[entry.vaultID]?.restore(relPath: entry.item.path)
        try await rescan(vaultID: entry.vaultID)
    }

    public func binItems() throws -> [BinEntry] {
        var out: [BinEntry] = []
        for v in vaults {
            guard let bin = binStores[v.descriptor.vaultID] else { continue }
            for i in try bin.list() {
                out.append(BinEntry(vaultID: v.descriptor.vaultID, item: i,
                                    fileURL: bin.binnedFileURL(relPath: i.path)))
            }
        }
        return out.sorted { $0.item.deletedAt > $1.item.deletedAt }
    }

    private func rescan(vaultID: String) async throws {
        guard let v = vault(id: vaultID) else { return }
        try await Task.detached(priority: .utility) { [catalog] in
            _ = try Scanner.scan(vault: v, catalog: catalog)
        }.value
    }
}

extension Catalog {
    /// Lightweight instance lookup used for Live Photo pair deletion.
    func instanceItem(hash: String, vaultID: String) throws -> InstanceRecord? {
        try dbQueue.read { db in
            try InstanceRecord.fetchOne(db, sql:
                "SELECT * FROM instances WHERE hash = ? AND vaultID = ? LIMIT 1",
                arguments: [hash, vaultID])
        }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter LibraryServiceTests` — Expected: 4 PASS.
- [ ] **Step 5: Run full suite** `swift test` — Expected: all green.
- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService.swift Tests/OpenPhotoCoreTests/LibraryServiceTests.swift
git commit -m "feat: LibraryService facade — scan, sections, folder tree, edits, bin"
```

### Task 15: FolderWatcher (FSEvents → debounced rescan)

**Files:**
- Create: `Sources/OpenPhotoCore/Scanner/FolderWatcher.swift`
- Test: `Tests/OpenPhotoCoreTests/FolderWatcherTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func firesAfterFileChange() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("watched")
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let watcher = FolderWatcher(paths: [dir.path], debounce: .milliseconds(200)) {
        continuation.yield(())
    }
    watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))   // let the FSEvents stream warm up
    try Data("x".utf8).write(to: dir.appendingPathComponent("new.jpg"))
    let result = await withTimeout(seconds: 5) {
        var it = stream.makeAsyncIterator()         // created inside the task — no capture issue
        return await it.next() != nil
    }
    #expect(result)   // change observed within 5s
}

/// Race an async predicate against a deadline.
func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await op() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 2: Run** `swift test --filter FolderWatcherTests` — Expected: FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation
import CoreServices

/// FSEvents wrapper: watches vault roots, fires a debounced callback on change.
/// The callback should trigger an incremental rescan (cheap — mtime fast-path).
public final class FolderWatcher: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let paths: [String]
    private let debounce: Duration
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "openphoto.fsevents")
    private var pending: DispatchWorkItem?

    public init(paths: [String], debounce: Duration = .seconds(2),
                onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleFire()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    private func scheduleFire() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        let ms = Int(debounce.components.seconds * 1000
            + debounce.components.attoseconds / 1_000_000_000_000_000)
        queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    deinit { stop() }
}
```

Note: events under `.openphoto/` also fire the callback — that's fine because the rescan is a fast-path no-op; do **not** try to filter paths here (manifest writes settle before the debounce fires).

- [ ] **Step 4: Run** `swift test --filter FolderWatcherTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Scanner/FolderWatcher.swift Tests/OpenPhotoCoreTests/FolderWatcherTests.swift
git commit -m "feat: FSEvents folder watcher with debounced rescan callback"
```

---

# Part B — OpenPhotoApp (SwiftUI)

UI tasks are verified by `swift build` + `swift run OpenPhotoApp` + a visual check against the prototype (`open UI-Design/design_handoff_openphoto/OpenPhoto.html`). Keep the prototype open side-by-side. Tokens below come from its README — do not invent colors.

### Task 16: Theme + AppState + app shell with sidebar

**Files:**
- Create: `Sources/OpenPhotoApp/Theme.swift`
- Create: `Sources/OpenPhotoApp/AppState.swift`
- Create: `Sources/OpenPhotoApp/Sidebar/SidebarView.swift`
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift`

- [ ] **Step 1: `Theme.swift`** (exact tokens from UI-Design README)

```swift
import SwiftUI

/// Design tokens — UI-Design/design_handoff_openphoto/README.md. Do not improvise.
enum Theme {
    static let accent = Color(hex: 0xCF5C57)          // warm coral-red
    static let accentHi = Color(hex: 0xD87B76)
    static var accentDim: Color { accent.opacity(0.16) }

    // Dark is the primary appearance; light variants via asset-style dynamic init.
    static let windowBG = Color(light: 0xF7F5F2, dark: 0x1B1917)
    static let bg2 = Color(light: 0xF1EEEA, dark: 0x211F1C)
    static let elevated = Color(light: 0xFFFFFF, dark: 0x2A2724)
    static let text = Color(light: 0x211E1B, dark: 0xECE9E4)
    static let textDim = Color(light: 0x6C6862, dark: 0xA39E97)
    static let textFaint = Color(light: 0x9A958D, dark: 0x726D66)
    static let tile = Color(light: 0xE7E3DD, dark: 0x2C2926)
    static let green = Color(light: 0x3F9D5F, dark: 0x5FB47A)
    static let amber = Color(light: 0xB9852A, dark: 0xD8A23E)
    static let blue = Color(light: 0x3F7FBF, dark: 0x6AA3D8)
    static var hairline: Color { Color.primary.opacity(0.09) }

    static let sidebarWidth: CGFloat = 248
    static let folderTreeWidth: CGFloat = 250
    static let inspectorWidth: CGFloat = 332
    static let toolbarHeight: CGFloat = 52
    static let gridGap: CGFloat = 3
    static let cellRadius: CGFloat = 3
    static let cardRadius: CGFloat = 13
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    /// Dynamic light/dark color.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
```

- [ ] **Step 2: `AppState.swift`**

```swift
import SwiftUI
import OpenPhotoCore

enum SidebarItem: String, Hashable, CaseIterable {
    case timeline, folders, bin
    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .folders: "Folders"
        case .bin: "Bin"
        }
    }
    var symbol: String {
        switch self {   // SF Symbol map from the UI-Design README
        case .timeline: "photo.on.rectangle.angled"
        case .folders: "folder"
        case .bin: "trash"
        }
    }
}

@Observable @MainActor
final class AppState {
    static let rootsDefaultsKey = "libraryRootPaths"

    var library: LibraryService?
    var selection: SidebarItem = .timeline
    var selectedFolder: String?              // dirPath in Folders view
    var openedItem: TimelineItem?            // non-nil → Viewer is presented
    var inspectorShown = true
    var gridMinSize: CGFloat = 132           // grid-size slider, 92…220
    var sections: [TimelineSection] = []
    var folderTree: [FolderNode] = []
    var binEntries: [LibraryService.BinEntry] = []
    var scanProgress: Scanner.Progress?
    var scanning = false
    private var watcher: FolderWatcher?

    var configuredRoots: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.rootsDefaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    func openLibrary(roots: [URL]) {
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.rootsDefaultsKey)
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenPhoto")
            library = try LibraryService(vaultRoots: roots, appSupportDir: appSupport)
            startWatcher(roots: roots)
            Task { await rescan() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func rescan() async {
        guard let library, !scanning else { return }
        scanning = true
        defer { scanning = false; scanProgress = nil }
        do {
            try await library.scanAll { [weak self] p in
                Task { @MainActor in self?.scanProgress = p }
            }
            try refreshQueries()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func refreshQueries() throws {
        guard let library else { return }
        sections = try library.timelineSections()
        folderTree = try library.folderTree()
        binEntries = try library.binItems()
    }

    private func startWatcher(roots: [URL]) {
        watcher = FolderWatcher(paths: roots.map(\.path)) { [weak self] in
            Task { @MainActor in await self?.rescan() }
        }
        watcher?.start()
    }
}
```

- [ ] **Step 3: `SidebarView.swift`**

```swift
import SwiftUI
import OpenPhotoCore

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIBRARY")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.44)
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            ForEach(SidebarItem.allCases, id: \.self) { item in
                let active = state.selection == item
                Button {
                    state.selection = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.label).font(.system(size: 13.5, weight: .medium))
                        Spacer()
                        if item == .bin, !state.binEntries.isEmpty {
                            Text("\(state.binEntries.count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? Theme.accentDim : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(active ? Theme.accent : Theme.text)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
            if let p = state.scanProgress {
                ActivityIndicatorView(progress: p)
            }
        }
        .frame(width: Theme.sidebarWidth)
        .background(.ultraThinMaterial)
    }
}

struct ActivityIndicatorView: View {
    let progress: Scanner.Progress
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Indexing library").font(.system(size: 12, weight: .medium))
            }
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Theme.accent)
                Text("\(progress.done) of \(progress.total) · \(progress.stage.rawValue)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(12)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}
```

- [ ] **Step 4: Rewrite `OpenPhotoApp.swift`**

```swift
import SwiftUI
import OpenPhotoCore

@main
struct OpenPhotoApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("OpenPhoto") {
            RootView(state: state)
                .frame(minWidth: 1100, minHeight: 700)
                .background(Theme.windowBG)
                .tint(Theme.accent)
                .task {
                    let roots = state.configuredRoots
                    if !roots.isEmpty { state.openLibrary(roots: roots) }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct RootView: View {
    @Bindable var state: AppState

    var body: some View {
        if state.library == nil {
            WelcomeView(state: state)
        } else {
            ZStack {
                HStack(spacing: 0) {
                    SidebarView(state: state)
                    Divider().overlay(Theme.hairline)
                    detail
                }
                if state.openedItem != nil {
                    ViewerView(state: state)   // full-window overlay
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .timeline: TimelineView(state: state)
        case .folders: FoldersView(state: state)
        case .bin: BinView(state: state)
        }
    }
}
```

`WelcomeView`, `TimelineView`, `FoldersView`, `ViewerView`, `BinView` don't exist yet — add **temporary placeholder views** in their future files so this task builds (each is `Text("…") /* Task NN */`), replaced by Tasks 17–21.

- [ ] **Step 5: Build & run** — `swift build && swift run OpenPhotoApp`. Expected: window with translucent sidebar, three items, placeholder detail. Compare chrome to prototype.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp
git commit -m "feat(app): theme tokens, app state, sidebar shell"
```

### Task 17: WelcomeView (first launch)

**Files:**
- Modify: `Sources/OpenPhotoApp/Welcome/WelcomeView.swift` (replace placeholder)

- [ ] **Step 1: Implement** (per `states.jsx`: centered card, folder list, dashed add button, reassurance copy — minus drive features which are Phase 3)

```swift
import SwiftUI
import OpenPhotoCore

struct WelcomeView: View {
    @Bindable var state: AppState
    @State private var roots: [URL] = []

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Welcome to OpenPhoto").font(.system(size: 24, weight: .bold))
            Text("Your photos stay exactly where they are — regular files in regular folders.\nOpenPhoto only indexes them. Delete the app and your library is untouched.")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                ForEach(roots, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        Text(url.path).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                        Button { roots.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 9))
                }
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.directoryURL = FileManager.default.urls(for: .picturesDirectory,
                                                                  in: .userDomainMask).first
                    if panel.runModal() == .OK {
                        roots.append(contentsOf: panel.urls.filter { !roots.contains($0) })
                    }
                } label: {
                    Label("Choose a folder…", systemImage: "plus")
                        .frame(maxWidth: .infinity).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.hairline, style: .init(lineWidth: 1, dash: [5])))
                }.buttonStyle(.plain)
            }
            .frame(width: 460)

            Button("Open library") { state.openLibrary(roots: roots) }
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty)

            Text("Suggested: your Pictures and Movies folders.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Verify** — delete the saved default (`defaults delete openphoto libraryRootPaths` may not exist yet; simply run) and `swift run OpenPhotoApp`: pick a small test folder of images, Open library → scan runs (sidebar indicator), placeholder timeline appears after.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Welcome
git commit -m "feat(app): first-launch welcome with library folder selection"
```

### Task 18: ThumbView, PhotoCellView, TimelineView

**Files:**
- Create: `Sources/OpenPhotoApp/Timeline/ThumbView.swift`
- Create: `Sources/OpenPhotoApp/Timeline/PhotoCellView.swift`
- Modify: `Sources/OpenPhotoApp/Timeline/TimelineView.swift` (replace placeholder)

- [ ] **Step 1: `ThumbView.swift`** — async thumbnail loading

```swift
import SwiftUI
import OpenPhotoCore

struct ThumbView: View {
    let item: TimelineItem
    let library: LibraryService
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.tile
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: item.hash) {
            let lib = library, it = item
            image = await Task.detached(priority: .userInitiated) {
                guard let url = lib.absoluteURL(for: it) else { return nil }
                return try? lib.thumbnails.thumbnail(
                    for: ContentHash(stringValue: it.hash), sourceURL: url,
                    kind: MediaKind(rawValue: it.kind) ?? .photo)
            }.value
        }
    }
}
```

- [ ] **Step 2: `PhotoCellView.swift`** — badges per README §Timeline (LIVE, video duration, favorite heart; offline badge arrives in Phase 3)

```swift
import SwiftUI
import OpenPhotoCore

struct PhotoCellView: View {
    let item: TimelineItem
    let library: LibraryService
    @State private var hovering = false

    var body: some View {
        ThumbView(item: item, library: library)
            .scaleEffect(hovering ? 1.045 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .overlay(alignment: .topTrailing) {
                if item.livePairHash != nil {
                    badge(symbol: "livephoto")
                } else if item.kind == MediaKind.video.rawValue {
                    badge(symbol: "play.fill", text: duration)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.favorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 2).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var duration: String? {
        guard let s = item.durationSeconds else { return nil }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func badge(symbol: String, text: String? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            if let text { Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(5)
    }
}
```

- [ ] **Step 3: `TimelineView.swift`**

```swift
import SwiftUI
import OpenPhotoCore

struct TimelineView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                             spacing: Theme.gridGap)],
                          spacing: Theme.gridGap,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(state.sections, id: \.dayStartMs) { section in
                        Section {
                            ForEach(section.items, id: \.hash) { item in
                                PhotoCellView(item: item, library: state.library!)
                                    .aspectRatio(1, contentMode: .fill)
                                    .onTapGesture { state.openedItem = item }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                    .font(.system(size: 16, weight: .bold))
                                Spacer()
                                Text("\(section.items.count) items")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 8)
                            .background(Theme.windowBG.opacity(0.92))
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("Timeline").font(.system(size: 15, weight: .semibold))
            Text(stats).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 92...220).frame(width: 120)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private var stats: String {
        let all = state.sections.flatMap(\.items)
        let v = all.filter { $0.kind == MediaKind.video.rawValue }.count
        return "\(all.count - v) photos · \(v) videos"
    }
}
```

(The year scrubber from the README is deferred — see the "Deferred within Phase 1" list at the end of this plan.)

- [ ] **Step 4: Verify** — `swift run OpenPhotoApp` with a test folder: grid renders grouped by day, newest first; badges on videos; hover scale; slider resizes cells; clicking a cell flips to the (placeholder) viewer; ⌘-click prototype comparison.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/Timeline
git commit -m "feat(app): timeline grid with sticky day headers, badges, grid-size slider"
```

### Task 19: FoldersView (tree + grid + breadcrumb)

**Files:**
- Modify: `Sources/OpenPhotoApp/Folders/FolderTreeView.swift`
- Modify: `Sources/OpenPhotoApp/Folders/FolderGridView.swift`
- Modify: `Sources/OpenPhotoApp/Folders/FoldersView.swift` (created as placeholder in Task 16; if you named the placeholder file differently, align to these three files)

- [ ] **Step 1: Implement**

`FoldersView.swift`:

```swift
import SwiftUI
import OpenPhotoCore

struct FoldersView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            FolderTreeView(state: state)
                .frame(width: Theme.folderTreeWidth)
            Divider().overlay(Theme.hairline)
            FolderGridView(state: state)
        }
    }
}
```

`FolderTreeView.swift`:

```swift
import SwiftUI
import OpenPhotoCore

struct FolderTreeView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.folderTree) { node in
                    FolderRow(node: node, state: state, depth: 0)
                }
            }
            .padding(8)
        }
        .background(Theme.bg2.opacity(0.5))
    }
}

private struct FolderRow: View {
    let node: FolderNode
    @Bindable var state: AppState
    let depth: Int
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if node.children.isEmpty {
                    Spacer().frame(width: 14)
                } else {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: 14)
                    }.buttonStyle(.plain)
                }
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(state.selectedFolder == node.path ? Theme.accent : Theme.textDim)
                Text(node.name).font(.system(size: 13))
                Spacer()
                if node.count > 0 {
                    Text("\(node.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .padding(.leading, CGFloat(depth) * 14)
            .background(state.selectedFolder == node.path ? Theme.accentDim : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { state.selectedFolder = node.path }
            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, state: state, depth: depth + 1)
                }
            }
        }
    }
}
```

`FolderGridView.swift`:

```swift
import SwiftUI
import OpenPhotoCore

struct FolderGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            if state.selectedFolder == nil {
                ContentUnavailableView("Select a folder", systemImage: "folder")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                                 spacing: Theme.gridGap)],
                              spacing: Theme.gridGap) {
                        ForEach(items, id: \.hash) { item in
                            PhotoCellView(item: item, library: state.library!)
                                .aspectRatio(1, contentMode: .fill)
                                .onTapGesture { state.openedItem = item }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task(id: state.selectedFolder) { reload() }
        .task(id: state.sections.count) { reload() }   // refresh after rescans
    }

    private func reload() {
        guard let lib = state.library, let dir = state.selectedFolder else { items = []; return }
        items = (try? lib.items(inDir: dir)) ?? []
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(state.selectedFolder?.replacingOccurrences(of: "/", with: " › ") ?? "Folders")
                .font(.system(size: 15, weight: .semibold))
            Text("\(items.count) items")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            if let dir = state.selectedFolder,
               let root = state.library?.vaults.first?.rootURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [root.appendingPathComponent(dir)])
                } label: { Label("Reveal in Finder", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }
}
```

Note: "Reveal in Finder" resolves against the **first** vault root for simplicity; folders from the second vault reveal incorrectly. Fix by storing `vaultID` alongside `selectedFolder` when wiring multi-vault trees — acceptable for Phase 1 single-`~/Pictures` testing, tracked in the Deferred list.

- [ ] **Step 2: Verify** — run; tree shows nested folders with counts; selecting fills the grid; breadcrumb shows `a › b`; Reveal opens Finder.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Folders
git commit -m "feat(app): folder tree with counts + folder grid with breadcrumb"
```

### Task 20: ViewerView (full-bleed stage, filmstrip, keyboard)

**Files:**
- Modify: `Sources/OpenPhotoApp/Viewer/ViewerView.swift` (replace placeholder)

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import AVKit
import OpenPhotoCore

struct ViewerView: View {
    @Bindable var state: AppState
    @State private var fullImage: NSImage?
    @State private var playingLive = false

    private var flatItems: [TimelineItem] { state.sections.flatMap(\.items) }
    private var index: Int? { flatItems.firstIndex { $0.hash == state.openedItem?.hash } }

    var body: some View {
        HStack(spacing: 0) {
            stage
            if state.inspectorShown, let item = state.openedItem {
                Divider().overlay(Theme.hairline)
                InspectorView(state: state, item: item)
                    .frame(width: Theme.inspectorWidth)
            }
        }
        .background(Color.black.opacity(0.96))
        .onKeyPress(.escape) { state.openedItem = nil; return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(KeyEquivalent("i")) { state.inspectorShown.toggle(); return .handled }
        .task(id: state.openedItem?.hash) { await loadFull() }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { state.openedItem = nil } label: {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.plain)
                if let item = state.openedItem {
                    Text(title(for: item)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                if state.openedItem?.livePairHash != nil {
                    Button { playingLive.toggle() } label: {
                        Label("Live", systemImage: "livephoto")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Button { state.inspectorShown.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).frame(height: 44)

            GeometryReader { _ in
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            filmstrip
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        if let item = state.openedItem {
            if item.kind == MediaKind.video.rawValue {
                if let url = state.library?.absoluteURL(for: item) {
                    VideoPlayer(player: AVPlayer(url: url))
                }
            } else if playingLive, let pair = item.livePairHash,
                      let pairURL = livePairURL(photo: item, pairHash: pair) {
                VideoPlayer(player: {
                    let p = AVPlayer(url: pairURL); p.play(); return p
                }())
            } else if let fullImage {
                Image(nsImage: fullImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .shadow(radius: 22)
                    .padding(20)
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(flatItems, id: \.hash) { item in
                        ThumbView(item: item, library: state.library!)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.hash == state.openedItem?.hash
                                              ? Theme.accent : .clear, lineWidth: 2))
                            .id(item.hash)
                            .onTapGesture { state.openedItem = item }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .onChange(of: state.openedItem?.hash) { _, hash in
                if let hash { withAnimation { proxy.scrollTo(hash, anchor: .center) } }
            }
        }
        .frame(height: 70)
        .background(.black.opacity(0.5))
    }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let j = i + delta
        guard flatItems.indices.contains(j) else { return }
        playingLive = false
        state.openedItem = flatItems[j]
    }

    private func loadFull() async {
        fullImage = nil
        guard let item = state.openedItem, item.kind == MediaKind.photo.rawValue,
              let url = state.library?.absoluteURL(for: item) else { return }
        fullImage = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }

    private func livePairURL(photo: TimelineItem, pairHash: String) -> URL? {
        guard let lib = state.library,
              let rec = try? lib.catalog.instanceItem(hash: pairHash, vaultID: photo.vaultID),
              let vault = lib.vault(id: photo.vaultID) else { return nil }
        return vault.absoluteURL(forRelativePath: rec.relPath)
    }

    private func title(for item: TimelineItem) -> String {
        let d = Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
```

Make `Catalog.instanceItem(hash:vaultID:)` (defined internal in Task 14) **public** so the app target can call it.

Also create `Sources/OpenPhotoApp/Inspector/InspectorView.swift` as a compile-only placeholder (the real one is Task 21):

```swift
import SwiftUI
import OpenPhotoCore

struct InspectorView: View {
    @Bindable var state: AppState
    let item: TimelineItem
    var body: some View { Text("Inspector — Task 21").frame(maxHeight: .infinity) }
}
```

- [ ] **Step 2: Verify** — open a photo: full-res fades in, ←/→ navigate, Esc closes, `i` toggles inspector, filmstrip follows, video plays, Live button plays the paired clip.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Viewer Sources/OpenPhotoCore/LibraryService.swift
git commit -m "feat(app): full-bleed viewer with filmstrip, keyboard nav, video & live playback"
```

### Task 21: InspectorView (metadata + sidecar edits + mini-map + presence + path)

**Files:**
- Modify: `Sources/OpenPhotoApp/Inspector/InspectorView.swift` (replace the Task 20 placeholder)

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MapKit
import OpenPhotoCore

struct InspectorView: View {
    @Bindable var state: AppState
    let item: TimelineItem

    @State private var caption = ""
    @State private var rating = 0
    @State private var favorite = false
    @State private var tags: [String] = []
    @State private var newTag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
                    .formatted(date: .complete, time: .shortened))
                    .font(.system(size: 13, weight: .semibold))

                section("Caption") {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(8).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { save() }
                }

                section("Rating") {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { i in
                            Button {
                                rating = (rating == i) ? 0 : i
                                save()
                            } label: {
                                Image(systemName: i <= rating ? "star.fill" : "star")
                                    .foregroundStyle(i <= rating ? Theme.amber : Theme.textFaint)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Button {
                            favorite.toggle(); save()
                        } label: {
                            Image(systemName: favorite ? "heart.fill" : "heart")
                                .foregroundStyle(favorite ? Theme.accent : Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                }

                section("Tags") {
                    FlowLayoutLite(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag).font(.system(size: 12))
                                Button {
                                    tags.removeAll { $0 == tag }; save()
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accentDim, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(Theme.accent)
                        }
                        TextField("Add tag", text: $newTag)
                            .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 70)
                            .onSubmit {
                                let t = newTag.trimmingCharacters(in: .whitespaces)
                                if !t.isEmpty, !tags.contains(t) { tags.append(t); save() }
                                newTag = ""
                            }
                    }
                }

                Divider().overlay(Theme.hairline)

                section(item.cameraModel ?? "Camera") {
                    exifGrid
                }

                if let lat = item.latitude, let lon = item.longitude {
                    section("Location") {
                        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))) {
                            Marker("", coordinate: coord).tint(Theme.accent)
                        }
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                        Text(String(format: "%.4f, %.4f", lat, lon))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    }
                }

                Divider().overlay(Theme.hairline)

                section("Presence") {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer")
                        Text("This Mac").font(.system(size: 12.5))
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                    }
                    // Drive rows arrive in Phase 3 with the presence map UI.
                }

                section("File") {
                    Text(item.relPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: item.size,
                                                       countStyle: .file))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Reveal in Finder") {
                            if let url = state.library?.absoluteURL(for: item) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }.controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg2)
        .task(id: item.hash) { load() }
    }

    private var exifGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            if let w = item.pixelWidth, let h = item.pixelHeight {
                GridRow { gLabel("Dimensions"); gValue("\(w) × \(h)") }
            }
            if let lens = item.lensModel { GridRow { gLabel("Lens"); gValue(lens) } }
            if let d = item.durationSeconds {
                GridRow { gLabel("Duration"); gValue(String(format: "%.1fs", d)) }
            }
            GridRow { gLabel("Kind"); gValue(item.livePairHash != nil ? "Live Photo" : item.kind) }
        }
    }

    private func gLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Theme.textFaint)
    }
    private func gValue(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold).monospacedDigit())
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.4)
                .foregroundStyle(Theme.textFaint)
            content()
        }
    }

    private func load() {
        caption = item.caption ?? ""
        rating = item.rating
        favorite = item.favorite
        tags = (try? JSONDecoder().decode([String].self,
                                          from: Data(item.tagsJSON.utf8))) ?? []
    }

    private func save() {
        guard let lib = state.library else { return }
        try? lib.updateMetadata(for: item,
                                rating: rating, favorite: favorite,
                                caption: caption.isEmpty ? nil : caption, tags: tags)
        try? state.refreshQueries()
        if let updated = try? lib.item(hash: item.hash) { state.openedItem = updated }
    }
}

/// Minimal wrapping layout for tag chips.
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
```

- [ ] **Step 2: Verify** — open a photo: set rating/favorite/tags/caption → check the sidecar file appeared at `<folder>/.openphoto/<name>.xmp` (e.g. `cat` it: standard XMP). Restart the app → edits persist (read back from catalog; delete `catalog.sqlite` and rescan → edits restored *from sidecars*, proving rebuildability).

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Inspector
git commit -m "feat(app): inspector — metadata, sidecar-backed edits, mini-map, file info"
```

### Task 22: BinView + delete actions

**Files:**
- Modify: `Sources/OpenPhotoApp/Bin/BinView.swift` (replace placeholder)
- Modify: `Sources/OpenPhotoApp/Timeline/PhotoCellView.swift` (context menu)
- Modify: `Sources/OpenPhotoApp/Viewer/ViewerView.swift` (⌫ deletes)

- [ ] **Step 1: `BinView.swift`**

```swift
import SwiftUI
import OpenPhotoCore

struct BinView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bin").font(.system(size: 15, weight: .semibold))
                Text("\(state.binEntries.count) items")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Empty Bin…", role: .destructive) { confirmEmpty() }
                    .disabled(state.binEntries.isEmpty)
            }
            .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if state.binEntries.isEmpty {
                ContentUnavailableView {
                    Label("Bin is empty", systemImage: "trash")
                } description: {
                    Text("Deleted photos rest here until you empty the bin.\nNothing leaves your drives until then.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(state.binEntries) { entry in
                            VStack(spacing: 6) {
                                BinThumb(entry: entry, library: state.library!)
                                    .frame(height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text((entry.item.path as NSString).lastPathComponent)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint).lineLimit(1)
                                Button("Restore") {
                                    Task {
                                        try? await state.library?.restore(entry)
                                        try? state.refreshQueries()
                                    }
                                }.controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func confirmEmpty() {
        let alert = NSAlert()
        alert.messageText = "Empty the bin?"
        alert.informativeText = "\(state.binEntries.count) items will move to the macOS Trash — still recoverable from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Recycle each vault's whole bin/ dir (files + their sidecars) to macOS
        // Trash — never unlink — then reset the bin log.
        for vault in state.library?.vaults ?? [] {
            if FileManager.default.fileExists(atPath: vault.binDirURL.path) {
                try? NSWorkspace.shared.recycle([vault.binDirURL])
            }
            try? AtomicFile.write(Data(), to: vault.binLogURL)
        }
        try? state.refreshQueries()
    }
}

private struct BinThumb: View {
    let entry: LibraryService.BinEntry
    let library: LibraryService
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Theme.tile
            if let image {
                Image(decorative: image, scale: 1).resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task {
            let e = entry, lib = library
            image = await Task.detached {
                try? lib.thumbnails.thumbnail(
                    for: ContentHash(stringValue: e.item.hash), sourceURL: e.fileURL,
                    kind: MediaKind.of(filename: e.fileURL.lastPathComponent) ?? .photo)
            }.value
        }
    }
}
```

Make `Vault.binLogURL` and `AtomicFile` accessible (both already `public`).

- [ ] **Step 2: Wire deletion** — add an `onDelete: () -> Void` parameter to `PhotoCellView`:

```swift
struct PhotoCellView: View {
    let item: TimelineItem
    let library: LibraryService
    var onDelete: () -> Void = {}
    // … existing body, plus:
    // .contextMenu {
    //     Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
    // }
}
```

and pass it at both call sites (`TimelineView`, `FolderGridView`):

```swift
PhotoCellView(item: item, library: state.library!) {
    Task {
        try? await state.library?.delete(item)
        try? state.refreshQueries()
    }
}
```

And in `ViewerView`, add after the other key handlers:

```swift
.onKeyPress(.deleteForward) { deleteCurrent(); return .handled }
.onKeyPress(.delete) { deleteCurrent(); return .handled }
```

with:

```swift
private func deleteCurrent() {
    guard let item = state.openedItem else { return }
    step(1)
    if state.openedItem?.hash == item.hash { state.openedItem = nil }  // was last item
    Task {
        try? await state.library?.delete(item)
        try? state.refreshQueries()
    }
}
```

- [ ] **Step 3: Verify** — delete from grid context-menu and viewer ⌫: item leaves timeline, appears in Bin with thumbnail; Restore brings it back (file returns to its folder); Empty Bin moves files to macOS Trash and clears the bin. Check `bin.jsonl` contents along the way.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp
git commit -m "feat(app): bin view, delete/restore/empty-to-Trash, grid+viewer delete actions"
```

### Task 23: make-app.sh (the .app bundle)

**Files:**
- Create: `scripts/make-app.sh`

- [ ] **Step 1: Implement**

```bash
#!/bin/bash
# Assemble OpenPhoto.app from the SwiftPM release build (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/OpenPhoto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenPhotoApp "$APP/Contents/MacOS/OpenPhoto"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>OpenPhoto</string>
    <key>CFBundleIdentifier</key><string>dev.jude.openphoto</string>
    <key>CFBundleName</key><string>OpenPhoto</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
```

- [ ] **Step 2: Verify**

Run: `chmod +x scripts/make-app.sh && ./scripts/make-app.sh && open build/OpenPhoto.app`
Expected: the app launches as a normal macOS app with its own Dock entry.

- [ ] **Step 3: Add `build/` to `.gitignore`**, then commit:

```bash
git add scripts/make-app.sh .gitignore
git commit -m "build: make-app.sh assembles OpenPhoto.app from SwiftPM release build"
```

---

# Part C — Spike & validation

### Task 24: ImageCaptureCore deletion spike (de-risks Phase 2)

Requires a physical iPhone over USB-C. The executable enumerates camera devices and items; `--delete-test` downloads one expendable photo, verifies, then attempts deletion and reports the outcome. Run it twice: with iCloud Photos ON and OFF, and record both results.

**Files:**
- Modify: `Sources/ICCSpike/main.swift`
- Create: `docs/spikes/2026-06-07-icc-deletion.md`
- Modify: `Package.swift` (link ImageCaptureCore)

- [ ] **Step 1: In `Package.swift`**, give the spike target the framework:

```swift
.executableTarget(
    name: "ICCSpike",
    linkerSettings: [.linkedFramework("ImageCaptureCore")]
),
```

- [ ] **Step 2: Implement `main.swift`**

```swift
import Foundation
import ImageCaptureCore

final class SpikeDelegate: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let deleteTest = CommandLine.arguments.contains("--delete-test")

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice,
                       moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        print("Found: \(device.name ?? "?") — opening session…")
        camera.delegate = self
        camera.requestOpenSession()
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error { print("Open session FAILED: \(error)"); exit(1) }
        print("Session open. Waiting for contents…")
    }

    func cameraDeviceDidEnumerateItems(_ camera: ICCameraDevice) {
        let files = camera.mediaFiles ?? []
        print("Items visible: \(files.count)")
        for f in files.prefix(10) {
            print("  \(f.name ?? "?")  \(f.fileSize) bytes  locked=\(f.isLocked)")
        }
        guard deleteTest, let victim = files.first else {
            print(deleteTest ? "No items to test with." : "Pass --delete-test to attempt deletion.")
            exit(0)
        }
        print("Attempting deletion of \(victim.name ?? "?") …")
        camera.requestDeleteFiles([victim])
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            print("No deletion callback within 10s — treat as NOT SUPPORTED.")
            exit(2)
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didDeleteFiles files: [ICCameraItem],
                      error: (any Error)?) {
        if let error {
            print("Deletion FAILED: \(error)")
        } else {
            print("Deletion SUCCEEDED for \(files.compactMap(\.name))")
        }
        exit(error == nil ? 0 : 3)
    }

    // Required protocol stubs:
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {}
    func device(_ d: ICDevice, didCloseSessionWithError e: (any Error)?) {}
    func didRemove(_ d: ICDevice) {}
    func cameraDevice(_ c: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ c: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ c: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ c: ICCameraDevice, didCompleteDeleteFilesWithError e: (any Error)?) {}
    func cameraDeviceDidChangeCapability(_ c: ICCameraDevice) {}
    func cameraDevice(_ c: ICCameraDevice, didReceiveThumbnail t: CGImage?,
                      for i: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ c: ICCameraDevice, didReceiveMetadata m: [AnyHashable: Any]?,
                      for i: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ c: ICCameraDevice, didReceivePTPEvent d: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog c: ICCameraDevice) {}
}

let delegate = SpikeDelegate()
let browser = ICDeviceBrowser()
browser.delegate = delegate
browser.browsedDeviceTypeMask = ICDeviceTypeMask(
    rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
browser.start()
print("Browsing for USB camera devices… plug in the iPhone and unlock it. Ctrl-C to quit.")
RunLoop.main.run()
```

(If the delegate protocol has shifted on macOS 15 — these APIs move — fix signatures per compiler errors; the *findings* are the deliverable, not this code.)

- [ ] **Step 3: Run with iPhone plugged in & unlocked**

Run: `swift run ICCSpike` (enumeration only), then `swift run ICCSpike --delete-test` with an expendable photo as the first item.
Expected: macOS prompts for camera access (grant it). Record exactly what happens in each iCloud Photos mode.

- [ ] **Step 4: Write findings** to `docs/spikes/2026-06-07-icc-deletion.md`:

```markdown
# Spike: iPhone deletion via ImageCaptureCore — findings

**Date run:** <fill>
**Device:** <iPhone model, iOS version>
**Host:** macOS 15.2, OpenPhoto ICCSpike

| Scenario | Enumeration | Download | Deletion |
|---|---|---|---|
| iCloud Photos OFF | <works?> | <works?> | <result + error if any> |
| iCloud Photos ON  | <works?> | <works?> | <result + error if any> |

## Conclusion for Phase 2
<one of:>
- Deletion works in our configuration → import flow may offer "Delete from iPhone".
- Deletion blocked → import flow ends with "Now delete imported items on the phone"
  guidance instead. (Spec §11 fallback.)

## Raw output
<paste spike output for both runs>
```

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ICCSpike docs/spikes/2026-06-07-icc-deletion.md
git commit -m "spike: ImageCaptureCore enumeration + deletion test with findings"
```

### Task 25: Real-library validation + README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Validate against a COPY of the real library** (never point Phase-1 code at the originals first — even though all writes are additive, the format doc's invariants deserve paranoia):

```bash
mkdir -p ~/openphoto-test && cp -R ~/Pictures/<one-real-folder> ~/openphoto-test/
swift run OpenPhotoApp   # Welcome → choose ~/openphoto-test
```

Checklist — record actual numbers in the commit message:
- [ ] Initial scan completes; note items/sec for hashing
- [ ] Timeline groups correctly; HEIC + video thumbnails render
- [ ] Live Photos appear as one item with the LIVE badge; Live playback works
- [ ] Rename a file in Finder mid-session → watcher rescan keeps identity (check Inspector path updates, edits survive)
- [ ] Edit rating/tags → `.xmp` appears in folder-level `.openphoto/`; delete `catalog.sqlite`, relaunch, confirm edits return from sidecars
- [ ] Delete → Bin → Restore → Empty Bin → file is in macOS Trash
- [ ] Second launch is fast-path (no rehash — watch the activity indicator)

- [ ] **Step 2: Write `README.md`** (succinct: what OpenPhoto is, the sovereignty promise, Phase 1 status, how to build — `swift test`, `swift run OpenPhotoApp`, `scripts/make-app.sh` — and pointers to `docs/` for the spec/format/plan).

- [ ] **Step 3: Full suite + commit**

```bash
swift test
git add README.md
git commit -m "docs: README; phase 1 validated against real library copy (<numbers>)"
```

---

## Deferred within Phase 1 (intentional, do not silently add)

- Year scrubber on the timeline (needs scroll-position plumbing; revisit with Phase 4 search UI)
- Filter chips (People/Places/Favorites/Media) — Favorites-only chip could come early, rest need Phase 4 data
- Multi-vault "Reveal in Finder" disambiguation in FoldersView (single-root testing is fine for now)
- Drift banner UI (drives don't exist until Phase 3)
- Light-appearance fine-tuning beyond the token table

## Done means

All tasks committed, `swift test` green, the app browses a real folder copy with timeline/folders/viewer/inspector/bin working, sidecar edits survive a catalog rebuild, and the ICC spike findings doc states a clear Phase-2 import-flow decision.

