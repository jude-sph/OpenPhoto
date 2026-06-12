# Foreign Imports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import from libraries that aren't yours — another person's OpenPhoto drive (auto-detected, browsed per-folder, structure preserved under a parent) and a friend's Apple Photos export folder (10k-scale enumeration, optional XMP-sidecar metadata fold) — through the existing import pipeline.

**Architecture:** A new read-only `ForeignVaultSource` enumerates from the foreign drive's *documented* formats (manifest.jsonl inventory; catalog-snapshot dates/thumbnails read with GRDB read-only, as `CatalogSnapshot.import` already does). `ImportEngine` gains two optional hooks: per-item destination subdirs (structure preservation) and a post-place callback (sidecar carry before the rescan). `VolumeSource` gains bounded-concurrency EXIF enumeration with progress and an opt-in Apple-XMP fold. DeviceWatcher surfaces unknown-vault volumes; ImportView gains a folder panel + "Include their metadata" toggle.

**Tech Stack:** Swift 6, SwiftPM (Command Line Tools ONLY — `swift build` / `swift test`, NO Xcode), SwiftUI (macOS 15), GRDB. Spec: `docs/superpowers/specs/2026-06-12-foreign-imports-design.md`.

---

## Hard rules (every task)

- Build/test ONLY with `swift build` / `swift test` (CLT). Never Xcode/xcodebuild.
- **0 warnings**: both `swift build 2>&1 | grep -i warning` and `swift build --build-tests 2>&1 | grep -i warning` must print nothing.
- Every commit message ends with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- NEVER access `~/Pictures`, `~/Movies`, or any personal folder. All test media generated (`makeJPEG` / raw `Data`) in `TestDirs`. `~/Documents/tests/OpenPhoto-drive` is REAL user data — never touch.
- No on-disk format change; no catalog migration; `schemaVersion` stays 11.
- Branch: `phase5.5-foreign-imports` (already created off `main`).

## File map

| File | Change |
|---|---|
| `Sources/OpenPhotoCore/Import/ImportSource.swift` | Modify — `ImportItem.knownHash` (defaulted; call sites unchanged) |
| `Sources/OpenPhotoCore/Import/ImportEngine.swift` | Modify — `subdirForItem` + `postPlace` hooks |
| `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift` | Modify — `assetDates(drive:)` read-only helper |
| `Sources/OpenPhotoCore/Catalog/Queries.swift` | Modify — `assetHashes()` |
| `Sources/OpenPhotoCore/Import/ForeignVaultSource.swift` | **Create** |
| `Sources/OpenPhotoCore/Import/VolumeSource.swift` | Modify — concurrent enumeration + progress + `sawXMPSidecars` + XMP fold |
| `Sources/OpenPhotoCore/Sidecar/XMP.swift` | Modify — `parseTitle(_:)` |
| `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift` | Modify — `.foreignVault` case + detection |
| `Sources/OpenPhotoApp/AppState.swift` | Modify — `knownVaultIDs` wiring + `sendDestination` arm |
| `Sources/OpenPhotoApp/Devices/ImportView.swift` | Modify — folder panel, toggle, progress, subdir/postPlace wiring |
| Tests | **Create**: `ForeignVaultSourceTests.swift`, `VolumeEnumerationTests.swift`, `AppleXMPFoldTests.swift`; **Modify**: `ImportEngineTests.swift` |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` | Modify — §10.5 item 2 DONE + changelog (Task 8) |

Existing context an implementer needs:
- `ImportItem`/`ImportSource`/`pairLiveItems`: `Sources/OpenPhotoCore/Import/ImportSource.swift` (ImportItem init is explicit memberwise).
- `ImportEngine.run` stages: expand pairs → staging dir → space precheck → per-item fetch/hash/dedup (`catalog.hashPresent(inVault:dirPath:hash:)`) → place (`FileNaming.collisionFreeURL`) → rescan → verify vs manifest → registry.
- `CatalogSnapshot`: `dirName = "catalog-snapshot"`, `thumbRelPath(forHash:)`, read-only GRDB pattern in `import(from:into:thumbnails:)` (`Configuration(); cfg.readonly = true`).
- `Vault.sidecarURL(forMediaAt:)`, `Manifest.read`, `ISO8601Millis.dateLenient(from:)` (VaultDescriptor.swift:53), `AtomicFile.write` (public), `MediaKind.of(filename:)`.
- Test fixtures: `TestDirs`, `makeJPEG(at:dateTimeOriginal:lat:lon:)`, `URL.creatingParent()`, `FakeSource` (Tests/OpenPhotoCoreTests/FakeSource.swift), `makeEnv` pattern in `ImportEngineTests.swift`.

---

### Task 1: ImportEngine hooks — `knownHash`, per-item subdirs, post-place callback (Core, TDD)

**Files:**
- Modify: `Sources/OpenPhotoCore/Import/ImportSource.swift` (ImportItem)
- Modify: `Sources/OpenPhotoCore/Import/ImportEngine.swift`
- Modify: `Tests/OpenPhotoCoreTests/ImportEngineTests.swift` (append)

- [ ] **Step 1: ImportItem gains `knownHash`** (defaulted — every existing call site compiles unchanged):

In `ImportSource.swift`, replace the `ImportItem` struct's property block and init with:

```swift
public struct ImportItem: Identifiable, Sendable, Equatable {
    public let id: String          // source-stable id (ICC object handle / volume relpath)
    public var name: String
    public var byteSize: Int64
    public var takenAt: Date?
    public var kind: MediaKind
    /// Set by pairLiveItems(): the other half of a Live Photo, if detected.
    public var livePartnerID: String?
    /// Content hash the SOURCE claims for this item (foreign OpenPhoto drives, from their
    /// manifest). Used ONLY to pre-flag "already in your library" before any byte copies —
    /// never for integrity; the engine still hashes and verifies its own copy.
    public var knownHash: String?

    public init(id: String, name: String, byteSize: Int64, takenAt: Date?,
                kind: MediaKind, livePartnerID: String?, knownHash: String? = nil) {
        self.id = id; self.name = name; self.byteSize = byteSize
        self.takenAt = takenAt; self.kind = kind; self.livePartnerID = livePartnerID
        self.knownHash = knownHash
    }
}
```

- [ ] **Step 2: Write the failing tests** (append to `ImportEngineTests.swift`; it already has `makeEnv`, `fakeItems`, `FakeSource`):

```swift
@Test func subdirForItemPlacesIntoPerItemFolders() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()

    let result = await engine.run(source: fake, items: items, vault: vault,
                                  dirPath: "From Sam",
                                  subdirForItem: { $0.id == "1" ? "rome2022" : "" })

    #expect(result.imported.count == 2 && result.failed.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: vault.absoluteURL(forRelativePath: "From Sam/rome2022/IMG_1.JPG").path))
    #expect(FileManager.default.fileExists(
        atPath: vault.absoluteURL(forRelativePath: "From Sam/IMG_2.JPG").path))
    // Registry + manifest recorded the real placed relPaths.
    let placed = Set(result.imported.map(\.placedRelPath))
    #expect(placed == ["From Sam/rome2022/IMG_1.JPG", "From Sam/IMG_2.JPG"])
}

@Test func subdirAwareDedupSkipsOnlyWithinTheSameTargetDir() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    // First import into From Sam/rome2022.
    _ = await engine.run(source: fake, items: [items[0]], vault: vault,
                         dirPath: "From Sam", subdirForItem: { _ in "rome2022" })
    // Same item again into the SAME subdir → skipped as duplicate.
    let again = await engine.run(source: fake, items: [items[0]], vault: vault,
                                 dirPath: "From Sam", subdirForItem: { _ in "rome2022" })
    #expect(again.skipped.count == 1 && again.imported.isEmpty)
}

@Test func postPlaceRunsBeforeRescanWithPlacedRelPath() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()

    // postPlace writes a sidecar next to the placed file; because the hook runs BEFORE the
    // engine's rescan, the rescan must ingest it in the same run (favorite lands in catalog).
    let result = await engine.run(source: fake, items: [items[0]], vault: vault,
                                  dirPath: "inbox",
                                  postPlace: { placed in
        let mediaURL = vault.absoluteURL(forRelativePath: placed.placedRelPath)
        let xmp = XMP.serialize(SidecarData(rating: 0, favorite: true, caption: "from them",
                                            tags: [], faces: []))
        try? AtomicFile.write(Data(xmp.utf8), to: vault.sidecarURL(forMediaAt: mediaURL))
    })

    #expect(result.imported.count == 1)
    let item = try lib.items(inDir: "inbox").first
    #expect(item?.favorite == true && item?.caption == "from them")
}
```

- [ ] **Step 3: Run — must FAIL to compile** (`subdirForItem`/`postPlace` don't exist): `swift test --filter ImportEngineTests 2>&1 | tail -5`

- [ ] **Step 4: Implement in `ImportEngine.swift`.**

(a) New `run` signature (the two hooks defaulted — existing callers unchanged):

```swift
    public func run(source: any ImportSource, items: [ImportItem],
                    vault: Vault, dirPath: String,
                    subdirForItem: (@Sendable (ImportItem) -> String)? = nil,
                    postPlace: (@Sendable (ImportedItem) async -> Void)? = nil,
                    progress: (@Sendable (Progress) -> Void)? = nil) async -> BatchResult {
```

(b) Directly after the staging/space-precheck section (before step 3's loop), add the per-item dir helper:

```swift
        // Per-item destination dir: dirPath plus the optional per-item subdir (foreign-vault
        // imports preserve THEIR folder tree under the chosen parent). Empty subdir = flat.
        func destDir(for item: ImportItem) -> String {
            guard let sub = subdirForItem?(item), !sub.isEmpty else { return dirPath }
            return dirPath.isEmpty ? sub : dirPath + "/" + sub
        }
```

(c) In step 3 (fetch/hash/dedup loop), the dedup check and registry line use `destDir(for: item)` instead of `dirPath`:

```swift
                if (try? library.catalog.hashPresent(
                        inVault: vault.descriptor.vaultID,
                        dirPath: destDir(for: item),
                        hash: hash)) == true {
                    try? registry.append(.init(sourceKey: source.sourceKey, name: item.name,
                        size: item.byteSize, takenAt: takenStr, hash: hash,
                        importedAt: ISO8601Millis.string(from: Date()),
                        importedTo: "\(destDir(for: item))/\(item.name)"))
```

(d) Replace step 4 (placement) — the single `dirURL` creation moves inside the loop, per item:

```swift
        // 4. Place with collision-safe names (per-item destination dir).
        var placed: [(item: ImportItem, relPath: String, hash: String)] = []
        for (i, s) in staged.enumerated() {
            progress?(Progress(stage: .placing, done: i, total: staged.count, currentName: s.item.name))
            let dirURL = vault.absoluteURL(forRelativePath: destDir(for: s.item))
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let target = FileNaming.collisionFreeURL(for: s.item.name, in: dirURL)
            do {
                try fm.moveItem(at: s.url, to: target)
                placed.append((s.item, vault.relativePath(of: target), s.hash))
            } catch {
                result.failed.append(FailedItem(item: s.item, reason: String(describing: error)))
            }
        }

        // 4.5. Post-place hook (e.g. sidecar carry) — BEFORE the rescan so whatever it
        // writes is ingested by the same scan.
        if let postPlace {
            for p in placed {
                await postPlace(ImportedItem(item: p.item, hash: p.hash, placedRelPath: p.relPath))
            }
        }
```

(Delete the old pre-loop `let dirURL = …` / `try? fm.createDirectory(…)` pair that step 4 had.)

- [ ] **Step 5: Run tests** — `swift test --filter ImportEngineTests 2>&1 | tail -3` → PASS (new + ALL pre-existing engine tests — flat behavior must be unchanged). Full `swift test`, both warning greps.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Import/ImportSource.swift Sources/OpenPhotoCore/Import/ImportEngine.swift Tests/OpenPhotoCoreTests/ImportEngineTests.swift
git commit -m "feat: ImportEngine per-item subdirs + post-place hook; ImportItem.knownHash

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Snapshot dates + catalog hash set (Core, TDD)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift` (append extension)
- Modify: `Sources/OpenPhotoCore/Catalog/Queries.swift` (append)
- Create: `Tests/OpenPhotoCoreTests/ForeignVaultSourceTests.swift` (starts here with these two helpers' tests; Task 3 appends)

- [ ] **Step 1: Write the failing tests**

`Tests/OpenPhotoCoreTests/ForeignVaultSourceTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// A fake FOREIGN drive in TestDirs: a real vault with seeded media, a written manifest,
/// and (optionally) a real catalog snapshot produced by the production writer.
func makeForeignDrive(_ t: TestDirs, withSnapshot: Bool) throws -> Vault {
    let root = try t.sub("their-drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    var entries: [ManifestEntry] = []
    for (rel, date) in [("rome2022/IMG_1.jpg", "2022:10:07 14:23:01"),
                        ("rome2022/IMG_2.jpg", "2022:10:07 14:23:02"),
                        ("family/IMG_3.jpg", "2022:10:07 14:23:03")] {
        let url = drive.absoluteURL(forRelativePath: rel)
        try makeJPEG(at: url.creatingParent(), dateTimeOriginal: date, lat: nil, lon: nil)
        let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        entries.append(ManifestEntry(hash: try ContentHash.ofFile(at: url), path: rel,
                                     size: size, mtime: "2022-10-07T14:23:01.000Z"))
    }
    try Manifest.write(entries, to: drive.manifestURL)
    if withSnapshot {
        // Production snapshot writer over a throwaway catalog seeded with the drive's assets.
        let cat = try Catalog(at: t.root.appendingPathComponent("their-cat.sqlite"))
        let assets = entries.enumerated().map { (i, e) in
            AssetRecord(hash: e.hash.stringValue, kind: "photo",
                        takenAtMs: 1_000_000 + Int64(i), pixelWidth: nil, pixelHeight: nil,
                        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
                        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
        }
        try cat.upsert(assets: assets)
        let thumbs = ThumbnailStore(cacheDir: try t.sub("their-thumbs"))
        try CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: drive)
    }
    return drive
}

@Test func assetDatesReadsSnapshotReadOnlyAndNilsWithout() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: true)
    let dates = CatalogSnapshot.assetDates(drive: drive)
    // NOTE: Manifest.write sorts by path — re-read order ≠ seed order. Look up by path.
    let entries = try Manifest.read(from: drive.manifestURL)
    let img1 = try #require(entries.first { $0.path == "rome2022/IMG_1.jpg" })
    #expect(dates?.count == 3)
    #expect(dates?[img1.hash.stringValue] == 1_000_000)   // seeded index 0 in makeForeignDrive

    let bare = try makeForeignDriveNoSnapshot(t)
    #expect(CatalogSnapshot.assetDates(drive: bare) == nil)
}

func makeForeignDriveNoSnapshot(_ t: TestDirs) throws -> Vault {
    let root = try t.sub("bare-drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    try Manifest.write([], to: drive.manifestURL)
    return drive
}

@Test func assetHashesReturnsEveryCataloguedHash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h1 = "sha256:" + String(repeating: "a", count: 64)
    let h2 = "sha256:" + String(repeating: "b", count: 64)
    try cat.upsert(assets: [h1, h2].map {
        AssetRecord(hash: $0, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
                    latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                    durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
                    favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    })
    #expect(try cat.assetHashes() == [h1, h2])
}
```

- [ ] **Step 2: Run — must FAIL to compile.** `swift test --filter ForeignVaultSourceTests 2>&1 | tail -5`

- [ ] **Step 3: Implement.**

Append to `CatalogSnapshot.swift`:

```swift
extension CatalogSnapshot {
    /// hash → takenAtMs from a drive's snapshot — the read-only fast path that lets a
    /// foreign drive's 10k items date-sort without touching 10k files. Reads ONLY the
    /// portable `assets` table per the documented snapshot-reader rules (catalog-schema.md);
    /// returns nil when the drive has no (readable) snapshot — callers fall back to
    /// manifest mtimes.
    public static func assetDates(drive: Vault) -> [String: Int64]? {
        let dbURL = drive.stateDirURL.appendingPathComponent(dirName)
            .appendingPathComponent("catalog.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var cfg = Configuration(); cfg.readonly = true
        guard let snap = try? DatabaseQueue(path: dbURL.path, configuration: cfg) else { return nil }
        return try? snap.read { db in
            var out: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT hash, takenAtMs FROM assets") {
                out[row["hash"]] = row["takenAtMs"]
            }
            return out
        }
    }
}
```

Append to `Queries.swift` (inside the `extension Catalog`):

```swift
    /// Every catalogued asset hash — the zero-I/O pre-flag for foreign-drive imports
    /// ("already in your library" from their manifest hashes, before any byte copies).
    public func assetHashes() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT hash FROM assets"))
        }
    }
```

- [ ] **Step 4: Run tests** — filter PASS, full `swift test`, both warning greps clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift Sources/OpenPhotoCore/Catalog/Queries.swift Tests/OpenPhotoCoreTests/ForeignVaultSourceTests.swift
git commit -m "feat: read-only snapshot dates + catalog hash set for foreign-drive pre-flagging

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `ForeignVaultSource` (Core, TDD)

**Files:**
- Create: `Sources/OpenPhotoCore/Import/ForeignVaultSource.swift`
- Modify: `Tests/OpenPhotoCoreTests/ForeignVaultSourceTests.swift` (append; reuses `makeForeignDrive`)

- [ ] **Step 1: Write the failing tests** (append):

```swift
@Test func foreignEnumerationComesFromManifestNotDiskWalk() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: true)
    // A file on disk but NOT in the manifest must not appear (manifest is the inventory)…
    try Data("stray".utf8).write(to: drive.absoluteURL(forRelativePath: "rome2022/stray.jpg"))
    let src = ForeignVaultSource(vault: drive, displayName: "Sam's drive")
    let items = try await src.enumerateItems()
    #expect(items.count == 3)
    #expect(!items.contains { $0.id == "rome2022/stray.jpg" })
    // …their manifest hash rides along for pre-flagging, dates come from the snapshot.
    // (Manifest re-read is path-sorted — match the entry by path, not index.)
    let entries = try Manifest.read(from: drive.manifestURL)
    let img1Entry = try #require(entries.first { $0.path == "rome2022/IMG_1.jpg" })
    let first = items.first { $0.id == "rome2022/IMG_1.jpg" }
    #expect(first?.knownHash == img1Entry.hash.stringValue)
    #expect(first?.takenAt == Date(timeIntervalSince1970: 1_000.000))   // takenAtMs 1_000_000 (seed idx 0)
    #expect(src.sourceKey == "foreign-" + drive.descriptor.vaultID)
}

@Test func foreignFolderCountsFetchSidecarAndReadOnlyDelete() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: false)
    let src = ForeignVaultSource(vault: drive, displayName: "Sam's drive")

    #expect(try src.folderCounts() == ["rome2022": 2, "family": 1])

    // Their sidecar bytes are exposed for the metadata-carry toggle.
    let mediaURL = drive.absoluteURL(forRelativePath: "family/IMG_3.jpg")
    let sc = drive.sidecarURL(forMediaAt: mediaURL)
    try FileManager.default.createDirectory(at: sc.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let xmp = Data(XMP.serialize(SidecarData(rating: 3, favorite: true, caption: nil,
                                             tags: ["beach"], faces: [])).utf8)
    try xmp.write(to: sc)
    let items = try await src.enumerateItems()
    let item3 = try #require(items.first { $0.id == "family/IMG_3.jpg" })
    #expect(src.sidecarData(for: item3) == xmp)
    #expect(src.sidecarData(for: items.first { $0.id == "rome2022/IMG_1.jpg" }!) == nil)

    // Fetch copies the bytes out; delete refuses (their drive is read-only).
    let out = t.root.appendingPathComponent("out.jpg")
    try await src.fetch(item3, to: out)
    #expect(FileManager.default.contentsEqual(atPath: out.path, andPath: mediaURL.path))
    let res = try await src.delete([item3])
    #expect(res.count == 1 && res[0].error != nil)
    #expect(FileManager.default.fileExists(atPath: mediaURL.path))
}

@Test func foreignDatesFallBackToManifestMtimeWithoutSnapshot() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: false)
    let src = ForeignVaultSource(vault: drive, displayName: "Sam's drive")
    let items = try await src.enumerateItems()
    #expect(items.allSatisfy { $0.takenAt == ISO8601Millis.dateLenient(from: "2022-10-07T14:23:01.000Z") })
}
```

- [ ] **Step 2: Run — must FAIL to compile.** `swift test --filter ForeignVaultSourceTests 2>&1 | tail -5`

- [ ] **Step 3: Implement.** `Sources/OpenPhotoCore/Import/ForeignVaultSource.swift`:

```swift
import Foundation
import ImageIO
import CoreGraphics

/// Read-only ImportSource over SOMEONE ELSE's OpenPhoto vault (a friend's canonical or
/// backup drive). Enumerates from the drive's documented formats — manifest.jsonl for the
/// inventory, the catalog snapshot (when present) for capture dates + thumbnails — so a
/// 10k-item drive lists without touching 10k files. Never writes to the drive (drives are
/// passive; this one isn't even ours).
public final class ForeignVaultSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let vault: Vault
    private let lock = NSLock()
    private var cachedEntries: [ManifestEntry]?
    private var cachedDates: [String: Int64]?    // hash → takenAtMs (snapshot fast path)

    public init(vault: Vault, displayName: String) {
        self.vault = vault
        self.displayName = displayName
        self.sourceKey = "foreign-" + vault.descriptor.vaultID
    }

    private func entries() throws -> [ManifestEntry] {
        lock.lock(); defer { lock.unlock() }
        if let cachedEntries { return cachedEntries }
        let e = try Manifest.read(from: vault.manifestURL)
        cachedEntries = e
        return e
    }

    private func snapshotDates() -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        if let cachedDates { return cachedDates }
        let d = CatalogSnapshot.assetDates(drive: vault) ?? [:]
        cachedDates = d
        return d
    }

    /// dirPath → direct media count, from the manifest alone (drives the folder panel).
    public func folderCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in try entries() where MediaKind.of(filename: e.path) != nil {
            counts[(e.path as NSString).deletingLastPathComponent, default: 0] += 1
        }
        return counts
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let dates = snapshotDates()
        var items: [ImportItem] = []
        for e in try entries() {
            guard let kind = MediaKind.of(filename: e.path) else { continue }
            let hash = e.hash.stringValue
            let taken: Date? = if let ms = dates[hash], ms != 0 {
                Date(timeIntervalSince1970: Double(ms) / 1000)
            } else {
                ISO8601Millis.dateLenient(from: e.mtime)
            }
            items.append(ImportItem(id: e.path, name: (e.path as NSString).lastPathComponent,
                                    byteSize: e.size, takenAt: taken, kind: kind,
                                    livePartnerID: nil, knownHash: hash))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        try FileManager.default.copyItem(at: vault.absoluteURL(forRelativePath: item.id), to: url)
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { DeleteResult(itemID: $0.id, error: "someone else's drive — read-only") }
    }

    /// Their `.openphoto/<name>.xmp` sidecar bytes for an item (metadata-carry toggle).
    public func sidecarData(for item: ImportItem) -> Data? {
        try? Data(contentsOf: vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: item.id)))
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        // Snapshot thumbnail first — no full-res decode off the drive.
        if let hash = item.knownHash {
            let thumbURL = vault.stateDirURL.appendingPathComponent(CatalogSnapshot.dirName)
                .appendingPathComponent(CatalogSnapshot.thumbRelPath(forHash: hash))
            if let src = CGImageSourceCreateWithURL(thumbURL as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return img
            }
        }
        let url = vault.absoluteURL(forRelativePath: item.id)
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

NOTE on the date test: the snapshot seeded `takenAtMs: 1_000_000 + i` → `Date(timeIntervalSince1970: 1_000.000)` for the first item. If `#expect(first?.takenAt == Date(timeIntervalSince1970: 1_000.000))` is flaky over Double equality, compare `timeIntervalSince1970` with `abs(... - 1000.0) < 0.001`.

- [ ] **Step 4: Run tests** — filter PASS; full `swift test`; both warning greps clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Import/ForeignVaultSource.swift Tests/OpenPhotoCoreTests/ForeignVaultSourceTests.swift
git commit -m "feat: ForeignVaultSource — read-only import from another person's OpenPhoto drive

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: VolumeSource — concurrent enumeration + progress + sidecar detection (Core, TDD)

**Files:**
- Modify: `Sources/OpenPhotoCore/Import/VolumeSource.swift`
- Create: `Tests/OpenPhotoCoreTests/VolumeEnumerationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func concurrentEnumerationMatchesSerialSemantics() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    // 40 JPEGs with EXIF dates (reverse order on disk), one video, one non-media file.
    for i in 0..<40 {
        try makeJPEG(at: root.appendingPathComponent("d\(i % 4)/IMG_\(i).jpg").creatingParent(),
                     dateTimeOriginal: String(format: "2022:10:07 14:%02d:%02d", i / 60, i % 60),
                     lat: nil, lon: nil)
    }
    try Data("v".utf8).write(to: root.appendingPathComponent("d0/MOV_1.mp4"))
    // Pin the video's mtime BELOW the photos' EXIF dates so the EXIF-driven sort is observable.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                          ofItemAtPath: root.appendingPathComponent("d0/MOV_1.mp4").path)
    try Data("x".utf8).write(to: root.appendingPathComponent("d0/notes.txt"))

    let src = VolumeSource(rootURL: root, displayName: "export")
    let progress = ProgressBox()
    src.enumerationProgress = { done, total in progress.append((done, total)) }
    let items = try await src.enumerateItems()

    #expect(items.count == 41)                                  // 40 photos + 1 video
    #expect(!items.contains { $0.name == "notes.txt" })
    // EXIF dates won (newest first): IMG_39 has the latest capture time; the
    // epoch-mtime video sorts last.
    #expect(items.first?.name == "IMG_39.jpg")
    #expect(items.last?.name == "MOV_1.mp4")
    // Progress reached completion over the candidate set.
    #expect(progress.values.last?.0 == progress.values.last?.1)
    #expect((progress.values.last?.1 ?? 0) > 0)
    #expect(src.sawXMPSidecars == false)
}

/// Thread-safe accumulator for the @Sendable progress callback.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [(Int, Int)] = []
    func append(_ p: (Int, Int)) { lock.lock(); v.append(p); lock.unlock() }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return v }
}

@Test func enumerationFlagsAdjacentXMPSidecars() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    try makeJPEG(at: root.appendingPathComponent("IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    try Data("<x/>".utf8).write(to: root.appendingPathComponent("IMG_1.xmp"))
    let src = VolumeSource(rootURL: root, displayName: "export")
    _ = try await src.enumerateItems()
    #expect(src.sawXMPSidecars == true)
    // The .xmp file itself never enumerates as media.
    #expect(!(try await src.enumerateItems()).contains { $0.name.hasSuffix(".xmp") })
}
```

- [ ] **Step 2: Run — must FAIL to compile** (`enumerationProgress`/`sawXMPSidecars` don't exist).

- [ ] **Step 3: Implement** — in `VolumeSource.swift`, add the two properties and replace `enumerateItems()`:

```swift
    /// Set BEFORE enumerateItems(); called as capture dates resolve (done, total).
    /// 10k files over USB would take minutes serially — the UI shows this as
    /// "Reading N of M…". Single-enumeration-at-a-time discipline (UI-driven).
    public var enumerationProgress: (@Sendable (Int, Int) -> Void)?
    /// True after enumerateItems() when any adjacent `.xmp` sidecar was seen — the
    /// import screen offers the "Include their metadata" fold only when relevant.
    public private(set) var sawXMPSidecars = false

    public func enumerateItems() async throws -> [ImportItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { return [] }
        // Pass 1 (fast): collect candidates — no per-file image reads.
        struct Candidate: Sendable {
            let url: URL; let rel: String; let kind: MediaKind
            let size: Int64; let mtime: Date?
        }
        var candidates: [Candidate] = []
        var sawXMP = false
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == ".openphoto-trash" { enumerator.skipDescendants() }
                continue
            }
            if url.pathExtension.lowercased() == "xmp" { sawXMP = true; continue }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            let resolvedURL = url.resolvingSymlinksInPath()
            let rootPath = rootURL.path  // rootURL is already resolved in init
            guard resolvedURL.path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(resolvedURL.path.dropFirst(rootPath.count + 1))
            candidates.append(Candidate(url: url, rel: rel, kind: kind,
                                        size: Int64(values?.fileSize ?? 0),
                                        mtime: values?.contentModificationDate))
        }
        sawXMPSidecars = sawXMP

        // Pass 2: EXIF capture dates with bounded concurrency (8 wide), order-stable.
        let urls = candidates.map(\.url)
        let kinds = candidates.map(\.kind)
        let total = candidates.count
        let progressCB = enumerationProgress
        let exifDates: [Date?] = await withTaskGroup(of: (Int, Date?).self,
                                                     returning: [Date?].self) { group in
            var result = [Date?](repeating: nil, count: urls.count)
            var done = 0
            var next = 0
            func addTask(_ i: Int) {
                group.addTask {
                    guard kinds[i] == .photo else { return (i, nil) }
                    return (i, Self.exifDate(of: urls[i]))
                }
            }
            while next < min(8, urls.count) { addTask(next); next += 1 }
            for await (i, d) in group {
                result[i] = d
                done += 1
                progressCB?(done, total)
                if next < urls.count { addTask(next); next += 1 }
            }
            return result
        }

        var items: [ImportItem] = []
        for (i, c) in candidates.enumerated() {
            items.append(ImportItem(id: c.rel, name: c.url.lastPathComponent,
                                    byteSize: c.size, takenAt: exifDates[i] ?? c.mtime,
                                    kind: c.kind, livePartnerID: nil))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    /// EXIF DateTimeOriginal via a cheap header read (no full decode).
    static func exifDate(of url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
```

(The old serial loop's inline EXIF block is replaced by `Self.exifDate`; delete the now-dead inline DateFormatter code from the old method body.)

- [ ] **Step 4: Run tests** — filter + full suite + warning greps. The pre-existing `VolumeSource`/SD-card tests must stay green (semantics unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Import/VolumeSource.swift Tests/OpenPhotoCoreTests/VolumeEnumerationTests.swift
git commit -m "perf: bounded-concurrency volume enumeration with progress; flag adjacent .xmp sidecars

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Apple-XMP fold on folder import (Core, TDD)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sidecar/XMP.swift` (add `parseTitle`)
- Modify: `Sources/OpenPhotoCore/Import/VolumeSource.swift` (fold in `fetch`)
- Create: `Tests/OpenPhotoCoreTests/AppleXMPFoldTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// Apple-Photos-style IPTC-as-XMP sidecar (generated; Apple's standard vocabulary —
/// dc:title as rdf:Alt, dc:description as rdf:Alt, dc:subject as rdf:Bag).
private func appleSidecarXML(title: String?, description: String?, keywords: [String]) -> String {
    var inner = ""
    if let title {
        inner += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)</rdf:li></rdf:Alt></dc:title>"
    }
    if let description {
        inner += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(description)</rdf:li></rdf:Alt></dc:description>"
    }
    if !keywords.isEmpty {
        let lis = keywords.map { "<rdf:li>\($0)</rdf:li>" }.joined()
        inner += "<dc:subject><rdf:Bag>\(lis)</rdf:Bag></dc:subject>"
    }
    return """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\(inner)</rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
}

@Test func parseTitleReadsDCTitleOnly() throws {
    let data = Data(appleSidecarXML(title: "Beach day", description: nil, keywords: []).utf8)
    #expect(XMP.parseTitle(data) == "Beach day")
    #expect(XMP.parseTitle(Data("<x/>".utf8)) == nil)
    // Our own sidecars (no dc:title) return nil.
    #expect(XMP.parseTitle(Data(XMP.serialize(.empty).utf8)) == nil)
}

@Test func fetchFoldsAppleSidecarWhenToggledOn() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    try makeJPEG(at: root.appendingPathComponent("IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    // Apple's ext-REPLACED naming: IMG_1.jpg → IMG_1.xmp.
    try Data(appleSidecarXML(title: "Beach day", description: "Sunset with Sam",
                             keywords: ["beach", "sam"]).utf8)
        .write(to: root.appendingPathComponent("IMG_1.xmp"))

    let src = VolumeSource(rootURL: root, displayName: "export")
    let item = try #require(try await src.enumerateItems().first)

    // Toggle OFF (default): plain copy, nothing embedded.
    let off = t.root.appendingPathComponent("off.jpg")
    try await src.fetch(item, to: off)
    #expect(EmbeddedMetadata.read(from: off) == nil
            || EmbeddedMetadata.read(from: off) == SidecarData.empty)

    // Toggle ON: description → caption, keywords → tags, folded into the copy.
    src.foldXMPSidecars = true
    let on = t.root.appendingPathComponent("on.jpg")
    try await src.fetch(item, to: on)
    let sd = try #require(EmbeddedMetadata.read(from: on))
    #expect(sd.caption == "Sunset with Sam")
    #expect(Set(sd.tags) == ["beach", "sam"])
    // The original export file is untouched (source is read-only).
    #expect(EmbeddedMetadata.read(from: root.appendingPathComponent("IMG_1.jpg")) == nil
            || EmbeddedMetadata.read(from: root.appendingPathComponent("IMG_1.jpg")) == SidecarData.empty)
}

@Test func fetchFoldUsesTitleWhenNoDescriptionAndAppendedNaming() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    try makeJPEG(at: root.appendingPathComponent("IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:02", lat: nil, lon: nil)
    // Appended naming variant: IMG_2.jpg.xmp.
    try Data(appleSidecarXML(title: "Just a title", description: nil, keywords: []).utf8)
        .write(to: root.appendingPathComponent("IMG_2.jpg.xmp"))
    let src = VolumeSource(rootURL: root, displayName: "export")
    src.foldXMPSidecars = true
    let item = try #require(try await src.enumerateItems().first)
    let out = t.root.appendingPathComponent("out.jpg")
    try await src.fetch(item, to: out)
    #expect(EmbeddedMetadata.read(from: out)?.caption == "Just a title")
}
```

- [ ] **Step 2: Run — must FAIL to compile** (`parseTitle`/`foldXMPSidecars` don't exist).

- [ ] **Step 3: Implement.**

Append inside `enum XMP` (XMP.swift):

```swift
    /// dc:title (Apple Photos' "Title" in IPTC-as-XMP exports). Our own sidecars never
    /// write it — used only as a caption fallback when folding foreign sidecars.
    public static func parseTitle(_ data: Data) -> String? {
        guard let doc = try? XMLDocument(data: data),
              let s = try? doc.nodes(forXPath:
                  "//*[local-name()='title']//*[local-name()='li']").first?.stringValue,
              !s.isEmpty else { return nil }
        return s
    }
```

In `VolumeSource.swift`, add the toggle + sidecar locator, and extend `fetch`:

```swift
    /// UI toggle ("Include their metadata"): fold an adjacent Apple-export `.xmp`
    /// sidecar (Export Unmodified Originals + "IPTC as XMP") into each fetched photo —
    /// Takeout-style, before hashing — so their captions/keywords survive the crossing.
    /// Default off; the sidecar itself is never copied in.
    public var foldXMPSidecars = false

    /// IMG_1.HEIC → IMG_1.xmp (Apple's ext-replaced form) or IMG_1.HEIC.xmp (appended).
    static func xmpSidecarURL(forMedia url: URL) -> URL? {
        let replaced = url.deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: replaced.path) { return replaced }
        let appended = url.appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: appended.path) { return appended }
        return nil
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        let src = rootURL.appendingPathComponent(item.id)
        try FileManager.default.copyItem(at: src, to: url)
        guard foldXMPSidecars, item.kind == .photo,
              let sidecarURL = Self.xmpSidecarURL(forMedia: src),
              let data = try? Data(contentsOf: sidecarURL) else { return }
        var sd = (try? XMP.parse(data)) ?? .empty
        if sd.caption == nil, let title = XMP.parseTitle(data) { sd.caption = title }
        sd.faces = []   // face regions are not carried by the fold
        guard sd != .empty else { return }
        try? EmbeddedMetadata.embed(sd, exifDate: nil, latitude: nil, longitude: nil,
                                    intoImageAt: url)
    }
```

(This REPLACES the existing one-line `fetch`; the copyItem line is preserved as the first statement.)

- [ ] **Step 4: Run tests** — filter + full suite + warning greps clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sidecar/XMP.swift Sources/OpenPhotoCore/Import/VolumeSource.swift Tests/OpenPhotoCoreTests/AppleXMPFoldTests.swift
git commit -m "feat: fold Apple-export XMP sidecars into folder imports (opt-in, Takeout-style)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: DeviceWatcher + AppState — foreign drives surface automatically (App, build-verified)

**Files:**
- Modify: `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift`
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: `ConnectedDevice` gains the case** (extend every switch in the enum):

```swift
    case foreignVault(id: String, name: String, url: URL)
```

- `id`: `case .foreignVault(let id, _, _): "foreign-\(id)"`
- `name`: `case .foreignVault(_, let n, _): n`
- `symbol`: `case .foreignVault: "externaldrive.badge.person.crop"`
- `supportsDeviceDelete`: add `.foreignVault` to the `return false` arm (their drive is read-only).

- [ ] **Step 2: Detection in `volumesChanged()`** — replace the per-URL loop body with:

```swift
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRemovable == true else { continue }
            // Someone ELSE's OpenPhoto drive → a read-only import source. Our own
            // registered drives never land here (their IDs are known); adoption stays
            // behind the explicit Add Drive flow.
            if let vault = (try? Vault.open(at: url)) ?? nil,
               !knownVaultIDs().contains(vault.descriptor.vaultID) {
                vols.append(.foreignVault(id: vault.descriptor.vaultID,
                                          name: v.volumeName ?? url.lastPathComponent,
                                          url: url))
                continue
            }
            guard FileManager.default.fileExists(
                      atPath: url.appendingPathComponent("DCIM").path) else { continue }
            vols.append(.volume(id: v.volumeUUIDString ?? url.path,
                                name: v.volumeName ?? url.lastPathComponent, url: url))
        }
```

Add the provider property near the other AppState-set closures:

```swift
    /// Set by AppState: every vault ID that is OURS (local source vaults + registered
    /// durable drives). A mounted vault with an unknown ID is someone else's → foreign.
    var knownVaultIDs: () -> Set<String> = { [] }
```

(Swift 6 isolation: DeviceWatcher is `@MainActor`, and the closure is only called from `volumesChanged()` (MainActor) while AppState's assignment captures MainActor state — if strict concurrency complains about the closure type, declare it `@MainActor () -> Set<String>`, matching how the file's other AppState-set callbacks behave.)

NOTE (accepted small deviation from spec §7): a foreign drive whose `format_version` is NEWER than ours makes `Vault.open` throw; with `try?` the volume silently doesn't surface as a foreign source. The polite error surface remains the explicit Add Drive panel (existing behavior). Document nothing further; the final reviewer should treat this as intended.

In the `kept` filter, add `case .foreignVault: return false` (re-detected on every mount change, like real volumes).

- [ ] **Step 3: `source(for:)` arm:**

```swift
        case .foreignVault(_, let name, let url):
            made = ((try? Vault.open(at: url)) ?? nil)
                .map { ForeignVaultSource(vault: $0, displayName: name) }
```

- [ ] **Step 4: AppState wiring.** Where AppState assigns `deviceWatcher.openedDeviceRemoved` / `onVolumesChanged` (grep `onVolumesChanged =` in AppState.swift), add:

```swift
        deviceWatcher.knownVaultIDs = { [weak self] in
            guard let self else { return [] }
            var ids = Set(self.library?.vaults.map(\.descriptor.vaultID) ?? [])
            ids.formUnion(self.durableVaults.map(\.id))
            return ids
        }
```

In `sendDestination(for:)`, extend the import-only arm:

```swift
        case .photosLibrary, .takeout, .foreignVault:
            return nil   // import-only sources — never send/free-up targets
```

(If any other `switch device` over `ConnectedDevice` fails to compile after the new case — e.g. in SidebarView — handle `.foreignVault` like `.takeout`: an import source row; ejecting/unmounting removes it via `volumesChanged`.)

- [ ] **Step 5: Build-verify.** `swift build 2>&1 | tail -3` → Build complete; both warning greps empty; `swift test 2>&1 | tail -3` → all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp/Devices/DeviceWatcher.swift Sources/OpenPhotoApp/AppState.swift
git commit -m "feat: foreign OpenPhoto drives auto-surface as read-only import sources

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

(Include any other App file the new enum case forced you to touch.)

---

### Task 7: ImportView — folder panel, metadata toggle, progress, wiring (App, build-verified)

**Files:**
- Modify: `Sources/OpenPhotoApp/Devices/ImportView.swift`

- [ ] **Step 1: State** (after `@State private var inLibraryCache = Set<String>()`):

```swift
    // Foreign-vault folder selection + the shared "Include their metadata" toggle.
    @State private var checkedFolders = Set<String>()
    @State private var foreignFolderCounts: [String: Int] = [:]
    @State private var carryMetadata = false
    @State private var enumProgress: (done: Int, total: Int)?
```

- [ ] **Step 2: Enumeration progress.** In `connect()`, right after `source = src`:

```swift
        if let vol = src as? VolumeSource {
            vol.enumerationProgress = { done, total in
                Task { @MainActor in enumProgress = (done, total) }
            }
        }
```

And make the `.connecting` case show it:

```swift
        case .connecting:
            ContentUnavailableView {
                Label("Connecting…", systemImage: "cable.connector")
            } description: {
                if let p = enumProgress {
                    Text("Reading \(p.done) of \(p.total)…")
                }
            }
            .frame(maxHeight: .infinity)
```

In `reloadItems()`, after `items = …`:

```swift
        enumProgress = nil
        if let foreign = source as? ForeignVaultSource {
            foreignFolderCounts = (try? foreign.folderCounts()) ?? [:]
            checkedFolders = []
        }
```

- [ ] **Step 3: Folder panel + filtered display.** Replace `displayItems` and add helpers:

```swift
    // NOTE: `source` is Optional — `source is ForeignVaultSource` would always be false;
    // `as?` flattens through the optional correctly.
    private var isForeign: Bool { (source as? ForeignVaultSource) != nil }

    /// Foreign vault: only items inside a checked folder (subtree-inclusive) display.
    private var displayItems: [ImportItem] {
        let base = items.filter { !($0.kind == .video && $0.livePartnerID != nil) }
        guard isForeign else { return base }
        return base.filter { item in
            let dir = (item.id as NSString).deletingLastPathComponent
            return checkedFolders.contains { dir == $0 || dir.hasPrefix($0 + "/") }
        }
    }

    /// Their folders, sorted; checking a folder includes its whole subtree.
    private var foreignFolderList: [String] { foreignFolderCounts.keys.sorted() }

    private var folderPanel: some View {
        List {
            ForEach(foreignFolderList, id: \.self) { path in
                Toggle(isOn: Binding(
                    get: { checkedFolders.contains(path) },
                    set: { on in
                        if on { checkedFolders.insert(path) }
                        else { checkedFolders.remove(path) }
                        selection.clear()
                    })) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                        Text(path.isEmpty ? "(root)" : path).font(.system(size: 12))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(foreignFolderCounts[path] ?? 0)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 230)
    }
```

In `content`'s `.ready, .importing` case, wrap the grid for foreign sources:

```swift
        case .ready, .importing:
            HStack(spacing: 0) {
                if isForeign {
                    folderPanel
                    Divider().overlay(Theme.hairline)
                }
                importGrid
            }
```

(`importGrid` = the existing `ScrollView { LazyVGrid … } .coordinateSpace … .modifier(RubberBandModifier …)` block extracted verbatim into a `private var importGrid: some View`.)

- [ ] **Step 4: Metadata toggle in the footer** (before `destinationPicker` in the `default:` arm):

```swift
                if isForeign || (source as? VolumeSource)?.sawXMPSidecars == true {
                    Toggle("Include their metadata", isOn: $carryMetadata)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help(isForeign
                              ? "Copy their captions, ratings, tags and favorites (their .openphoto sidecars) alongside the imported photos."
                              : "Fold the exported .xmp sidecars (captions, keywords) into the imported files.")
                }
```

- [ ] **Step 5: `runBatch()` wiring.** Replace the engine call with:

```swift
        let foreign = source as? ForeignVaultSource
        if let vol = source as? VolumeSource { vol.foldXMPSidecars = carryMetadata }
        let carry = carryMetadata
        let result = await engine.run(
            source: source, items: batchItems, vault: vault, dirPath: destination,
            subdirForItem: foreign != nil
                ? { item in (item.id as NSString).deletingLastPathComponent }
                : nil,
            postPlace: (foreign != nil && carry)
                ? { placed in
                    // Carry their sidecar (their human metadata) for the placed copy —
                    // collision-renamed names included; the engine rescans right after.
                    guard let data = foreign?.sidecarData(for: placed.item) else { return }
                    let mediaURL = vault.absoluteURL(forRelativePath: placed.placedRelPath)
                    try? AtomicFile.write(data, to: vault.sidecarURL(forMediaAt: mediaURL))
                }
                : nil) { p in
            Task { @MainActor in phase = .importing(done: p.done, total: p.total) }
        }
```

- [ ] **Step 6: knownHash pre-flag.** In `rebuildInLibraryCache()`, after the fingerprint loop:

```swift
        // Foreign drives: exact-hash pre-flag from their manifest — zero I/O.
        if items.contains(where: { $0.knownHash != nil }),
           let hashes = try? state.library?.catalog.assetHashes() {
            for item in items {
                if let kh = item.knownHash, hashes.contains(kh) { cache.insert(item.id) }
            }
        }
```

- [ ] **Step 7: Build-verify + bundle.** `swift build` clean, both warning greps empty, `swift test` all pass, `./scripts/make-app.sh 2>&1 | tail -2` → bundle rebuilt.

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenPhotoApp/Devices/ImportView.swift
git commit -m "feat: import screen — foreign-drive folder panel, metadata toggle, 10k enumeration progress

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Docs (master spec)

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1:** §10.5 Phase 5.5 block: mark item 2 ("Import from other people's libraries") **DONE** by prepending `**DONE (2026-06-12).** ` to its text (items 3 undo-stack and 4 tile-grid stay).

- [ ] **Step 2:** Find the backlog item about importing from other people's libraries (grep `other people's`): tag it `[Phase 5.5 — DONE 2026-06-12]` and prepend `**Shipped 2026-06-12** (spec: \`2026-06-12-foreign-imports-design.md\`) — ` to its body.

- [ ] **Step 3:** Add a changelog entry beside the other 2026-06-12 entries:

```markdown
- **2026-06-12** — **Foreign imports shipped (Phase 5.5 slice 2)** — importing from libraries that aren't yours. **(A) Foreign OpenPhoto drives:** a mounted volume carrying an unknown vault auto-surfaces as a read-only import source (`ForeignVaultSource`); enumeration comes from the drive's *documented* formats (manifest.jsonl inventory; catalog-snapshot dates + thumbnails read with the documented reader rules — OpenPhoto as its own first third-party snapshot implementor); their manifest hashes pre-flag "already in your library" with zero I/O; a folder panel picks their folders, which land with structure intact under a chosen parent (engine gained per-item subdirs); an "Include their metadata" toggle (default OFF) copies their `.openphoto` sidecars alongside (post-place hook, before the rescan). Adoption-as-my-drive is untouched. **(B) Friend's Apple Photos:** documented export workflow (Export Unmodified Originals + IPTC-as-XMP; transport via external drive / Thunderbolt-Bridge share / Wi-Fi share); folder import now enumerates 10k-class exports with bounded-concurrency EXIF reads + progress, and the same metadata toggle folds the exported `.xmp` sidecars into the copies (Takeout-style, before hashing). No format change; schemaVersion stays 11. Spec: `2026-06-12-foreign-imports-design.md`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: mark foreign imports shipped in master spec (§10.5 + changelog)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

1. `swift test 2>&1 | tail -3` → all pass (expect ~355+).
2. `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → empty.
3. Whole-slice review subagent vs the spec.
4. Merge `phase5.5-foreign-imports` → `main` with `--no-ff` using a message FILE (`-F /tmp/file`, NEVER `-F -`), push origin main, delete branch. (User pre-approved.)

Live acceptance (Jude, post-merge): the real friend import (10k export cull) and, when available, a real foreign OpenPhoto drive.
