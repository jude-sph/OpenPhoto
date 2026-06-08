# OpenPhoto Phase 2 (Device Import) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import photos/videos from iPhones (ImageCaptureCore) and mounted volumes (SD cards) into the library with verified-copy-before-delete safety, a durable import registry, and the opt-in free-up-the-phone flow.

**Architecture:** Source-agnostic `ImportEngine` in OpenPhotoCore behind an `ImportSource` protocol (`CameraSource` = ICC, hardware-validated; `VolumeSource` = filesystem, fixture-tested; `FakeSource` = test double). Pipeline per batch: stage into `.openphoto/staging/` → hash → registry/catalog dedup → place with collision-safe names → one incremental rescan → verify staged-hash == manifest-hash → registry append. UI: import session screen (sequential batches) + free-up-phone selection screen.

**Tech Stack:** Swift 6 / SwiftPM (existing package), Swift Testing, ImageCaptureCore, existing Core primitives (Vault, AtomicFile, ContentHash, MediaKind, ISO8601Millis, LibraryService, Scanner).

**Authoritative docs:** `docs/superpowers/specs/2026-06-08-phase2-import-design.md` (spec), `docs/format/vault-format-v1.md` (format — §12 added by Task 2), `docs/spikes/2026-06-08-icc-deletion.md` (hardware behavior), `UI-Design/design_handoff_openphoto/import.jsx` + README §3 (visual reference), `Sources/ICCSpike/main.swift` (proven ICC skeleton).

---

## Conventions (same as Phase 1)

- **HARD RULE — no real user data, ever.** Tests touch only the repo and `FileManager.default.temporaryDirectory`. All media fixtures generated (`makeJPEG`/`makeMOV` helpers exist in the test target). Hardware steps (CameraSource) are MANUAL checklist items run by Jude — never automated against his phone.
- TDD for everything in OpenPhotoCore. `swift test` green + `swift build` 0 warnings after every task. Exact commit message per task.
- Format-doc discipline: Task 2 changes the on-disk format → updates `docs/format/vault-format-v1.md` in the same commit.
- App-target pitfall from Phase 1: `Scanner` collides with Foundation — `typealias Scanner = OpenPhotoCore.Scanner` already exists in `AppState.swift`.

## Existing API you build on (verified, Phase 1)

- `Vault`: `rootURL`, `descriptor.vaultID`, `stateDirURL`, `absoluteURL(forRelativePath:)`, `relativePath(of:)`, `manifestURL`, `sidecarURL(forMediaAt:)`; `Vault.stateDirName == ".openphoto"`
- `Manifest.read(from:) -> [ManifestEntry]` (`entry.hash.stringValue`, `entry.path`)
- `ContentHash.ofFile(at:)`, `AtomicFile.write(_:to:)`, `ISO8601Millis.string/date`, `MediaKind.of(filename:)`
- `LibraryService`: `vaults`, `catalog`, `thumbnails`, `timelineSections(grouping:)`, `binItems()`, plus **private** `rescan(vaultID:)` (Task 5 makes it public) and `Catalog.knownHashes() -> Set<String>`
- `LivePhotoPairer.pair(candidates:)` (basename+time fallback logic — reused conceptually in Task 1's device-item pairing)
- App: `AppState` (@Observable @MainActor), `Theme`, `SidebarView`, mockup tokens in `UI-Design/design_handoff_openphoto/README.md`

## File structure (end state)

```
Sources/OpenPhotoCore/Import/
  ImportSource.swift      protocol + ImportItem + SourceState + DeleteResult + pairLiveItems()
  ImportRegistry.swift    imports.jsonl — load/lookup/append (format §12)
  VolumeSource.swift      SD-card/folder source incl. .openphoto-trash deletion
  ImportEngine.swift      batch pipeline + BatchResult
  CameraSource.swift      ImageCaptureCore source (thin, hardware-validated)
Sources/OpenPhotoApp/Devices/
  DeviceWatcher.swift     ICDeviceBrowser + volume mounts → observable device list
  ImportView.swift        session screen: grid, select/import/done footer states
  ImportItemCell.swift    device-item tile (badges: imported, LIVE, video)
  FreeUpPhoneView.swift   deletion selection screen + confirmation
Tests/OpenPhotoCoreTests/
  FakeSource.swift        controllable in-memory ImportSource
  ImportSourceTests.swift ImportRegistryTests.swift  VolumeSourceTests.swift  ImportEngineTests.swift
docs/format/vault-format-v1.md   §12 import registry, staging, sd-trash, §9 examples
```

---

# Part A — Core

### Task 1: ImportSource protocol, ImportItem, live pairing, FakeSource

**Files:**
- Create: `Sources/OpenPhotoCore/Import/ImportSource.swift`
- Create: `Tests/OpenPhotoCoreTests/FakeSource.swift`
- Create: `Tests/OpenPhotoCoreTests/ImportSourceTests.swift`

- [ ] **Step 1: failing tests** (`ImportSourceTests.swift`):

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func item(_ id: String, name: String, kind: MediaKind,
                  taken: TimeInterval) -> ImportItem {
    ImportItem(id: id, name: name, byteSize: 100, takenAt: Date(timeIntervalSince1970: taken),
               kind: kind, livePartnerID: nil)
}

@Test func pairsLiveItemsByBasenameAndTime() {
    let paired = pairLiveItems([
        item("1", name: "IMG_1.HEIC", kind: .photo, taken: 100),
        item("2", name: "IMG_1.MOV", kind: .video, taken: 101),
        item("3", name: "IMG_2.HEIC", kind: .photo, taken: 200),
        item("4", name: "CLIP.MOV", kind: .video, taken: 300),
    ])
    let p1 = paired.first { $0.id == "1" }!
    let v1 = paired.first { $0.id == "2" }!
    #expect(p1.livePartnerID == "2")
    #expect(v1.livePartnerID == "1")
    #expect(paired.first { $0.id == "3" }!.livePartnerID == nil)
    #expect(paired.first { $0.id == "4" }!.livePartnerID == nil)
}

@Test func fakeSourceRoundTrips() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let fake = FakeSource(sourceKey: "fake-1", items: [
        (item("a", name: "A.JPG", kind: .photo, taken: 10), Data("aaa".utf8)),
    ])
    let listed = try await fake.enumerateItems()
    #expect(listed.count == 1 && listed[0].name == "A.JPG")
    let dest = t.root.appendingPathComponent("a.jpg")
    try await fake.fetch(listed[0], to: dest)
    #expect(try Data(contentsOf: dest) == Data("aaa".utf8))
    let results = try await fake.delete([listed[0]])
    #expect(results == [DeleteResult(itemID: "a", error: nil)])
    #expect(fake.deletedIDs == ["a"])
}
```

- [ ] **Step 2:** `swift test --filter ImportSourceTests` → FAIL (types undefined).

- [ ] **Step 3: implement `ImportSource.swift`:**

```swift
import Foundation
import CoreGraphics

/// One item visible on an import source (device photo, SD-card file).
public struct ImportItem: Identifiable, Sendable, Equatable {
    public let id: String          // source-stable id (ICC object handle / volume relpath)
    public var name: String
    public var byteSize: Int64
    public var takenAt: Date?
    public var kind: MediaKind
    /// Set by pairLiveItems(): the other half of a Live Photo, if detected.
    public var livePartnerID: String?

    public init(id: String, name: String, byteSize: Int64, takenAt: Date?,
                kind: MediaKind, livePartnerID: String?) {
        self.id = id; self.name = name; self.byteSize = byteSize
        self.takenAt = takenAt; self.kind = kind; self.livePartnerID = livePartnerID
    }
}

public enum SourceState: Sendable, Equatable {
    case connected          // found, session not open yet
    case waitingForUnlock   // ICC error -9943 — UI shows "Unlock your iPhone"
    case ready              // enumerable
    case gone               // unplugged / unmounted
}

public struct DeleteResult: Sendable, Equatable {
    public let itemID: String
    public let error: String?      // nil = deleted
    public init(itemID: String, error: String?) {
        self.itemID = itemID; self.error = error
    }
}

/// A place photos can be imported from — spec §3. Implementations:
/// CameraSource (ICC), VolumeSource (SD/folder), FakeSource (tests).
public protocol ImportSource: Sendable {
    var sourceKey: String { get }              // stable per device — registry key part
    var displayName: String { get }
    func enumerateItems() async throws -> [ImportItem]   // sorted newest-first
    func fetch(_ item: ImportItem, to url: URL) async throws
    func delete(_ items: [ImportItem]) async throws -> [DeleteResult]
    func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage?
}

/// Pair Live Photo halves among device items: same lowercased basename,
/// photo+video, capture times within 2s (mirrors LivePhotoPairer's fallback).
public func pairLiveItems(_ items: [ImportItem]) -> [ImportItem] {
    func base(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }
    var videosByBase: [String: ImportItem] = [:]
    for i in items where i.kind == .video { videosByBase[base(i.name)] = i }
    var out = items
    for (idx, i) in out.enumerated() where i.kind == .photo {
        guard let v = videosByBase[base(i.name)],
              let pt = i.takenAt, let vt = v.takenAt,
              abs(pt.timeIntervalSince(vt)) <= 2 else { continue }
        out[idx].livePartnerID = v.id
        if let vIdx = out.firstIndex(where: { $0.id == v.id }) {
            out[vIdx].livePartnerID = i.id
        }
    }
    return out
}
```

- [ ] **Step 4: implement `Tests/OpenPhotoCoreTests/FakeSource.swift`:**

```swift
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

/// Controllable in-memory ImportSource for engine tests.
final class FakeSource: ImportSource, @unchecked Sendable {
    let sourceKey: String
    let displayName = "Fake Device"
    private let payloads: [String: Data]
    private let listed: [ImportItem]
    /// Set these to inject failures:
    var failFetchIDs: Set<String> = []
    var failDeleteIDs: Set<String> = []
    private(set) var deletedIDs: [String] = []

    init(sourceKey: String, items: [(ImportItem, Data)]) {
        self.sourceKey = sourceKey
        self.listed = items.map(\.0)
        self.payloads = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
    }

    func enumerateItems() async throws -> [ImportItem] { listed }

    func fetch(_ item: ImportItem, to url: URL) async throws {
        if failFetchIDs.contains(item.id) {
            throw CocoaError(.fileReadUnknown)
        }
        try payloads[item.id]!.write(to: url)
    }

    func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { i in
            if failDeleteIDs.contains(i.id) {
                return DeleteResult(itemID: i.id, error: "injected failure")
            }
            deletedIDs.append(i.id)
            return DeleteResult(itemID: i.id, error: nil)
        }
    }

    func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? { nil }
}
```

- [ ] **Step 5:** `swift test --filter ImportSourceTests` → 2 PASS; full suite 56 green; 0 warnings.
- [ ] **Step 6: Commit:** `git add Sources/OpenPhotoCore/Import Tests/OpenPhotoCoreTests/FakeSource.swift Tests/OpenPhotoCoreTests/ImportSourceTests.swift && git commit -m "feat: ImportSource protocol, live pairing, fake source for tests"`

### Task 2: ImportRegistry + format doc §12

**Files:**
- Create: `Sources/OpenPhotoCore/Import/ImportRegistry.swift`
- Create: `Tests/OpenPhotoCoreTests/ImportRegistryTests.swift`
- Modify: `docs/format/vault-format-v1.md` (same commit — format rule)

- [ ] **Step 1: failing tests:**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func entry(_ name: String, taken: String) -> ImportRegistry.Entry {
    ImportRegistry.Entry(sourceKey: "iphone-1", name: name, size: 123,
                         takenAt: taken, hash: "sha256:" + String(repeating: "a", count: 64),
                         importedAt: "2026-06-08T02:00:00.000Z",
                         importedTo: "rome2026/\(name)")
}

@Test func appendsAndLooksUp() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let reg = ImportRegistry(vault: vault)
    let e = entry("IMG_1.HEIC", taken: "2026-06-01T10:00:00.000Z")
    try reg.append(e)
    #expect(reg.contains(sourceKey: "iphone-1", name: "IMG_1.HEIC", size: 123,
                         takenAt: "2026-06-01T10:00:00.000Z"))
    #expect(!reg.contains(sourceKey: "iphone-1", name: "IMG_2.HEIC", size: 123,
                          takenAt: "2026-06-01T10:00:00.000Z"))
    // Reload from disk — durable.
    let reg2 = ImportRegistry(vault: vault)
    try reg2.load()
    #expect(reg2.contains(sourceKey: "iphone-1", name: "IMG_1.HEIC", size: 123,
                          takenAt: "2026-06-01T10:00:00.000Z"))
    #expect(reg2.entries(forSourceKey: "iphone-1").count == 1)
}

@Test func appendIsIdempotentPerKey() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = ImportRegistry(vault: vault)
    try reg.append(entry("IMG_1.HEIC", taken: "2026-06-01T10:00:00.000Z"))
    try reg.append(entry("IMG_1.HEIC", taken: "2026-06-01T10:00:00.000Z"))   // dup key
    let reg2 = ImportRegistry(vault: vault); try reg2.load()
    #expect(reg2.entries(forSourceKey: "iphone-1").count == 1)
}
```

- [ ] **Step 2:** filter-run → FAIL.

- [ ] **Step 3: implement `ImportRegistry.swift`:**

```swift
import Foundation

/// Durable memory of every item ever imported from each device —
/// imports.jsonl in the vault's .openphoto/ (vault-format-v1 §12).
public final class ImportRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let sourceKey: String
        public let name: String
        public let size: Int64
        public let takenAt: String      // ISO-8601 millis; "" when source had none
        public let hash: String
        public let importedAt: String
        public let importedTo: String
        enum CodingKeys: String, CodingKey {
            case sourceKey = "source_key", name, size
            case takenAt = "taken_at", hash
            case importedAt = "imported_at", importedTo = "imported_to"
        }
        public init(sourceKey: String, name: String, size: Int64, takenAt: String,
                    hash: String, importedAt: String, importedTo: String) {
            self.sourceKey = sourceKey; self.name = name; self.size = size
            self.takenAt = takenAt; self.hash = hash
            self.importedAt = importedAt; self.importedTo = importedTo
        }
        var key: String { "\(sourceKey)|\(name)|\(size)|\(takenAt)" }
    }

    private let url: URL
    private var byKey: [String: Entry] = [:]
    private let lock = NSLock()

    public init(vault: Vault) {
        url = vault.stateDirURL.appendingPathComponent("imports.jsonl")
        try? load()
    }

    /// (Re)load from disk. Missing file = empty registry.
    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        byKey.removeAll()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain
            && e.code == NSFileReadNoSuchFileError { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let e = try dec.decode(Entry.self, from: line)
            byKey[e.key] = e
        }
    }

    public func contains(sourceKey: String, name: String, size: Int64, takenAt: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byKey["\(sourceKey)|\(name)|\(size)|\(takenAt)"] != nil
    }

    public func entries(forSourceKey key: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.sourceKey == key }
    }

    /// Append (idempotent by key) and rewrite atomically.
    public func append(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        guard byKey[entry.key] == nil else { return }
        byKey[entry.key] = entry
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in byKey.values.sorted(by: { $0.importedAt < $1.importedAt }) {
            out.append(try enc.encode(e)); out.append(0x0A)
        }
        try AtomicFile.write(out, to: url)
    }
}
```

- [ ] **Step 4:** filter-run → 2 PASS; full suite green; 0 warnings.

- [ ] **Step 5: format doc** — in `docs/format/vault-format-v1.md`:
  (a) §1 layout block: add `imports.jsonl` and `staging/` lines under the vault-root `.openphoto/`:
```
    imports.jsonl                  ← device-import registry (§12)
    staging/                       ← transient import workspace — readers MUST ignore
```
  (b) New section after §11:

```markdown
## 12. Import registry (`imports.jsonl`)

Durable record of every item OpenPhoto has imported from an external device
(phone, SD card). One JSON object per line:

​```json
{"hash":"sha256:…","imported_at":"2026-06-08T02:10:00.000Z","imported_to":"rome2026/IMG_6385.HEIC","name":"IMG_6385.HEIC","size":2888127,"source_key":"jude-iphone-ABC123","taken_at":"2026-06-08T01:15:58.000Z"}
​```

- `source_key` — stable device identity (device name + serial, or volume UUID).
- Lookup key is `(source_key, name, size, taken_at)`; `hash` records what the
  bytes were. Entries are never removed: "imported once" is permanent memory,
  surviving renames, evictions, and deletion from the library.
- Lives in the **primary** vault's `.openphoto/` (the first configured root).
- `.openphoto/staging/` is a transient import workspace; readers MUST ignore
  it. OpenPhoto clears it at session start.
- On removable volumes OpenPhoto deletes by moving files into
  `.openphoto-trash/` at the volume root — never unlinking (§8 spirit).
```
  (c) §9: extend the example event list with `"import"` and `"device-delete"` event names.

- [ ] **Step 6: Commit:** `git add Sources/OpenPhotoCore/Import/ImportRegistry.swift Tests/OpenPhotoCoreTests/ImportRegistryTests.swift docs/format/vault-format-v1.md && git commit -m "feat: durable import registry (imports.jsonl) per format v1 §12"`

### Task 3: VolumeSource

**Files:**
- Create: `Sources/OpenPhotoCore/Import/VolumeSource.swift`
- Create: `Tests/OpenPhotoCoreTests/VolumeSourceTests.swift`

- [ ] **Step 1: failing tests:**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func enumeratesMediaNewestFirstAndFetches() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    try makeJPEG(at: card.appendingPathComponent("DCIM/100APPLE/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2026:01:01 10:00:00", lat: nil, lon: nil)
    try makeJPEG(at: card.appendingPathComponent("DCIM/100APPLE/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2026:03:01 10:00:00", lat: nil, lon: nil)
    try t.file("CARD/DCIM/notes.txt", Data("x".utf8))
    let src = VolumeSource(rootURL: card, displayName: "Test Card")
    let items = try await src.enumerateItems()
    #expect(items.count == 2)
    #expect(items[0].name == "IMG_2.jpg")          // newest first
    #expect(items[0].byteSize > 0)
    let dest = t.root.appendingPathComponent("out.jpg")
    try await src.fetch(items[0], to: dest)
    #expect(FileManager.default.fileExists(atPath: dest.path))
    #expect(await src.thumbnail(items[0], maxPixel: 64) != nil)
}

@Test func deleteMovesToVolumeTrashNeverUnlinks() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    try makeJPEG(at: card.appendingPathComponent("DCIM/IMG_9.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let src = VolumeSource(rootURL: card, displayName: "Test Card")
    let items = try await src.enumerateItems()
    let results = try await src.delete(items)
    #expect(results == [DeleteResult(itemID: items[0].id, error: nil)])
    #expect(!FileManager.default.fileExists(
        atPath: card.appendingPathComponent("DCIM/IMG_9.jpg").path))
    #expect(FileManager.default.fileExists(
        atPath: card.appendingPathComponent(".openphoto-trash/DCIM/IMG_9.jpg").path))
}

@Test func sourceKeyStableForSameRoot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    let a = VolumeSource(rootURL: card, displayName: "C")
    let b = VolumeSource(rootURL: card, displayName: "C")
    #expect(a.sourceKey == b.sourceKey && !a.sourceKey.isEmpty)
}
```

- [ ] **Step 2:** filter-run → FAIL.

- [ ] **Step 3: implement `VolumeSource.swift`:**

```swift
import Foundation
import ImageIO
import CoreGraphics

/// ImportSource for a mounted volume or plain folder (SD card DCIM, etc).
public final class VolumeSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let rootURL: URL

    public init(rootURL: URL, displayName: String) {
        self.rootURL = rootURL
        self.displayName = displayName
        // Volume UUID when available; else stable hash of the path.
        let uuid = (try? rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString
        self.sourceKey = "vol-" + (uuid ?? rootURL.path.precomposedStringWithCanonicalMapping)
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { return [] }
        var items: [ImportItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == ".openphoto-trash" { enumerator.skipDescendants() }
                continue
            }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            // Capture date: EXIF for photos (cheap header read), mtime fallback.
            var taken = values?.contentModificationDate
            if kind == .photo, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                taken = f.date(from: s) ?? taken
            }
            let rel = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            items.append(ImportItem(id: rel, name: url.lastPathComponent,
                                    byteSize: Int64(values?.fileSize ?? 0),
                                    takenAt: taken, kind: kind, livePartnerID: nil))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        try FileManager.default.copyItem(at: rootURL.appendingPathComponent(item.id), to: url)
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        let fm = FileManager.default
        return items.map { item in
            do {
                let src = rootURL.appendingPathComponent(item.id)
                let dst = rootURL.appendingPathComponent(".openphoto-trash")
                    .appendingPathComponent(item.id)
                try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst)
                return DeleteResult(itemID: item.id, error: nil)
            } catch {
                return DeleteResult(itemID: item.id, error: String(describing: error))
            }
        }
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        let url = rootURL.appendingPathComponent(item.id)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
```

- [ ] **Step 4:** filter-run → 3 PASS; full suite green; 0 warnings.
- [ ] **Step 5: Commit:** `git add Sources/OpenPhotoCore/Import/VolumeSource.swift Tests/OpenPhotoCoreTests/VolumeSourceTests.swift && git commit -m "feat: VolumeSource — SD-card/folder import source with volume trash"`

### Task 4: ImportEngine — stage, hash, dedup, place, verify, registry

**Files:**
- Create: `Sources/OpenPhotoCore/Import/ImportEngine.swift`
- Modify: `Sources/OpenPhotoCore/LibraryService.swift` (make `rescan(vaultID:)` public; add `syncLog(event:)` helper)
- Create: `Tests/OpenPhotoCoreTests/ImportEngineTests.swift`

**PLAN ADAPTATION (documented):** the spec's per-item "manifest+catalog update" is implemented as *place all batch items → one incremental `rescan` → verify each placed path's manifest hash equals its staging hash*. Verification thus cross-checks two independent hash computations (engine's staging hash vs scanner's), and reuses Phase 1's proven reconcile. Crash between place and verify self-heals: files are already valid library members; the registry backfills on the next import attempt via hash dedup.

- [ ] **Step 1: failing tests:**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func makeEnv(_ t: TestDirs) throws -> (LibraryService, Vault, ImportRegistry) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("existing/OLD.jpg").creatingParent(),
                 dateTimeOriginal: "2024:01:01 00:00:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    let vault = lib.vaults[0]
    return (lib, vault, ImportRegistry(vault: vault))
}

private func fakeItems() -> [(ImportItem, Data)] {
    [
        (ImportItem(id: "1", name: "IMG_1.JPG", byteSize: 3, takenAt: Date(timeIntervalSince1970: 100), kind: .photo, livePartnerID: nil), Data("one".utf8)),
        (ImportItem(id: "2", name: "IMG_2.JPG", byteSize: 3, takenAt: Date(timeIntervalSince1970: 200), kind: .photo, livePartnerID: nil), Data("two".utf8)),
    ]
}

@Test func importsPlacesVerifiesAndRecords() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    let result = await engine.run(source: fake, items: items, vault: vault, dirPath: "trip2026")
    #expect(result.imported.count == 2 && result.failed.isEmpty && result.skipped.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent("trip2026/IMG_1.JPG").path))
    // In catalog + manifest after the engine's rescan:
    #expect(try lib.items(inDir: "trip2026").count == 2)
    // Registry remembers:
    #expect(reg.entries(forSourceKey: "fk").count == 2)
    // Staging cleaned:
    let staging = vault.stateDirURL.appendingPathComponent("staging")
    let leftover = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    #expect(leftover.isEmpty)
}

@Test func skipsAlreadyImportedAndAlreadyInLibrary() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    _ = await engine.run(source: fake, items: items, vault: vault, dirPath: "a")
    // Second run: registry-known → both skipped, nothing copied anywhere.
    let result2 = await engine.run(source: fake, items: items, vault: vault, dirPath: "b")
    #expect(result2.imported.isEmpty && result2.skipped.count == 2)
    #expect(try lib.items(inDir: "b").isEmpty)
}

@Test func collisionGetsSuffixedName() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try t.file("Pictures/trip/IMG_1.JPG", Data("different-bytes".utf8))
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    let result = await engine.run(source: fake, items: [items[0]], vault: vault, dirPath: "trip")
    #expect(result.imported.count == 1)
    #expect(FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent("trip/IMG_1 (2).JPG").path))
}

@Test func fetchFailureFailsItemAndBatchContinues() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    fake.failFetchIDs = ["1"]
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    let result = await engine.run(source: fake, items: items, vault: vault, dirPath: "x")
    #expect(result.failed.count == 1 && result.failed[0].item.id == "1")
    #expect(result.imported.count == 1)
    #expect(reg.entries(forSourceKey: "fk").count == 1)   // failed item never recorded
}

@Test func livePairImportsAtomically() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    var photo = ImportItem(id: "p", name: "IMG_9.HEIC", byteSize: 3,
                           takenAt: Date(timeIntervalSince1970: 50), kind: .photo, livePartnerID: "v")
    var video = ImportItem(id: "v", name: "IMG_9.MOV", byteSize: 3,
                           takenAt: Date(timeIntervalSince1970: 50), kind: .video, livePartnerID: "p")
    let fake = FakeSource(sourceKey: "fk", items: [(photo, Data("ph".utf8)), (video, Data("vd".utf8))])
    let engine = ImportEngine(library: lib, registry: reg)
    // Caller passes ONLY the photo — the engine must pull the partner in.
    let result = await engine.run(source: fake, items: [photo], vault: vault, dirPath: "lp")
    #expect(result.imported.count == 2)
    #expect(FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent("lp/IMG_9.MOV").path))
    _ = (photo, video)
}
```

- [ ] **Step 2:** filter-run → FAIL.

- [ ] **Step 3: LibraryService changes** — in `Sources/OpenPhotoCore/LibraryService.swift`:
  (a) change `private func rescan(vaultID:)` to `public func rescan(vaultID: String) async throws` (body unchanged);
  (b) add the sync-log helper:

```swift
    /// Append an event to the vault's sync-log.jsonl (format §9, informative).
    public func appendSyncLog(vault: Vault, event: String, summary: String,
                              counterpartyKey: String) {
        let line: [String: Any] = ["event": event,
                                   "at": ISO8601Millis.string(from: Date()),
                                   "counterparty_vault_id": counterpartyKey,
                                   "summary": summary]
        guard let data = try? JSONSerialization.data(withJSONObject: line,
                                                     options: [.sortedKeys]) else { return }
        var existing = (try? Data(contentsOf: vault.syncLogURL)) ?? Data()
        existing.append(data); existing.append(0x0A)
        try? AtomicFile.write(existing, to: vault.syncLogURL)
    }
```

- [ ] **Step 4: implement `ImportEngine.swift`:**

```swift
import Foundation

/// Runs one import batch: stage → hash → dedup → place → rescan → verify →
/// registry. Spec: docs/superpowers/specs/2026-06-08-phase2-import-design.md §3.
public final class ImportEngine: Sendable {
    public struct ImportedItem: Sendable, Equatable {
        public let item: ImportItem
        public let hash: String
        public let placedRelPath: String
    }
    public struct FailedItem: Sendable {
        public let item: ImportItem
        public let reason: String
    }
    public struct BatchResult: Sendable {
        public var imported: [ImportedItem] = []
        public var skipped: [ImportItem] = []      // duplicates (registry or library)
        public var failed: [FailedItem] = []
    }
    public struct Progress: Sendable {
        public enum Stage: String, Sendable { case fetching, placing, verifying }
        public let stage: Stage
        public let done: Int
        public let total: Int
        public let currentName: String
    }

    private let library: LibraryService
    private let registry: ImportRegistry

    public init(library: LibraryService, registry: ImportRegistry) {
        self.library = library
        self.registry = registry
    }

    public func run(source: any ImportSource, items: [ImportItem],
                    vault: Vault, dirPath: String,
                    progress: (@Sendable (Progress) -> Void)? = nil) async -> BatchResult {
        var result = BatchResult()
        let fm = FileManager.default

        // 0. Expand Live pairs: selecting either half imports both (spec §3).
        var work = items
        let ids = Set(items.map(\.id))
        for item in items {
            if let pid = item.livePartnerID, !ids.contains(pid) {
                // Partner not in the selection — pull it from the source listing.
                if let partner = try? await source.enumerateItems().first(where: { $0.id == pid }) {
                    work.append(partner)
                }
            }
        }

        // 1. Fresh staging area (cleared at session start by the UI; per-batch uuid here).
        let staging = vault.stateDirURL.appendingPathComponent("staging")
            .appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 2. Disk-space precheck (plan-then-act).
        let needed = work.reduce(Int64(0)) { $0 + $1.byteSize }
        if let free = (try? vault.rootURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage,
           free < needed * 2 {   // ×2: staging + placed copies coexist briefly
            result.failed = work.map { FailedItem(item: $0, reason: "not enough disk space") }
            return result
        }

        // 3. Per-item: fetch → hash → dedup-check → remember staged file.
        var staged: [(item: ImportItem, url: URL, hash: String)] = []
        let known = (try? library.catalog.knownHashes()) ?? []
        for (i, item) in work.enumerated() {
            progress?(Progress(stage: .fetching, done: i, total: work.count, currentName: item.name))
            let takenStr = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
            if registry.contains(sourceKey: source.sourceKey, name: item.name,
                                 size: item.byteSize, takenAt: takenStr) {
                result.skipped.append(item)
                continue
            }
            let dest = staging.appendingPathComponent(UUID().uuidString + "-" + item.name)
            do {
                try await source.fetch(item, to: dest)
                let hash = try ContentHash.ofFile(at: dest).stringValue
                if known.contains(hash) {
                    // Library already has these bytes — record and skip.
                    try? registry.append(.init(sourceKey: source.sourceKey, name: item.name,
                        size: item.byteSize, takenAt: takenStr, hash: hash,
                        importedAt: ISO8601Millis.string(from: Date()),
                        importedTo: ""))
                    result.skipped.append(item)
                    try? fm.removeItem(at: dest)
                    continue
                }
                staged.append((item, dest, hash))
            } catch {
                result.failed.append(FailedItem(item: item, reason: String(describing: error)))
            }
        }

        // 4. Place with collision-safe names.
        let dirURL = vault.absoluteURL(forRelativePath: dirPath)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        var placed: [(item: ImportItem, relPath: String, hash: String)] = []
        for (i, s) in staged.enumerated() {
            progress?(Progress(stage: .placing, done: i, total: staged.count, currentName: s.item.name))
            let target = collisionFreeURL(for: s.item.name, in: dirURL)
            do {
                try fm.moveItem(at: s.url, to: target)
                placed.append((s.item, vault.relativePath(of: target), s.hash))
            } catch {
                result.failed.append(FailedItem(item: s.item, reason: String(describing: error)))
            }
        }

        // 5. One incremental rescan picks the placed files into manifest+catalog.
        progress?(Progress(stage: .verifying, done: 0, total: placed.count, currentName: ""))
        do { try await library.rescan(vaultID: vault.descriptor.vaultID) }
        catch {
            result.failed.append(contentsOf: placed.map {
                FailedItem(item: $0.item, reason: "rescan failed: \(error)") })
            return result
        }

        // 6. Verify: manifest hash (scanner's independent computation) must
        //    equal the staging hash. Only verified items enter the registry.
        let manifestByPath = Dictionary(uniqueKeysWithValues:
            ((try? Manifest.read(from: vault.manifestURL)) ?? []).map { ($0.path, $0.hash.stringValue) })
        for p in placed {
            if manifestByPath[p.relPath] == p.hash {
                try? registry.append(.init(sourceKey: source.sourceKey, name: p.item.name,
                    size: p.item.byteSize,
                    takenAt: p.item.takenAt.map(ISO8601Millis.string(from:)) ?? "",
                    hash: p.hash,
                    importedAt: ISO8601Millis.string(from: Date()),
                    importedTo: p.relPath))
                result.imported.append(ImportedItem(item: p.item, hash: p.hash,
                                                    placedRelPath: p.relPath))
            } else {
                result.failed.append(FailedItem(item: p.item,
                    reason: "verification mismatch at \(p.relPath)"))
            }
        }

        library.appendSyncLog(vault: vault, event: "import",
            summary: "\(result.imported.count) imported, \(result.skipped.count) skipped, \(result.failed.count) failed → \(dirPath)",
            counterpartyKey: source.sourceKey)
        return result
    }

    /// IMG_1.JPG → IMG_1 (2).JPG → IMG_1 (3).JPG …
    private func collisionFreeURL(for name: String, in dir: URL) -> URL {
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

- [ ] **Step 5:** `swift test --filter ImportEngineTests` → 5 PASS; full suite green; 0 warnings. (If Swift 6 flags anything — e.g. the `try? await` in pair expansion — adapt minimally and report.)
- [ ] **Step 6: Commit:** `git add Sources/OpenPhotoCore Tests/OpenPhotoCoreTests/ImportEngineTests.swift && git commit -m "feat: ImportEngine — stage/hash/dedup/place/verify pipeline with registry"`

### Task 5: CameraSource (ImageCaptureCore — thin, hardware-validated)

**Files:**
- Create: `Sources/OpenPhotoCore/Import/CameraSource.swift`
- Modify: `Package.swift` (move ImageCaptureCore link to OpenPhotoCore target; ICCSpike keeps its own)

**No unit tests** — this is the hardware seam; the spike (`Sources/ICCSpike/main.swift`) is its proven skeleton and Task 9's manual checklist validates it. It must COMPILE warning-free.

- [ ] **Step 1:** In `Package.swift`, add to the OpenPhotoCore target: `linkerSettings: [.linkedFramework("ImageCaptureCore")]`.

- [ ] **Step 2: implement `CameraSource.swift`** (continuation-bridged ICC delegate; mirrors the spike):

```swift
import Foundation
import CoreGraphics
@preconcurrency import ImageCaptureCore

/// ImportSource for a USB-connected camera device (iPhone) via ImageCaptureCore.
/// Hardware-validated (see spike findings doc); keep this layer THIN.
public final class CameraSource: NSObject, ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let camera: ICCameraDevice
    private var itemsByID: [String: ICCameraItem] = [:]

    public private(set) var stateStream: AsyncStream<SourceState>!
    private var stateContinuation: AsyncStream<SourceState>.Continuation!
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var deleteContinuation: CheckedContinuation<Void, Error>?

    public init(camera: ICCameraDevice) {
        self.camera = camera
        self.displayName = camera.name ?? "Camera"
        self.sourceKey = "cam-" + (camera.serialNumberString ?? camera.name ?? "unknown")
        super.init()
        (stateStream, stateContinuation) = {
            var c: AsyncStream<SourceState>.Continuation!
            let s = AsyncStream<SourceState> { c = $0 }
            return (s, c)
        }()
        camera.delegate = self
    }

    /// Open session; resolves when content catalog is ready. -9943 (locked)
    /// surfaces as .waitingForUnlock on stateStream and the call keeps waiting —
    /// unlock triggers automatic retry (spike-proven pattern).
    public func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyContinuations.append(c)
            stateContinuation.yield(.connected)
            camera.requestOpenSession()
        }
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        itemsByID.removeAll()
        var items: [ImportItem] = files.map { f in
            let id = String(f.ptpObjectHandle)
            itemsByID[id] = f
            return ImportItem(id: id, name: f.name ?? "item-\(id)",
                              byteSize: Int64(f.fileSize),
                              takenAt: f.creationDate,
                              kind: MediaKind.of(filename: f.name ?? "") ?? .photo,
                              livePartnerID: nil)
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        guard let file = itemsByID[item.id] as? ICCameraFile else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = url.deletingLastPathComponent()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            downloadContinuation = c
            camera.requestDownloadFile(file,
                options: [.downloadsDirectoryURL: dir as Any,
                          .saveAsFilename: url.lastPathComponent as Any],
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownload(_:error:options:contextInfo:)),
                contextInfo: nil)
        }
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        // Spike: requestDeleteFiles completes via didCompleteDeleteFilesWithError.
        // Delete one-by-one so failures are attributable per item (spec §5).
        var results: [DeleteResult] = []
        for item in items {
            guard let file = itemsByID[item.id] else {
                results.append(DeleteResult(itemID: item.id, error: "not found")); continue
            }
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    deleteContinuation = c
                    camera.requestDeleteFiles([file])
                }
                results.append(DeleteResult(itemID: item.id, error: nil))
            } catch {
                results.append(DeleteResult(itemID: item.id, error: String(describing: error)))
            }
        }
        return results
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        guard let file = itemsByID[item.id] else { return nil }
        if let existing = file.thumbnail { return existing.takeUnretainedValue() }
        file.requestThumbnail()
        // Thumbnail arrives via delegate; poll briefly (UI re-requests on nil).
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let thumb = file.thumbnail { return thumb.takeUnretainedValue() }
        }
        return nil
    }

    @objc private func didDownload(_ file: ICCameraFile, error: (any Error)?,
                                   options: [String: Any],
                                   contextInfo: UnsafeMutableRawPointer?) {
        if let error { downloadContinuation?.resume(throwing: error) }
        else { downloadContinuation?.resume() }
        downloadContinuation = nil
    }
}

extension CameraSource: ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            let ns = error as NSError
            if ns.code == -9943 { stateContinuation.yield(.waitingForUnlock); return }
            readyContinuations.forEach { $0.resume(throwing: error) }
            readyContinuations.removeAll()
        }
    }
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        stateContinuation.yield(.ready)
        readyContinuations.forEach { $0.resume() }
        readyContinuations.removeAll()
    }
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        stateContinuation.yield(.connected)
        camera.requestOpenSession()       // spike-proven retry
    }
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        stateContinuation.yield(.waitingForUnlock)
    }
    public func didRemove(_ device: ICDevice) {
        stateContinuation.yield(.gone)
        readyContinuations.forEach { $0.resume(throwing: CocoaError(.serviceRequestCancelled)) }
        readyContinuations.removeAll()
    }
    public func cameraDevice(_ camera: ICCameraDevice,
                             didCompleteDeleteFilesWithError error: (any Error)?) {
        if let error { deleteContinuation?.resume(throwing: error) }
        else { deleteContinuation?.resume() }
        deleteContinuation = nil
    }
    // Required stubs (signatures per macOS 15 SDK — fix per compiler as in the spike):
    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                             for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                             for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
```

NOTE: ICC API details (e.g. `.saveAsFilename` option key, `thumbnail` property type, exact delegate signatures) shift between SDKs — adapt per compiler exactly as the spike did, and report adaptations. The CONTRACT (open/enumerate/fetch/delete semantics, lock-wait states) is what matters.

- [ ] **Step 3:** `swift build` → 0 warnings; `swift test` → all green (no new tests).
- [ ] **Step 4: Commit:** `git add Package.swift Sources/OpenPhotoCore/Import/CameraSource.swift && git commit -m "feat: CameraSource — ImageCaptureCore import source with lock-wait states"`

---

# Part B — App

UI tasks: verified by `swift build` (0 warnings) + the controller's relaunch; visual truth is `UI-Design/design_handoff_openphoto/import.jsx` + README §3 (large thumbs min 178px gap 10px radius 10px, circular checkbox top-left, dupes greyed non-selectable with "Already in library" pill, sticky footer with destination Menu + two-phase progress).

### Task 6: DeviceWatcher + sidebar Devices section

**Files:**
- Create: `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift`
- Modify: `Sources/OpenPhotoApp/Sidebar/SidebarView.swift` (Devices section)
- Modify: `Sources/OpenPhotoApp/AppState.swift` (deviceWatcher + openedDevice)
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift` (RootView routes to ImportView)
- Create placeholder: `Sources/OpenPhotoApp/Devices/ImportView.swift` (`Text("Import — Task 7")`, signature `ImportView(state:device:)`)

- [ ] **Step 1: `DeviceWatcher.swift`:**

```swift
import SwiftUI
import OpenPhotoCore
@preconcurrency import ImageCaptureCore

/// A connectable import origin shown in the sidebar's Devices section.
enum ConnectedDevice: Identifiable, Equatable {
    case camera(id: String, name: String)
    case volume(id: String, name: String, url: URL)
    var id: String {
        switch self {
        case .camera(let id, _): "cam-\(id)"
        case .volume(let id, _, _): "vol-\(id)"
        }
    }
    var name: String {
        switch self {
        case .camera(_, let n): n
        case .volume(_, let n, _): n
        }
    }
    var symbol: String {
        switch self {
        case .camera: "iphone"
        case .volume: "sdcard"
        }
    }
}

/// Watches ICDeviceBrowser + volume mounts; exposes devices + source factory.
@Observable @MainActor
final class DeviceWatcher: NSObject {
    private(set) var devices: [ConnectedDevice] = []
    private var cameras: [String: ICCameraDevice] = [:]
    private let browser = ICDeviceBrowser()

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000001 | 0x00000100)!
        browser.start()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        volumesChanged()
    }

    func source(for device: ConnectedDevice) -> (any ImportSource)? {
        switch device {
        case .camera(let id, _):
            cameras[id].map { CameraSource(camera: $0) }
        case .volume(_, _, let url):
            VolumeSource(rootURL: url, displayName: device.name)
        }
    }

    @objc private func volumesChanged() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var vols: [ConnectedDevice] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRemovable == true,
                  FileManager.default.fileExists(
                      atPath: url.appendingPathComponent("DCIM").path) else { continue }
            vols.append(.volume(id: v.volumeUUIDString ?? url.path,
                                name: v.volumeName ?? url.lastPathComponent, url: url))
        }
        devices = devices.filter { if case .camera = $0 { true } else { false } } + vols
    }
}

extension DeviceWatcher: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice,
                                   moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let id = cam.serialNumberString ?? cam.name ?? UUID().uuidString
        let name = cam.name ?? "Camera"
        Task { @MainActor in
            self.cameras[id] = cam
            if !self.devices.contains(where: { $0.id == "cam-\(id)" }) {
                self.devices.append(.camera(id: id, name: name))
            }
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice,
                                   moreGoing: Bool) {
        let name = device.name
        Task { @MainActor in
            if let (id, _) = self.cameras.first(where: { $0.value.name == name }) {
                self.cameras[id] = nil
                self.devices.removeAll { $0.id == "cam-\(id)" }
                if self.openedDeviceRemoved != nil { self.openedDeviceRemoved?("cam-\(id)") }
            }
        }
    }
}
```

Also add to the DeviceWatcher CLASS BODY (not the extension — extensions can't hold stored properties) a callback so an unplug closes an open import session:
```swift
    /// Set by AppState; called with the removed device's id.
    var openedDeviceRemoved: ((String) -> Void)?
```
(the `didRemove` delegate method above already calls it).

- [ ] **Step 2: AppState additions:**

```swift
    var deviceWatcher = DeviceWatcher()
    var openedDevice: ConnectedDevice?      // non-nil → ImportView is shown
```
In `openLibrary(roots:)` (after `startWatcher`): `deviceWatcher.start()` and
```swift
        deviceWatcher.openedDeviceRemoved = { [weak self] id in
            if self?.openedDevice?.id == id { self?.openedDevice = nil }
        }
```

- [ ] **Step 3: SidebarView** — after the LIBRARY ForEach, add:

```swift
            if !state.deviceWatcher.devices.isEmpty {
                Text("DEVICES")
                    .font(.system(size: 11, weight: .semibold)).kerning(0.44)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                ForEach(state.deviceWatcher.devices) { device in
                    let active = state.openedDevice?.id == device.id
                    Button { state.openedDevice = device } label: {
                        HStack(spacing: 9) {
                            Image(systemName: device.symbol).frame(width: 18)
                            Text(device.name).font(.system(size: 13.5, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background(active ? Theme.accentDim : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(active ? Theme.accent : Theme.text)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
            }
```

- [ ] **Step 4: RootView** — in the detail builder, before the sidebar-selection switch: `if let device = state.openedDevice { ImportView(state: state, device: device) } else { detailSwitch }` (restructure the existing `@ViewBuilder` accordingly).

- [ ] **Step 5:** `swift build` 0 warnings; `swift test` green. Commit: `git add Sources/OpenPhotoApp Package.swift && git commit -m "feat(app): device watcher + sidebar Devices section"`

### Task 7: ImportView + ImportItemCell (the session screen)

**Files:**
- Replace: `Sources/OpenPhotoApp/Devices/ImportView.swift`
- Create: `Sources/OpenPhotoApp/Devices/ImportItemCell.swift`
- Modify: `Sources/OpenPhotoApp/AppState.swift` (add `importRegistry` lazy accessor)

- [ ] **Step 1: AppState** — add:

```swift
    private var _importRegistry: ImportRegistry?
    var importRegistry: ImportRegistry? {
        if _importRegistry == nil, let primary = library?.vaults.first {
            _importRegistry = ImportRegistry(vault: primary)
        }
        return _importRegistry
    }
```

- [ ] **Step 2: `ImportItemCell.swift`:**

```swift
import SwiftUI
import OpenPhotoCore

struct ImportItemCell: View {
    let item: ImportItem
    let source: any ImportSource
    let alreadyImported: Bool
    let importedThisSession: Bool
    let selected: Bool
    let onToggle: () -> Void
    @State private var thumb: CGImage?

    var body: some View {
        ZStack {
            Theme.tile
            if let thumb {
                Image(decorative: thumb, scale: 1).resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            if !alreadyImported {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.85))
                    .shadow(radius: 2).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.livePartnerID != nil, item.kind == .photo {
                Image(systemName: "livephoto").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white).padding(5)
                    .background(.black.opacity(0.45), in: Capsule()).padding(6)
            } else if item.kind == .video {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white).padding(5)
                    .background(.black.opacity(0.45), in: Capsule()).padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if importedThisSession {
                badge("Imported ✓", color: Theme.green)
            } else if alreadyImported {
                badge("Already in library", color: Theme.textFaint)
            }
        }
        .opacity(alreadyImported && !importedThisSession ? 0.45 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { if !alreadyImported { onToggle() } }
        .task(id: item.id) {
            thumb = await source.thumbnail(item, maxPixel: 360)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(color).padding(6)
    }
}
```

- [ ] **Step 3: `ImportView.swift`** (session state machine: connecting → waitingForUnlock → ready/select → importing → batchDone; sequential batches; accumulates verified items):

```swift
import SwiftUI
import OpenPhotoCore

struct ImportView: View {
    @Bindable var state: AppState
    let device: ConnectedDevice

    enum Phase: Equatable { case connecting, waitingForUnlock, ready, importing(done: Int, total: Int), failedToConnect(String) }
    @State private var phase: Phase = .connecting
    @State private var source: (any ImportSource)?
    @State private var items: [ImportItem] = []
    @State private var selection = Set<String>()
    @State private var destination: String = ""
    @State private var newFolderName: String = ""
    @State private var sessionImported: [ImportEngine.ImportedItem] = []   // across batches
    @State private var sessionImportedIDs = Set<String>()
    @State private var lastResult: ImportEngine.BatchResult?
    @State private var showFreeUp = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
            Divider().overlay(Theme.hairline)
            footer
        }
        .task(id: device.id) { await connect() }
        .sheet(isPresented: $showFreeUp) {
            if let source, let registry = state.importRegistry,
               let lib = state.library, let vault = lib.vaults.first {
                FreeUpPhoneView(source: source, registry: registry,
                                library: lib, vault: vault,
                                deviceItems: items,
                                sessionImportedIDs: sessionImportedIDs) {
                    Task { await reloadItems() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
            Text(device.name).font(.system(size: 15, weight: .semibold))
            if case .ready = phase {
                Text("\(items.count) items · \(alreadyImportedCount) already imported")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Select all new") {
                selection = Set(items.filter { !isImported($0) }.map(\.id))
            }.controlSize(.small)
            Button("Deselect") { selection.removeAll() }.controlSize(.small)
            Button { state.openedDevice = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .connecting:
            ContentUnavailableView("Connecting…", systemImage: "cable.connector")
                .frame(maxHeight: .infinity)
        case .waitingForUnlock:
            ContentUnavailableView {
                Label("Unlock your \(device.name)", systemImage: "lock.iphone")
            } description: {
                Text("OpenPhoto is waiting — unlock the device and this screen will continue automatically.")
            }.frame(maxHeight: .infinity)
        case .failedToConnect(let why):
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
            } description: { Text(why) }.frame(maxHeight: .infinity)
        case .ready, .importing:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 10)],
                          spacing: 10) {
                    ForEach(displayItems) { item in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay {
                                ImportItemCell(
                                    item: item, source: source!,
                                    alreadyImported: isImported(item),
                                    importedThisSession: sessionImportedIDs.contains(item.id),
                                    selected: selection.contains(item.id),
                                    onToggle: { toggle(item) })
                            }
                            .clipped()
                    }
                }
                .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch phase {
            case .importing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                Text("Copying & verifying… \(done)/\(total) · checksum verified before any deletion")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            default:
                if let r = lastResult {
                    Label("\(r.imported.count) imported & verified" +
                          (r.skipped.isEmpty ? "" : " · \(r.skipped.count) duplicates skipped") +
                          (r.failed.isEmpty ? "" : " · \(r.failed.count) FAILED"),
                          systemImage: r.failed.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(r.failed.isEmpty ? Theme.green : Theme.amber)
                }
                Text("\(selection.count) selected")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
                destinationPicker
                Button("Import \(selection.count) items") { Task { await runBatch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || destination.isEmpty)
                if !sessionImported.isEmpty || hasPreviouslyImportedOnDevice {
                    Button("Free up space on \(device.name)…") { showFreeUp = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight + 8)
    }

    private var destinationPicker: some View {
        Menu {
            ForEach(allFolders, id: \.self) { f in
                Button(f) { destination = f }
            }
            Divider()
            TextField("New folder…", text: $newFolderName)
                .onSubmit { destination = newFolderName }
        } label: {
            Label(destination.isEmpty ? "Destination…" : destination,
                  systemImage: "folder")
        }
        .menuStyle(.borderedButton)
        .frame(maxWidth: 260)
    }

    // MARK: helpers

    private var displayItems: [ImportItem] {
        // Hide the video halves of Live pairs — the photo tile represents both.
        items.filter { !($0.kind == .video && $0.livePartnerID != nil) }
    }
    private var allFolders: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { paths.append(n.path); walk(n.children) } }
        walk(state.folderTree)
        return paths.sorted()
    }
    private var alreadyImportedCount: Int { items.filter(isImported).count }
    private var hasPreviouslyImportedOnDevice: Bool {
        items.contains { isImported($0) && !sessionImportedIDs.contains($0.id) }
    }
    private func isImported(_ item: ImportItem) -> Bool {
        guard let reg = state.importRegistry, let source else { return false }
        let taken = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
        return sessionImportedIDs.contains(item.id) ||
               reg.contains(sourceKey: source.sourceKey, name: item.name,
                            size: item.byteSize, takenAt: taken)
    }
    private func toggle(_ item: ImportItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
        // Live pairs select atomically (engine enforces too; UI mirrors it).
        if let pid = item.livePartnerID {
            if selection.contains(item.id) { selection.insert(pid) }
            else { selection.remove(pid) }
        }
    }

    private func connect() async {
        phase = .connecting
        guard let src = state.deviceWatcher.source(for: device) else {
            phase = .failedToConnect("Source unavailable"); return
        }
        source = src
        if let cam = src as? CameraSource {
            Task {   // observe lock-state transitions for the UI
                for await s in cam.stateStream {
                    await MainActor.run {
                        if s == .waitingForUnlock { phase = .waitingForUnlock }
                    }
                }
            }
            do { try await cam.open() }
            catch { phase = .failedToConnect(String(describing: error)); return }
        }
        await reloadItems()
        phase = .ready
    }

    private func reloadItems() async {
        guard let source else { return }
        items = (try? await source.enumerateItems()) ?? []
    }

    private func runBatch() async {
        guard let source, let lib = state.library, let registry = state.importRegistry,
              let vault = lib.vaults.first else { return }
        let batchItems = items.filter { selection.contains($0.id) }
        phase = .importing(done: 0, total: batchItems.count)
        let engine = ImportEngine(library: lib, registry: registry)
        let result = await engine.run(source: source, items: batchItems,
                                      vault: vault, dirPath: destination) { p in
            Task { @MainActor in phase = .importing(done: p.done, total: p.total) }
        }
        lastResult = result
        sessionImported.append(contentsOf: result.imported)
        sessionImportedIDs.formUnion(result.imported.map(\.item.id))
        selection.removeAll()
        try? state.refreshQueries()
        phase = .ready
    }
}
```

- [ ] **Step 4:** `swift build` 0 warnings; `swift test` green. Adapt minimally per compiler (Menu-with-TextField may need a custom popover on macOS — if `Menu` rejects the TextField, replace the destination picker with a `Picker` + separate "New folder" TextField beside it; report the adaptation).
- [ ] **Step 5: Commit:** `git add Sources/OpenPhotoApp && git commit -m "feat(app): import session screen — grid, badges, sequential batches"`

### Task 8: FreeUpPhoneView (deletion selection flow)

**Files:**
- Create: `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift`

- [ ] **Step 1: implement:**

```swift
import SwiftUI
import OpenPhotoCore

/// Opt-in deletion flow — spec §5. Nothing preselected; only registry-verified
/// items are listed; deletion is per-item with per-item failure reporting.
struct FreeUpPhoneView: View {
    let source: any ImportSource
    let registry: ImportRegistry
    let library: LibraryService          // for the device-delete sync-log event
    let vault: Vault
    let deviceItems: [ImportItem]
    let sessionImportedIDs: Set<String>
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var deleting = false
    @State private var results: [DeleteResult]?
    @State private var confirming = false

    private var verifiedOnDevice: [ImportItem] {
        deviceItems.filter { item in
            let taken = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
            return registry.contains(sourceKey: source.sourceKey, name: item.name,
                                     size: item.byteSize, takenAt: taken)
        }
    }
    private var thisSession: [ImportItem] {
        verifiedOnDevice.filter { sessionImportedIDs.contains($0.id) }
    }
    private var previous: [ImportItem] {
        verifiedOnDevice.filter { !sessionImportedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Free up space on \(source.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss(); onDone() }
            }
            .padding(16)
            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) {
                chip("This session") { selection = Set(thisSession.map(\.id)) }
                chip("Screenshots") {
                    selection = Set(verifiedOnDevice
                        .filter { $0.name.lowercased().hasSuffix(".png") }.map(\.id))
                }
                chip("All") { selection = Set(verifiedOnDevice.map(\.id)) }
                chip("None") { selection.removeAll() }
                Spacer()
                Text("\(selection.count) selected")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            ScrollView {
                if !thisSession.isEmpty {
                    sectionGrid("IMPORTED THIS SESSION", thisSession)
                }
                if !previous.isEmpty {
                    DisclosureGroup("Previously imported, still on \(source.displayName) (\(previous.count))") {
                        sectionGrid(nil, previous)
                    }
                    .padding(.horizontal, 16)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                }
                if let results {
                    resultsList(results)
                }
            }

            Divider().overlay(Theme.hairline)
            HStack {
                Text("Only photos verified in your library are listed.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Spacer()
                if deleting { ProgressView().controlSize(.small) }
                Button("Delete \(selection.count) from \(source.displayName)…", role: .destructive) {
                    confirming = true
                }
                .disabled(selection.isEmpty || deleting)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .confirmationDialog(
            "Delete \(selection.count) photos from \(source.displayName)?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Delete — immediate and permanent on the device", role: .destructive) {
                Task { await runDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There is no Recently Deleted on the device for USB deletion. Verified copies exist in your library.")
        }
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered).controlSize(.small)
    }

    private func sectionGrid(_ title: String?, _ items: [ImportItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 10.5, weight: .semibold)).kerning(0.4)
                    .foregroundStyle(Theme.textFaint).padding(.horizontal, 16)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(items) { item in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay {
                            ImportItemCell(item: item, source: source,
                                           alreadyImported: false,
                                           importedThisSession: false,
                                           selected: selection.contains(item.id),
                                           onToggle: {
                                               if selection.contains(item.id) { selection.remove(item.id) }
                                               else { selection.insert(item.id) }
                                           })
                        }
                        .clipped()
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func resultsList(_ results: [DeleteResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let failed = results.filter { $0.error != nil }
            Label("\(results.count - failed.count) deleted from device" +
                  (failed.isEmpty ? "" : " · \(failed.count) failed"),
                  systemImage: failed.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(failed.isEmpty ? Theme.green : Theme.amber)
            ForEach(failed, id: \.itemID) { f in
                Text("• \(f.itemID): \(f.error ?? "")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func runDelete() async {
        deleting = true
        defer { deleting = false }
        let toDelete = verifiedOnDevice.filter { selection.contains($0.id) }
        let r = (try? await source.delete(toDelete)) ??
            toDelete.map { DeleteResult(itemID: $0.id, error: "delete request failed") }
        results = r
        let failed = r.filter { $0.error != nil }.count
        library.appendSyncLog(vault: vault, event: "device-delete",
            summary: "\(r.count - failed) deleted from \(source.displayName), \(failed) failed",
            counterpartyKey: source.sourceKey)
        selection.removeAll()
    }
}
```

- [ ] **Step 2:** `swift build` 0 warnings; `swift test` green. Commit: `git add Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift && git commit -m "feat(app): free-up-phone selection flow with permanence confirmation"`

### Task 9: Validation — fixtures end-to-end + hardware checklist

**Files:**
- Modify: `README.md` (Status paragraph: Phase 2 implemented)

- [ ] **Step 1: Fixture end-to-end (no hardware, agent-runnable):** generate a fake SD card inside the repo and import from it via the real app:

```bash
swift scripts/gen-fixtures.swift 40 && mkdir -p fixtures-card/DCIM && cp -R fixtures-library/rome2022 fixtures-card/DCIM/ && swift run OpenPhotoApp
```
Wait — VolumeSource devices come from REMOVABLE volume detection; a repo folder won't appear in Devices. For validation, temporarily verify via the Core test suite (VolumeSource + ImportEngine cover this path) plus: add a DEBUG-only "Open folder as device…" menu command:
In `OpenPhotoApp.swift` commands block, add:
```swift
        CommandGroup(after: .newItem) {
            Button("Open Folder as Import Source…") {
                MainActor.assumeIsolated {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        state.deviceWatcher.addManualVolume(url: url)
                    }
                }
            }
        }
```
and in DeviceWatcher:
```swift
    func addManualVolume(url: URL) {
        devices.append(.volume(id: "manual-" + url.path,
                               name: url.lastPathComponent, url: url))
    }
```
(This is also genuinely useful: "import from any folder". Keep it, not DEBUG-gated.)
Then: launch app → File menu → Open Folder as Import Source → pick `fixtures-card` → grid shows items → import a batch to a new folder → verify badges, dedup on second attempt, and "free up" flow moving card files to `fixtures-card/.openphoto-trash/`. Checklist (record results in commit message):
- [ ] Grid shows items newest-first with thumbnails
- [ ] Import batch → verified ✓ badges; photos appear in library timeline
- [ ] Re-attempt import → all skipped as duplicates
- [ ] Free-up flow: chips work; deletion moves files to `.openphoto-trash/`; nothing preselected
- [ ] `imports.jsonl` exists in `fixtures-library/.openphoto/` (or chosen vault) with correct entries

- [ ] **Step 2: HARDWARE checklist (MANUAL — requires Jude + iPhone; controller pauses here):**
- [ ] Plug in locked iPhone → Devices shows it → ImportView shows "Unlock your iPhone" → unlock → grid loads (4,357 items, newest first)
- [ ] Import 2–3 expendable photos to a test folder → verified; Live Photo imports as pair
- [ ] Re-open device → those items badge "Already in library"
- [ ] Free-up flow with ONE user-designated expendable item → deleted; permanence dialog shown; per-item result listed
- [ ] Unplug mid-session → ImportView closes cleanly, no crash, no stray staging

- [ ] **Step 3:** README Status: change to "**Phases 1–2** — browse + device import implemented; Phases 3–5 designed". Full `swift test` green; 0 warnings.
- [ ] **Step 4: Commit:** `git add README.md Sources/OpenPhotoApp && git commit -m "feat(app): manual import source via folder; phase 2 validation; README status"`

---

## Deferred within Phase 2 (intentional)

- Thumbnail delegate-callback wiring for CameraSource (current poll-based `thumbnail()` is adequate; revisit if grid feels slow on 4k-item devices)
- Recent-destinations memory for the picker (list is alphabetic folder tree for now)
- Volume `.openphoto-trash` emptying UI (Finder suffices; documented in format doc)
- Import progress in the sidebar activity indicator (footer progress suffices)

## Done means

All 9 tasks committed; suite green (≈66 tests); 0 warnings; fixture end-to-end checklist passes; hardware checklist passes with Jude's iPhone; format doc §12 shipped with the registry code; spec §§3–6 fully covered.
