# Phase 3 Slice 5d — Quick View (ephemeral, trace-free drive peek) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plug in a drive — or point at any folder — and browse it *without adopting it*: a sandboxed, ephemeral peek that writes nothing to the drive and nothing persistent on the Mac. On Done / eject / quit, it's gone.

**Architecture:** Two read-only backends behind one `PeekSource.load(root:tempDir:)` returning a `PeekContext` (items + a throwaway `ThumbnailStore` + the temp dir). A snapshot-carrying OpenPhoto drive is read instantly via `CatalogSnapshot.import` into a temp `Catalog`; a raw folder is enumerated lazily (path-derived synthetic thumb hashes, thumbnails generated on scroll). A self-contained App surface (`PeekGridCell` / `PeekView` / `PeekViewer`) presents it as a main-window takeover keyed on `AppState.peekContext`. Teardown deletes the temp dir.

**Tech Stack:** Swift 6 / SwiftUI / SwiftPM (Command Line Tools, no Xcode), GRDB SQLite catalog, Swift Testing, AVKit. Builds on 5a (drive full-res), 5b (`CatalogSnapshot.import`), the `ThumbView` async pattern, and the `ZoomableImageView` CALayer viewer.

**Branch:** `phase3-drives` (the FINAL Phase 3 slice; after it the branch merges to `main` — noted in T5, NOT performed here).

---

## Hard rules for every task (do not violate)

- **Generated mock media only.** NEVER access `~/Pictures`, `~/Movies`, or any personal folder. All test/fixture media is created with `makeJPEG`/`makeMOV` under `TestDirs` (system temp), and drive vaults via `Vault.openOrCreate` + `CatalogSnapshot.write`.
- **Read-only on the drive; nothing persisted on the Mac.** The raw backend MUST NOT call `Vault.openOrCreate` on the folder (that writes a `vault.json`). Only the snapshot backend opens a `Vault`, and only because `vault.json` already exists there. All peek state lives under one temp dir, deleted on teardown. The live catalog and live thumbnail cache are never touched.
- **Do NOT modify** `VerifiedCopy`, `Manifest`, the `SyncEngine` copy/verify spine, the send destinations, or the `CatalogSnapshot`/`Catalog`/`Vault` Core internals. You may only **call** `CatalogSnapshot.import`. No catalog migration, no on-disk format change (a peek writes nothing).
- **All peek I/O off-main** (the `PeekSource.load` runs in a detached task from `AppState`).
- **UI strings:** use `\u{...}` escapes or ASCII for typographic characters (`\u{201c}`/`\u{201d}` curly quotes, `\u{00b7}` middle dot, `\u{2026}` ellipsis, `\u{2019}` apostrophe). NEVER paste raw multibyte characters — they double-encode.
- **0 compiler warnings:** `swift build 2>&1 | grep -i warning` must be empty.
- Each task commits with the EXACT message given, ending with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OpenPhotoCore/Sync/PeekSource.swift` | **Create.** `PeekItem`, `PeekContext` models + `PeekSource` (the two read-only backends + shared media walk). | T1 |
| `Tests/OpenPhotoCoreTests/PeekSourceTests.swift` | **Create.** Unit tests for `mediaFiles`, raw load, snapshot load, synthetic-hash determinism. | T1 |
| `Sources/OpenPhotoApp/Peek/PeekView.swift` | **Create.** `PeekGridCell` + `PeekView` + `PeekViewer` (self-contained peek surface). | T2 |
| `Sources/OpenPhotoApp/Viewer/ViewerView.swift` | **Modify.** Make `ZoomableImageView` internal (drop `private`) so `PeekViewer` reuses it. | T2 |
| `Sources/OpenPhotoApp/AppState.swift` | **Modify.** `peekContext` state + `startQuickView`/`endQuickView`/`quickViewFolderViaPanel` + eject-mid-peek teardown. | T3, T4 |
| `Sources/OpenPhotoApp/OpenPhotoApp.swift` | **Modify.** `RootView.detail` peek takeover + "Quick View Folder…" File-menu command. | T3, T4 |
| `Sources/OpenPhotoApp/Drives/DrivesView.swift` | **Modify.** Drive-row "Quick View" button, "Quick View Folder…" toolbar button, Adopt/**Quick View**/Not-now prompt option. | T4 |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` | **Modify.** §10 Phase 3 (5d done) + changelog; Phase 3 COMPLETE → next: merge. | T5 |

---

## Task 1: Core — `PeekItem`/`PeekContext` models + `PeekSource` (TDD)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/PeekSource.swift`
- Test: `Tests/OpenPhotoCoreTests/PeekSourceTests.swift`

**Context for the implementer:** This is the read-only Core spine of Quick View. `MediaKind.of(filename:)` returns `nil` for hidden/non-media files. `Vault.stateDirName == ".openphoto"`. `Catalog(at:)` creates a fresh SQLite catalog; `ThumbnailStore(cacheDir:)` is a thumbnail cache rooted at a dir. `CatalogSnapshot.import(from: Vault, into: Catalog, thumbnails: ThumbnailStore) -> AdoptionImport` (from 5b) reads a drive's `catalog-snapshot/` into the given catalog + copies that drive's cached thumbs into the given store. `Catalog.timelineItems() -> [TimelineItem]` returns browseable rows (`hash`, `kind: String`, `relPath`, `driveRelPath: String?`, …). `Vault.absoluteURL(forRelativePath:)` resolves a drive-relative path to a file URL. `ContentHash(stringValue:)` wraps a `"sha256:…"` string. The snapshot fixture pattern (drive vault + manifest + presence + cached thumb + `CatalogSnapshot.write`) lives in `Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift` — mirror it inline (its `snapshotFixture` is `private` to that file).

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/PeekSourceTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

// MARK: - mediaFiles(under:)

@Test func mediaFilesReturnsOnlyMediaAndSkipsStateDir() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let a = try t.sub("a"), b = try t.sub("b")
    try makeJPEG(at: a.appendingPathComponent("x.jpg"), dateTimeOriginal: nil, lat: nil, lon: nil)
    try await Task { try await makeMOV(at: b.appendingPathComponent("y.mov")) }.value
    // A .openphoto/ dir with a stray jpg inside — must be skipped wholesale.
    let state = try t.sub(".openphoto")
    try makeJPEG(at: state.appendingPathComponent("stray.jpg"), dateTimeOriginal: nil, lat: nil, lon: nil)
    // A non-media file — must be skipped.
    try Data("hi".utf8).write(to: t.root.appendingPathComponent("notes.txt"))

    let urls = PeekSource.mediaFiles(under: t.root)
    let names = urls.map(\.lastPathComponent).sorted()
    #expect(names == ["x.jpg", "y.mov"])
    #expect(!urls.contains { $0.path.contains("/.openphoto/") })
}

// MARK: - raw load (no snapshot)

@Test func loadRawFolderBuildsOneItemPerMediaFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.sub("src")
    let jpg = src.appendingPathComponent("p.jpg")
    try makeJPEG(at: jpg, dateTimeOriginal: nil, lat: nil, lon: nil)
    let jpg2 = src.appendingPathComponent("q.jpg")
    try makeJPEG(at: jpg2, dateTimeOriginal: nil, lat: nil, lon: nil)
    let tmp = t.root.appendingPathComponent("peek-tmp")

    let ctx = try PeekSource.load(root: src, tempDir: tmp)

    #expect(ctx.items.count == 2)
    #expect(ctx.root == src)
    #expect(Set(ctx.items.map(\.sourceURL.lastPathComponent)) == ["p.jpg", "q.jpg"])
    #expect(ctx.items.allSatisfy { $0.kind == .photo })
    // Distinct synthetic thumb hashes (path-derived).
    #expect(Set(ctx.items.map(\.thumbHash.stringValue)).count == 2)
    // The throwaway thumbnail cache lives under tempDir.
    for item in ctx.items {
        #expect(ctx.thumbnails.cacheURL(for: item.thumbHash).path.hasPrefix(tmp.path))
    }
}

// MARK: - snapshot load

/// Build a canonical drive carrying a catalog-snapshot (manifest + presence + a cached thumb), as in
/// CatalogSnapshotTests. Returns (driveRoot, driveHash).
private func snapshotDrive(_ t: TestDirs) throws -> (URL, String) {
    let catalog = try Catalog(at: t.root.appendingPathComponent("seed.sqlite"))
    let thumbs = ThumbnailStore(cacheDir: try t.sub("seed-thumbs"))
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let driveHash = "sha256:" + String(repeating: "a", count: 64)
    try catalog.upsert(assets: [AssetRecord(hash: driveHash, kind: "photo", takenAtMs: 1,
        pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: driveHash),
        path: "Pictures/rome/IMG_1.jpg", size: 3, mtime: "2022-10-07T14:23:01.000Z")],
        to: drive.manifestURL)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    let u = thumbs.cacheURL(for: ContentHash(stringValue: driveHash))
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("jpg".utf8).write(to: u)
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)
    return (drive.rootURL, driveHash)
}

@Test func loadSnapshotDriveReadsIndexIntoTempCatalog() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (driveRoot, driveHash) = try snapshotDrive(t)
    let tmp = t.root.appendingPathComponent("peek-tmp")

    let ctx = try PeekSource.load(root: driveRoot, tempDir: tmp)

    #expect(ctx.items.count == 1)
    let item = try #require(ctx.items.first)
    #expect(item.thumbHash.stringValue == driveHash)           // real asset hash, not synthetic
    #expect(item.sourceURL.path.contains("Pictures/rome/IMG_1.jpg"))   // full-res from the drive
    // The load built its OWN temp catalog under tempDir (nothing written to any live catalog).
    #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("catalog.sqlite").path))
    #expect(ctx.thumbnails.cacheURL(for: item.thumbHash).path.hasPrefix(tmp.path))
}

// MARK: - synthetic hash

@Test func syntheticHashIsDeterministicAndPerPath() throws {
    let h1 = PeekSource.syntheticHash(forPath: "/a/b/c.jpg")
    let h2 = PeekSource.syntheticHash(forPath: "/a/b/c.jpg")
    let h3 = PeekSource.syntheticHash(forPath: "/a/b/d.jpg")
    #expect(h1 == h2)
    #expect(h1 != h3)
    #expect(h1.stringValue.hasPrefix("sha256:"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter mediaFilesReturnsOnlyMediaAndSkipsStateDir 2>&1 | tail -20`
Expected: FAIL to compile — `PeekSource` / `PeekItem` / `PeekContext` are not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/OpenPhotoCore/Sync/PeekSource.swift`:

```swift
import Foundation
import CryptoKit

/// One peekable photo/video, backend-agnostic (snapshot drive OR raw folder).
public struct PeekItem: Sendable, Identifiable, Equatable {
    public var id: String          // stable identity (the source file path / drive-relative path)
    public var name: String        // filename, for display
    public var kind: MediaKind
    public var sourceURL: URL      // the file on the drive/folder — thumbnail source AND full-res
    public var thumbHash: ContentHash  // real asset hash (snapshot) or a path-derived synthetic (raw)

    public init(id: String, name: String, kind: MediaKind, sourceURL: URL, thumbHash: ContentHash) {
        self.id = id; self.name = name; self.kind = kind
        self.sourceURL = sourceURL; self.thumbHash = thumbHash
    }
}

/// A loaded, ephemeral peek: the items + a THROWAWAY thumbnail cache, all under `tempDir`.
public struct PeekContext: Sendable {
    public var sourceName: String              // drive/folder display name (the banner)
    public var items: [PeekItem]
    public var thumbnails: ThumbnailStore      // temp cache (cacheDir under tempDir)
    public var tempDir: URL                    // deleted wholesale on teardown
    public var root: URL                       // the peeked drive/folder (for eject-mid-peek detection)

    public init(sourceName: String, items: [PeekItem], thumbnails: ThumbnailStore,
                tempDir: URL, root: URL) {
        self.sourceName = sourceName; self.items = items
        self.thumbnails = thumbnails; self.tempDir = tempDir; self.root = root
    }
}

/// The two read-only backends behind one loader.
public enum PeekSource {
    /// Build a peek for `root` into a fresh `tempDir`. If `root` carries a catalog-snapshot it's read
    /// instantly (snapshot backend); otherwise its media files are enumerated (raw backend). Reads
    /// only — never writes to `root`.
    public static func load(root: URL, tempDir: URL) throws -> PeekContext {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let thumbs = ThumbnailStore(cacheDir: tempDir.appendingPathComponent("thumbs"))

        let snapshotDB = root.appendingPathComponent(Vault.stateDirName)
            .appendingPathComponent("catalog-snapshot")
            .appendingPathComponent("catalog.sqlite")

        if fm.fileExists(atPath: snapshotDB.path) {
            // SNAPSHOT backend. vault.json already exists for an OpenPhoto drive, so openOrCreate
            // only READS it — it never writes to the drive here.
            let drive = try Vault.openOrCreate(at: root, role: .canonical)
            let cat = try Catalog(at: tempDir.appendingPathComponent("catalog.sqlite"))
            _ = try CatalogSnapshot.import(from: drive, into: cat, thumbnails: thumbs)
            let items = try cat.timelineItems()
                .filter { $0.driveRelPath != nil }
                .map { row in
                    PeekItem(id: row.driveRelPath!,
                             name: (row.relPath as NSString).lastPathComponent,
                             kind: MediaKind(rawValue: row.kind) ?? .photo,
                             sourceURL: drive.absoluteURL(forRelativePath: row.driveRelPath!),
                             thumbHash: ContentHash(stringValue: row.hash))
                }
            return PeekContext(sourceName: root.lastPathComponent, items: items,
                               thumbnails: thumbs, tempDir: tempDir, root: root)
        }

        // RAW backend — read-only media walk; NEVER openOrCreate a raw folder.
        let items = mediaFiles(under: root).map { url in
            PeekItem(id: url.path,
                     name: url.lastPathComponent,
                     kind: MediaKind.of(filename: url.lastPathComponent) ?? .photo,
                     sourceURL: url,
                     thumbHash: syntheticHash(forPath: url.path))
        }
        return PeekContext(sourceName: root.lastPathComponent, items: items,
                           thumbnails: thumbs, tempDir: tempDir, root: root)
    }

    /// Recursive, read-only walk of media files under `root` (skips `.openphoto/`, hidden files, and
    /// non-media). Sorted by path for a stable order.
    public static func mediaFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.lastPathComponent == Vault.stateDirName { en.skipDescendants(); continue }
            if MediaKind.of(filename: url.lastPathComponent) != nil { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A path-derived `ContentHash` (SHA-256 of the path STRING, not the file bytes — instant, stable,
    /// filename-safe) used to key a raw item's throwaway thumbnail cache.
    public static func syntheticHash(forPath path: String) -> ContentHash {
        let digest = SHA256.hash(data: Data(path.utf8))
        return ContentHash(stringValue: "sha256:" + digest.map { String(format: "%02x", $0) }.joined())
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter mediaFilesReturnsOnlyMediaAndSkipsStateDir --filter loadRawFolderBuildsOneItemPerMediaFile --filter loadSnapshotDriveReadsIndexIntoTempCatalog --filter syntheticHashIsDeterministicAndPerPath 2>&1 | tail -25`
Expected: PASS (4 tests). Then confirm 0 warnings: `swift build 2>&1 | grep -i warning` → empty.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/PeekSource.swift Tests/OpenPhotoCoreTests/PeekSourceTests.swift
git commit -m "$(cat <<'EOF'
feat: PeekSource — read-only snapshot+raw backends for Quick View

PeekItem/PeekContext models + PeekSource.load(root:tempDir:) (snapshot drive →
CatalogSnapshot.import into a temp Catalog; raw folder → lazy media walk with
path-derived synthetic thumb hashes) + mediaFiles(under:). Read-only on the
source; all state under a throwaway tempDir.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: App — `PeekGridCell` + `PeekView` + `PeekViewer`

**Files:**
- Create: `Sources/OpenPhotoApp/Peek/PeekView.swift`
- Modify: `Sources/OpenPhotoApp/Viewer/ViewerView.swift:219` (make `ZoomableImageView` internal)

**Context for the implementer:** The peek surface is self-contained — it reads only its `PeekContext` (no `AppState`, no `LibraryService`). `PeekGridCell` mirrors `ThumbView`'s async pattern (`Sources/OpenPhotoApp/Timeline/ThumbView.swift`): a file-private `NSCache` of decoded `CGImage`s read synchronously for instant recycled-cell display, refreshed in a `.task(id:)` off a `Task.detached`. `PeekViewer` mirrors `ViewerView`'s `loadFull` (read `Data(contentsOf:)` off a detached task, build `NSImage` on the main actor) and reuses `ZoomableImageView` (the CALayer zoom/pan view at the bottom of `ViewerView.swift`). `Theme` provides `.tile`, `.toolbarHeight`, `.textDim`, `.hairline`. There are NO unit tests for views — this task is **build-verified**.

- [ ] **Step 1: Make `ZoomableImageView` reusable**

In `Sources/OpenPhotoApp/Viewer/ViewerView.swift`, change the declaration (around line 219) from:

```swift
private struct ZoomableImageView: NSViewRepresentable {
```

to (drop `private` so `PeekViewer` in another file can reuse it):

```swift
struct ZoomableImageView: NSViewRepresentable {
```

(Leave everything else in that struct and `ZoomPanLayerView` unchanged.)

- [ ] **Step 2: Create the peek surface**

Create `Sources/OpenPhotoApp/Peek/PeekView.swift`:

```swift
import SwiftUI
import AVKit
import OpenPhotoCore

/// Thread-safe box so CGImage (a CF type) can live in NSCache<NSString, AnyObject>.
private final class PeekImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

nonisolated(unsafe) private let peekMemoryCache: NSCache<NSString, PeekImageBox> = {
    let c = NSCache<NSString, PeekImageBox>()
    c.countLimit = 2000
    return c
}()

/// One peek thumbnail. Mirrors ThumbView: synchronous cache read for instant recycled-cell display,
/// async refresh off a detached task. A snapshot item's real hash hits the imported cache; a raw
/// item's synthetic hash misses → generated from the file once.
struct PeekGridCell: View {
    let item: PeekItem
    let thumbnails: ThumbnailStore
    var targetPixel: Int = ThumbnailStore.maxPixel
    @State private var asyncImage: CGImage?

    private var cacheKey: NSString { "\(item.id)@\(targetPixel)" as NSString }

    var body: some View {
        let cached = peekMemoryCache.object(forKey: cacheKey)?.image ?? asyncImage
        ZStack {
            Theme.tile
            if let cached {
                Image(decorative: cached, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: cacheKey) {
            let key = cacheKey
            if let hit = peekMemoryCache.object(forKey: key)?.image { asyncImage = hit; return }
            let store = thumbnails, it = item, px = targetPixel
            let result: CGImage? = await Task.detached(priority: .userInitiated) {
                if let img = try? await store.displayImage(
                    for: it.thumbHash, sourceURL: it.sourceURL, kind: it.kind, maxPixel: px) {
                    return img
                }
                return await store.cachedDisplayImage(for: it.thumbHash, maxPixel: px)
            }.value
            if let img = result {
                peekMemoryCache.setObject(PeekImageBox(img), forKey: key)
                asyncImage = img
            }
        }
    }
}

/// The main-window-takeover peek surface: a labeled banner + a grid + an in-place full-screen viewer.
struct PeekView: View {
    let context: PeekContext
    let onDone: () -> Void

    @State private var openedPeek: PeekItem?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 2)]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Viewing \u{201c}\(context.sourceName)\u{201d}")
                        .font(.system(size: 15, weight: .semibold))
                    Text("temporary \u{00b7} not added to your library")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Done") { onDone() }.controlSize(.small)
                }
                .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
                Divider().overlay(Theme.hairline)

                if context.items.isEmpty {
                    ContentUnavailableView("No photos here", systemImage: "photo.on.rectangle")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(context.items) { item in
                                PeekGridCell(item: item, thumbnails: context.thumbnails)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { openedPeek = item }
                            }
                        }
                        .padding(2)
                    }
                }
            }
            if let opened = openedPeek {
                PeekViewer(items: context.items, initial: opened) { openedPeek = nil }
            }
        }
    }
}

/// A self-contained full-screen viewer for a peek (NOT AppState-coupled). Full-res is read from the
/// source file; reuses ZoomableImageView. Arrow keys navigate, esc closes.
private struct PeekViewer: View {
    let items: [PeekItem]
    let onClose: () -> Void

    @State private var current: PeekItem
    @State private var fullImage: NSImage?
    @State private var player: AVPlayer?
    @State private var loadFailed = false
    @FocusState private var focused: Bool

    init(items: [PeekItem], initial: PeekItem, onClose: @escaping () -> Void) {
        self.items = items
        self.onClose = onClose
        _current = State(initialValue: initial)
    }

    private var index: Int? { items.firstIndex(of: current) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text(current.name).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 44)

            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.96))
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .task(id: current.id) { await loadFull() }
    }

    @ViewBuilder private var content: some View {
        if current.kind == .video {
            if let player { VideoPlayer(player: player) }
        } else if let fullImage {
            ZoomableImageView(image: fullImage).id(current.id)
        } else if loadFailed {
            Label("Full-res isn\u{2019}t available", systemImage: "externaldrive.badge.xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        current = items[j]
    }

    private func loadFull() async {
        fullImage = nil; player = nil; loadFailed = false
        if current.kind == .video {
            player = AVPlayer(url: current.sourceURL)
            return
        }
        let url = current.sourceURL
        // NSImage isn't Sendable; load raw Data in the detached task, build on the main actor.
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        if let data, let img = NSImage(data: data) { fullImage = img } else { loadFailed = true }
    }
}
```

- [ ] **Step 3: Build-verify (0 warnings)**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds, no `error:`/`warning:` lines. Confirm: `swift build 2>&1 | grep -i 'warning\|error'` → empty.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Peek/PeekView.swift Sources/OpenPhotoApp/Viewer/ViewerView.swift
git commit -m "$(cat <<'EOF'
feat: Quick View surface — PeekGridCell + PeekView + PeekViewer

Self-contained peek UI reading only a PeekContext: a labeled "Viewing ..." banner
+ a lazy thumbnail grid (ThumbView async pattern over the throwaway store) + an
in-place full-screen PeekViewer (full-res from the source file, reusing the
CALayer ZoomableImageView, now internal). View-only: no inspector, selection, or
library actions.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: App — `AppState.peekContext` lifecycle + `RootView` takeover

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (add `peekContext` + `startQuickView`/`endQuickView`; eject-mid-peek check in the `onVolumesChanged` closure ~line 707)
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift:74` (`RootView.detail` peek branch)

**Context for the implementer:** `AppState` is a `@MainActor @Observable` class. `PeekContext` (T1) now carries `root: URL`. The peek loads off-main in a detached task, then the result is assigned on the main actor. The app already reacts to volume mount/unmount in the `deviceWatcher.onVolumesChanged = { [weak self] in Task { @MainActor in … } }` closure — that's where eject-mid-peek teardown belongs (a real volume vanishing makes `ctx.root` no longer exist on disk). `RootView.detail` is a `@ViewBuilder` that swaps on `state.openedDevice`; the peek takes priority over it. The temp dir is created under `FileManager.default.temporaryDirectory`.

- [ ] **Step 1: Add the peek state + lifecycle to `AppState`**

In `Sources/OpenPhotoApp/AppState.swift`, add a stored property near the other UI state (e.g. next to `var openedDevice`):

```swift
    /// Non-nil while a Quick View peek is open. Ephemeral — its tempDir is deleted on teardown.
    var peekContext: PeekContext?
```

Then add these methods (place them near `addImportSourceViaPanel`):

```swift
    /// Start an ephemeral, trace-free peek of `root` (a drive or any folder). Loads off-main into a
    /// throwaway temp dir; nothing is written to `root` or persisted on the Mac.
    func startQuickView(root: URL) async {
        endQuickView()   // tear down any prior peek first (single peekContext)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPhotoPeek-" + UUID().uuidString)
        let ctx = await Task.detached(priority: .userInitiated) {
            try? PeekSource.load(root: root, tempDir: tmp)
        }.value
        if let ctx {
            peekContext = ctx
        } else {
            try? FileManager.default.removeItem(at: tmp)
            driveAlert("Couldn\u{2019}t open Quick View",
                       "\u{201c}\(root.lastPathComponent)\u{201d} couldn\u{2019}t be read.")
        }
    }

    /// End the current peek and delete its temp dir (idempotent).
    func endQuickView() {
        guard let ctx = peekContext else { return }
        peekContext = nil
        try? FileManager.default.removeItem(at: ctx.tempDir)
    }
```

(`driveAlert(_:_:)` already exists in `AppState` — it's used by `ejectDrive`.)

- [ ] **Step 2: Tear down the peek when the peeked drive ejects mid-peek**

In `Sources/OpenPhotoApp/AppState.swift`, find the `deviceWatcher.onVolumesChanged` closure (~line 707):

```swift
            deviceWatcher.onVolumesChanged = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reloadDrives()
                    await self.autoScanConnectedDrives()
                }
            }
```

Add the eject-mid-peek check after `self.reloadDrives()`:

```swift
            deviceWatcher.onVolumesChanged = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reloadDrives()
                    // A peeked drive that vanished (ejected/unplugged) → close the peek. Nothing was
                    // persisted, so this just discards the throwaway temp dir.
                    if let ctx = self.peekContext,
                       !FileManager.default.fileExists(atPath: ctx.root.path) {
                        self.endQuickView()
                    }
                    await self.autoScanConnectedDrives()
                }
            }
```

- [ ] **Step 3: Present the peek as a `RootView.detail` takeover**

In `Sources/OpenPhotoApp/OpenPhotoApp.swift`, change `RootView.detail` (line 74) to give the peek top priority:

```swift
    @ViewBuilder private var detail: some View {
        if let ctx = state.peekContext {
            PeekView(context: ctx) { state.endQuickView() }
        } else if let device = state.openedDevice {
            ImportView(state: state, device: device)
        } else {
            switch state.selection {
            case .timeline: TimelineView(state: state)
            case .folders: FoldersView(state: state)
            case .drives: DrivesView(state: state)
            case .bin: BinView(state: state)
            }
        }
    }
```

- [ ] **Step 4: Build-verify (0 warnings)**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds. Confirm: `swift build 2>&1 | grep -i 'warning\|error'` → empty.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "$(cat <<'EOF'
feat: Quick View lifecycle — peekContext + RootView takeover

AppState.startQuickView(root:) loads a peek off-main into a throwaway temp dir;
endQuickView() clears it and deletes the temp dir. The onVolumesChanged closure
closes a peek whose drive ejected mid-view. RootView.detail shows PeekView as a
top-priority takeover (sidebar stays).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: App — entry points (Drives row, "Quick View Folder…", Adopt prompt)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (`quickViewFolderViaPanel`)
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift` (row button + toolbar button + adopt-prompt option)
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift` (File-menu command)

**Context for the implementer:** Three entry points. (a) A "Quick View" button on a connected drive row (`DrivesView.row`, the HStack near the existing "Verify Integrity" button, gated on `present`). (b) A "Quick View Folder…" path: an `AppState.quickViewFolderViaPanel()` running an `NSOpenPanel` (mirror `addImportSourceViaPanel`), wired to a toolbar button next to "Add Drive…" AND a File-menu command. (c) The 5b adoption prompt (`adoptTarget` alert in `DrivesView`, ~line 44) gains a third button "Quick View". `VaultRecord.rootPath` is a `String`. This task is **build-verified + manual**; rebuild the app bundle at the end.

- [ ] **Step 1: Add `quickViewFolderViaPanel` to `AppState`**

In `Sources/OpenPhotoApp/AppState.swift`, near `addImportSourceViaPanel`:

```swift
    /// Prompt for a folder/drive and Quick View it (the raw-folder entry point). Shared by the Drives
    /// toolbar button and the File-menu command.
    func quickViewFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Quick View"
        panel.message = "Choose a folder or drive to browse without adding it to your library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await startQuickView(root: url) }
    }
```

- [ ] **Step 2: Add the drive-row "Quick View" button**

In `Sources/OpenPhotoApp/Drives/DrivesView.swift`, in `row(_:)`, add a button after the existing "Verify Integrity" button (before `driveMenu(vr)`):

```swift
            Button("Quick View") {
                Task { await state.startQuickView(root: URL(fileURLWithPath: vr.rootPath)) }
            }.controlSize(.small).disabled(!present)
```

- [ ] **Step 3: Add the "Quick View Folder…" toolbar button**

In `Sources/OpenPhotoApp/Drives/DrivesView.swift`, in `mainContent`, next to the existing "Add Drive…" button:

```swift
                Button("Add Drive\u{2026}") { state.addDriveViaPanel() }.controlSize(.small)
                Button("Quick View Folder\u{2026}") { state.quickViewFolderViaPanel() }.controlSize(.small)
```

- [ ] **Step 4: Add the "Quick View Folder…" File-menu command**

In `Sources/OpenPhotoApp/OpenPhotoApp.swift`, in the `CommandGroup(after: .newItem)` block, add after the existing "Open Folder as Import Source…" button:

```swift
            CommandGroup(after: .newItem) {
                Button("Open Folder as Import Source…") {
                    MainActor.assumeIsolated { state.addImportSourceViaPanel() }
                }
                Button("Quick View Folder\u{2026}") {
                    MainActor.assumeIsolated { state.quickViewFolderViaPanel() }
                }
            }
```

- [ ] **Step 5: Add the "Quick View" option to the adoption prompt**

In `Sources/OpenPhotoApp/Drives/DrivesView.swift`, in the `adoptTarget` alert (~line 51), add a "Quick View" button between "Adopt" and "Not now":

```swift
                   presenting: adoptTarget) { vr in
                Button("Adopt") {
                    let vaultRecord = vr
                    adoptTarget = nil
                    Task { await state.adoptDrive(vaultRecord) }
                }
                Button("Quick View") {
                    let root = URL(fileURLWithPath: vr.rootPath)
                    adoptTarget = nil
                    Task { await state.startQuickView(root: root) }
                }
                Button("Not now", role: .cancel) {
                    adoptDismissed.insert(vr.id)
                    adoptTarget = nil
                }
            } message: { _ in
```

- [ ] **Step 6: Build-verify (0 warnings) + rebuild the bundle**

Run: `swift build 2>&1 | tail -20` → succeeds, no warnings.
Confirm: `swift build 2>&1 | grep -i 'warning\|error'` → empty.
Then rebuild the app bundle for manual testing:
Run: `./scripts/make-app.sh 2>&1 | tail -5`
Expected: `build/OpenPhoto.app` rebuilt.

**Manual test checklist (the user runs these):**
- Drives panel → a connected snapshot drive's "Quick View" → instant labeled grid; tap → full-res from the drive; arrows navigate; esc/Done discards.
- "Quick View Folder…" (toolbar + File menu) → pick a raw folder of photos → thumbnails generate as you scroll; full-res opens.
- Unknown-drive prompt → "Quick View" peeks before committing.
- Eject the drive mid-peek → the peek closes cleanly.
- After any peek: the live timeline / Drives / catalog are unchanged (no new presence, no thumbs in the live cache).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Drives/DrivesView.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "$(cat <<'EOF'
feat: Quick View entry points — drive row, folder panel, adopt prompt

A "Quick View" button on connected drive rows; a "Quick View Folder..." toolbar
button + File-menu command (quickViewFolderViaPanel, the raw-folder entry); and a
third "Quick View" option on the unknown-drive adoption prompt (peek before
committing). Rebuilt the app bundle.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Docs — master spec §10 + changelog (Phase 3 complete)

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md` (§10 Phase 3 line for 5d + a dated changelog entry)

**Context for the implementer:** No code, no on-disk format change (a peek writes nothing). Update the Phase 3 slice-status in §10 to mark 5d done ("Quick View implemented"), and add a `2026-06-10` changelog entry. State that **Phase 3 (Drives) is now COMPLETE** and the next step is merging `phase3-drives` → `main` — but DO NOT perform the merge (it's user-gated).

- [ ] **Step 1: Read the relevant sections**

Run: `grep -n "Slice 5d\|Quick View\|## Changelog\|Phase 3" docs/superpowers/specs/2026-06-07-openphoto-design.md | head -30`
Read §10's Phase 3 slice list and the top of the Changelog to match the existing formatting.

- [ ] **Step 2: Mark 5d done in §10**

Update the Phase 3 Slice 5d line so it reads as implemented — condense its sub-bullet to a one-line "implemented" summary, e.g.:

```markdown
  - **Slice 5d — Quick View (DONE):** ephemeral, trace-free peek of a drive or any folder, without adopting. Two read-only backends behind one `PeekItem`/`PeekContext` (`PeekSource.load`): a snapshot drive is read into a throwaway temp `Catalog` via `CatalogSnapshot.import`; a raw folder is lazy-walked with path-derived synthetic thumb hashes. Main-window-takeover `PeekView` (banner + grid + self-contained full-screen `PeekViewer`). Nothing written to the drive; nothing persisted on the Mac (temp dir discarded on Done/eject). Entry points: Drives-row "Quick View", "Quick View Folder…" (toolbar + File menu), and the Adopt/Quick View/Not-now prompt.
```

(Match the surrounding bullet style; adjust the exact wording to fit.)

- [ ] **Step 3: Add the changelog entry**

Add a dated entry at the top of the changelog (matching the existing entry format):

```markdown
### 2026-06-10 — Slice 5d (Quick View): ephemeral, trace-free drive/folder peek

Browse a drive or any folder without adopting it. Two read-only backends behind one
`PeekSource.load(root:tempDir:)`: a snapshot-carrying OpenPhoto drive is read instantly into a
throwaway temp `Catalog` (`CatalogSnapshot.import`, thumbnails from the snapshot cache); a raw
folder / non-OpenPhoto drive is lazy-walked (`mediaFiles(under:)`) with path-derived synthetic
thumb hashes (thumbnails generated on scroll). One `PeekItem`/`PeekContext` model serves both. The
App surface is a main-window takeover (`AppState.peekContext` → `PeekView`): a labeled "Viewing …
— temporary · not added to your library" banner, a lazy thumbnail grid, and a self-contained
full-screen `PeekViewer` (full-res from the source file, reusing `ZoomableImageView`). Invariants:
read-only on the drive (the raw backend NEVER `openOrCreate`s a folder — that would write a
`vault.json`); nothing persisted on the Mac (all peek state under one temp dir, deleted on
Done/eject/quit). Entry points: a Drives-row "Quick View" button, a "Quick View Folder…" toolbar
button + File-menu command, and a third "Quick View" option on the 5b unknown-drive adoption prompt.

**Phase 3 (Drives) is now COMPLETE.** Next step: merge `phase3-drives` → `main` (user-gated — not
performed here).
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "$(cat <<'EOF'
docs: Slice 5d (Quick View) implemented — Phase 3 complete

Master-spec §10 marks Slice 5d done and a 2026-06-10 changelog entry records the
ephemeral trace-free peek (snapshot + raw backends behind one PeekItem; main-window
takeover; read-only on the drive, nothing persisted on the Mac). Phase 3 (Drives)
is feature-complete; next step is merging phase3-drives -> main (user-gated).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## After all tasks

- [ ] Dispatch a final whole-slice code review (all of T1–T4) covering: the read-only invariant (no writes to the drive; raw backend never `openOrCreate`s), trace-free teardown (temp dir always deleted, no live-catalog/live-cache writes), the `ThumbView`-pattern fidelity in `PeekGridCell`, and eject-mid-peek correctness.
- [ ] Confirm full suite green: `swift test 2>&1 | tail -15` and `swift build 2>&1 | grep -i 'warning\|error'` empty.
- [ ] **Do NOT merge.** Phase 3 is complete; the `phase3-drives` → `main` merge is user-gated. Report completion and wait for the user's explicit go-ahead before running `superpowers:finishing-a-development-branch`.

---

## Self-Review (completed)

- **Spec coverage:** §3.1 models → T1. §3.2 `PeekSource` two backends + `mediaFiles` → T1. §3.3 `PeekGridCell`/`PeekView`/`PeekViewer` → T2. §3.4 `AppState.peekContext` + `startQuickView`/`endQuickView` + `RootView` takeover + eject teardown → T3. §3.5 entry points (Drives row, "Quick View Folder…", Adopt/Quick View/Not-now) → T4. §6 testing → T1 tests (1–4) + T4 manual checklist. §7 task decomposition → T1–T5. Docs discipline (no format change) → T5.
- **Placeholder scan:** none — every code step contains complete code; every run step has an expected result.
- **Type consistency:** `PeekItem.kind` is `MediaKind` (enum) throughout; `TimelineItem.kind` is `String` (mapped via `MediaKind(rawValue:)` in T1). `PeekContext` carries `root: URL` from T1, consumed by the eject check in T3. `PeekSource.syntheticHash(forPath:)` is `public static` (called from the T1 test). `ThumbnailStore.displayImage(for:sourceURL:kind:maxPixel:)` / `cachedDisplayImage(for:maxPixel:)` / `cacheURL(for:)` / `maxPixel` match the Core signatures. `ZoomableImageView` made internal in T2 so `PeekViewer` reuses it.
