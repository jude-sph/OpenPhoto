# Metadata interop + Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose OpenPhoto's human metadata to other tools — a one-way XMP **sidecar export** to a chosen folder, an **opt-in two-way Finder-tag sync** (3-way merge), and a small **Settings** window (sync opt-in + GeoNames attribution).

**Architecture:** Pure Core primitives (`TagMerge`, `FinderTags`, `SidecarExporter`) + a `finder_tag_sync` baseline table (catalog migration v11) + `LibraryService.reconcileFinderTags`; the App gates Finder sync behind a persisted opt-in and adds a native `Settings` scene. XMP sidecars stay authoritative; the library is never written by export; Finder xattrs are written only when opted in (non-destructive — content hash unchanged).

**Tech Stack:** Swift 6 · SwiftUI · SwiftPM **Command Line Tools only** (`swift build` / `swift test`, **NO Xcode**) · GRDB · Foundation `URLResourceValues.tagNames` · macOS 15.

---

## Hard rules (every task)

- **Toolchain:** `swift build` / `swift test` only. Never Xcode.
- **Zero warnings:** after each task, `swift build 2>&1 | grep -i warning` **and** `swift build --build-tests 2>&1 | grep -i warning` must both be empty.
- **TDD for Core** (Tasks 1–3: failing test first). **Build-verified for App** (Tasks 4–5).
- **No real user data.** All test files are generated (`makeJPEG`, raw `Data`) in `TestDirs` temp dirs. Never read `~/Pictures`/`~/Movies` or any personal folder. (Finder-tag tests write/read tags on a temp file — system temp is APFS, which supports tags.)
- **`finder_tag_sync` is a rebuildable catalog cache (migration v11). No sidecar/`vault-format-v1` change.**
- **CRITICAL — documentation discipline:** the `schemaVersion` 10→11 bump lands in drive snapshots, so `docs/format/catalog-schema.md` **MUST** be updated to Version 11 (the `finder_tag_sync` table) **in the same commit as the migration (Task 2)**. (This is the lesson from the near-dup v10 review.)
- **Commit** each task with the EXACT message in the task, ending with:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Do NOT modify** `XMP`, `SidecarStore`, `AtomicFile`, `Scanner`, `SyncEngine`, the `delete` path, or `updateMetadata` (the inspector's save just routes its tags through a new `tagsForSave`).

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OpenPhotoCore/Interop/TagMerge.swift` (create) | Pure 3-way set merge. | 1 |
| `Sources/OpenPhotoCore/Interop/FinderTags.swift` (create) | Read/write a file's Finder tags. | 1 |
| `Tests/OpenPhotoCoreTests/TagMergeTests.swift` (create) | Merge + Finder round-trip tests. | 1 |
| `Sources/OpenPhotoCore/Catalog/Catalog.swift` (modify) | Migration v11 + `schemaVersion` 10→11. | 2 |
| `Sources/OpenPhotoCore/Catalog/Catalog+FinderTags.swift` (create) | Baseline get/set. | 2 |
| `Sources/OpenPhotoCore/LibraryService.swift` (modify) | `reconcileFinderTags`. | 2 |
| `docs/format/catalog-schema.md` (modify) | `finder_tag_sync` (v11) — **same commit**. | 2 |
| `Tests/OpenPhotoCoreTests/FinderSyncTests.swift` (create) | Baseline + reconcile tests. | 2 |
| `Sources/OpenPhotoCore/Interop/SidecarExporter.swift` (create) | Export mirror tree of XMP. | 3 |
| `Tests/OpenPhotoCoreTests/SidecarExporterTests.swift` (create) | Export tests. | 3 |
| `Sources/OpenPhotoApp/AppState.swift` (modify) | opt-in + `tagsForSave` + `syncFinderTagsNow` + `exportSidecars`. | 4 |
| `Sources/OpenPhotoApp/Inspector/InspectorView.swift` (modify) | Route save tags through `tagsForSave`. | 4 |
| `Sources/OpenPhotoApp/OpenPhotoApp.swift` (modify) | Export File-menu command + `Settings` scene. | 4,5 |
| `Sources/OpenPhotoApp/Settings/SettingsView.swift` (create) | The Settings window. | 5 |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` (modify) | §10.5 DONE + changelog. | 6 |

---

### Task 1: `TagMerge` + `FinderTags`

**Files:** Create `Sources/OpenPhotoCore/Interop/TagMerge.swift`, `Sources/OpenPhotoCore/Interop/FinderTags.swift`, `Tests/OpenPhotoCoreTests/TagMergeTests.swift`.

- [ ] **Step 1: Write the failing tests** — `Tests/OpenPhotoCoreTests/TagMergeTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func tagMergeAddOnOneSidePropagates() {
    #expect(TagMerge.merge(baseline: ["a"], openphoto: ["a", "b"], finder: ["a"]) == ["a", "b"])
}
@Test func tagMergeRemoveOnOneSidePropagates() {
    #expect(TagMerge.merge(baseline: ["a", "b"], openphoto: ["a", "b"], finder: ["a"]) == ["a"])
}
@Test func tagMergeAddAndRemoveOppositeSides() {
    // baseline {a,b}; OpenPhoto added c; Finder removed a → {b,c}
    #expect(TagMerge.merge(baseline: ["a", "b"], openphoto: ["a", "b", "c"], finder: ["b"]) == ["b", "c"])
}
@Test func tagMergeEmptyBaselineIsAdditive() {
    #expect(TagMerge.merge(baseline: [], openphoto: ["a"], finder: ["b"]) == ["a", "b"])
}
@Test func tagMergeNoOpWhenAllEqual() {
    #expect(TagMerge.merge(baseline: ["a"], openphoto: ["a"], finder: ["a"]) == ["a"])
}

@Test func finderTagsRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let f = t.root.appendingPathComponent("x.txt")
    try Data("x".utf8).write(to: f)
    #expect(FinderTags.read(f) == [])
    try FinderTags.write(["beach", "summer"], to: f)
    #expect(Set(FinderTags.read(f)) == ["beach", "summer"])
    try FinderTags.write(["beach"], to: f)                 // removal overwrite
    #expect(FinderTags.read(f) == ["beach"])
    try FinderTags.write([], to: f)                        // clear
    #expect(FinderTags.read(f) == [])
}
```

- [ ] **Step 2: Run, confirm fail** — `swift test --filter "tagMerge|finderTags" 2>&1 | tail -5` → "cannot find 'TagMerge'".

- [ ] **Step 3: Create `Sources/OpenPhotoCore/Interop/TagMerge.swift`:**

```swift
import Foundation

/// 3-way set merge for two-way tag sync. A tag survives iff it wasn't removed on either side; a tag is
/// added iff it appeared on either side relative to the baseline. `removed` and `added` never overlap
/// (a tag can't be both in-baseline-and-removed and not-in-baseline-and-added), so the result is
/// unambiguous — no conflicts to resolve. Pure + unit-tested.
public enum TagMerge {
    public static func merge(baseline: Set<String>, openphoto: Set<String>, finder: Set<String>) -> Set<String> {
        let removed = baseline.subtracting(openphoto).union(baseline.subtracting(finder))
        let added   = openphoto.subtracting(baseline).union(finder.subtracting(baseline))
        return baseline.subtracting(removed).union(added)
    }
}
```

- [ ] **Step 4: Create `Sources/OpenPhotoCore/Interop/FinderTags.swift`:**

```swift
import Foundation

/// Read/write a file's macOS Finder tags (the `com.apple.metadata:_kMDItemUserTags` xattr) via
/// Foundation's `URLResourceValues.tagNames` — plain label strings (Finder tag *colours* are not
/// represented here and are out of scope). Non-destructive: tags live in the resource fork, so the
/// data fork (and the content hash) is unchanged.
public enum FinderTags {
    public static func read(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    public static func write(_ tags: [String], to url: URL) throws {
        var u = url
        var values = URLResourceValues()
        values.tagNames = tags
        try u.setResourceValues(values)
    }
}
```

- [ ] **Step 5: Run + clean build** — `swift test --filter "tagMerge|finderTags" 2>&1 | tail -8` → all pass. Both warning greps empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Interop/TagMerge.swift Sources/OpenPhotoCore/Interop/FinderTags.swift Tests/OpenPhotoCoreTests/TagMergeTests.swift
git commit -m "$(cat <<'EOF'
feat(interop): pure 3-way TagMerge + FinderTags read/write

TagMerge.merge(baseline, openphoto, finder) — conflict-free two-way tag reconciliation.
FinderTags read/write a file's macOS Finder tags via URLResourceValues.tagNames (label strings;
colours out of scope; non-destructive). TDD: merge cases + a real temp-file Finder round-trip.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `finder_tag_sync` table (migration v11) + `reconcileFinderTags`

**Files:** Modify `Catalog.swift`, `LibraryService.swift`, `docs/format/catalog-schema.md`; create `Catalog+FinderTags.swift`, `Tests/OpenPhotoCoreTests/FinderSyncTests.swift`.

- [ ] **Step 1: Write the failing tests** — `Tests/OpenPhotoCoreTests/FinderSyncTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func schemaIsV11() { #expect(Catalog.schemaVersion == 11) }

@Test func finderTagBaselineRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    #expect(try cat.finderTagBaseline(forHash: "h") == [])
    try cat.setFinderTagBaseline(hash: "h", tags: ["a", "b"])
    #expect(Set(try cat.finderTagBaseline(forHash: "h")) == ["a", "b"])
    try cat.setFinderTagBaseline(hash: "h", tags: ["a"])      // replace
    #expect(try cat.finderTagBaseline(forHash: "h") == ["a"])
}

@Test func reconcileFinderTagsMergesWritesAndBaselines() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    let media = pics.appendingPathComponent("rome/IMG.jpg").creatingParent()
    try makeJPEG(at: media, dateTimeOriginal: nil, lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    try await lib.scanAll()
    let h = try lib.catalog.timelineItems().first { $0.relPath == "rome/IMG.jpg" }!.hash
    // baseline {a,b}; Finder has {b} (a removed in Finder); OpenPhoto proposes {a,b,c} (c added) → {b,c}
    try lib.catalog.setFinderTagBaseline(hash: h, tags: ["a", "b"])
    try FinderTags.write(["b"], to: media)
    let merged = try lib.reconcileFinderTags(forHash: h, proposedTags: ["a", "b", "c"])
    #expect(Set(merged) == ["b", "c"])
    #expect(Set(FinderTags.read(media)) == ["b", "c"])                          // written to the file
    #expect(Set(try lib.catalog.finderTagBaseline(forHash: h)) == ["b", "c"])   // baseline updated
}

@Test func reconcileFinderTagsDriveOnlyReturnsProposedAndWritesNothing() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    let h = "sha256:" + String(repeating: "z", count: 64)   // no local instance for this hash
    #expect(try lib.reconcileFinderTags(forHash: h, proposedTags: ["x"]) == ["x"])
    #expect(try lib.catalog.finderTagBaseline(forHash: h) == [])   // nothing stored
}
```

- [ ] **Step 2: Run, confirm fail** — `swift test --filter "schemaIsV11|finderTag|reconcileFinderTags" 2>&1 | tail -6`.

- [ ] **Step 3: Migration v11 + bump `schemaVersion`** in `Catalog.swift`. Change `public static let schemaVersion = 10` → `= 11`. Insert AFTER the `registerMigration("v10")` block and BEFORE `try migrator.migrate(dbQueue)`:

```swift
        migrator.registerMigration("v11") { db in
            // Per-photo last-synced tag set — the 3-way-merge baseline for Finder-tag sync. Rebuildable
            // sync-state, machine-derived. Catalog-only: NO sidecar, NO format change. Dropping it makes
            // the next sync additive for one cycle, then re-seeds.
            try db.create(table: "finder_tag_sync") { t in
                t.primaryKey("hash", .text)             // → assets.hash
                t.column("baseline", .text).notNull()   // JSON array of tag strings
            }
        }
```

- [ ] **Step 4: Create `Sources/OpenPhotoCore/Catalog/Catalog+FinderTags.swift`:**

```swift
import Foundation
import GRDB

extension Catalog {
    /// Store (replace) the last-synced Finder/OpenPhoto tag set for an asset (the merge baseline).
    public func setFinderTagBaseline(hash: String, tags: [String]) throws {
        let json = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO finder_tag_sync (hash, baseline) VALUES (?, ?)",
                           arguments: [hash, json])
        }
    }
    /// The stored baseline tag set for an asset (`[]` if never synced).
    public func finderTagBaseline(forHash hash: String) throws -> [String] {
        try dbQueue.read { db in
            guard let json = try String.fetchOne(db,
                sql: "SELECT baseline FROM finder_tag_sync WHERE hash = ?", arguments: [hash]) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
    }
}
```

- [ ] **Step 5: Add `reconcileFinderTags`** to `LibraryService.swift` (near `updateMetadata`):

```swift
    /// Reconcile an asset's tags with macOS Finder tags on its local files via a 3-way merge against the
    /// stored baseline. Reads the UNION of all local instance files' Finder tags, merges with
    /// `proposedTags` + the baseline, writes the merged set to EVERY local file, and stores the new
    /// baseline. Returns the merged set (the caller persists it to the XMP sidecar + catalog). A
    /// drive-only asset (no reachable local file) returns `proposedTags` unchanged and writes nothing.
    public func reconcileFinderTags(forHash hash: String, proposedTags: [String]) throws -> [String] {
        let urls: [URL] = ((try? catalog.instances(forHash: hash)) ?? []).compactMap { inst in
            guard let v = vault(id: inst.vaultID) else { return nil }
            let u = v.absoluteURL(forRelativePath: inst.relPath)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard !urls.isEmpty else { return proposedTags }    // drive-only: no Finder write
        let finder = Set(urls.flatMap { FinderTags.read($0) })
        let baseline = Set((try? catalog.finderTagBaseline(forHash: hash)) ?? [])
        let merged = TagMerge.merge(baseline: baseline, openphoto: Set(proposedTags), finder: finder)
        let mergedArr = merged.sorted()
        for u in urls { try? FinderTags.write(mergedArr, to: u) }
        try? catalog.setFinderTagBaseline(hash: hash, tags: mergedArr)
        return mergedArr
    }
```
> `vault(id:)`, `catalog.instances(forHash:)`, and `Vault.absoluteURL(forRelativePath:)` already exist.

- [ ] **Step 6: Update `docs/format/catalog-schema.md` (SAME COMMIT — mandatory).** READ the file first to learn its house style (it documents `phash` v10, `geocode` v9, etc., each with a table block + a reader rule). Then: bump the title/version line to **Version 11**; update the "`Catalog.schemaVersion` is N" line to **11**; add a `finder_tag_sync` table subsection (columns `hash` TEXT PK → `assets.hash`, `baseline` TEXT NOT NULL = a JSON array of the last-synced tag strings) described as a **rebuildable, machine-derived, droppable sync-state cache** (catalog-only; no sidecar/vault-format change); add a reader rule mirroring the others (a third-party reader MAY ignore it; it's Mac-local Finder-sync state, not part of the portable record).

- [ ] **Step 7: Run + clean build** — `swift test --filter "schemaIsV11|finderTag|reconcileFinderTags" 2>&1 | tail -8` → all pass. `swift test 2>&1 | tail -3` → full suite green. Both warning greps empty.

- [ ] **Step 8: Commit** (note: includes the schema doc)

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift Sources/OpenPhotoCore/Catalog/Catalog+FinderTags.swift Sources/OpenPhotoCore/LibraryService.swift docs/format/catalog-schema.md Tests/OpenPhotoCoreTests/FinderSyncTests.swift
git commit -m "$(cat <<'EOF'
feat(interop): finder_tag_sync baseline (migration v11) + reconcileFinderTags

A rebuildable `finder_tag_sync` table (catalog migration v11, schemaVersion 10->11) holds the
per-photo last-synced tag set (the 3-way-merge baseline). LibraryService.reconcileFinderTags reads
the union of an asset's local files' Finder tags, merges against the baseline + proposed tags,
writes the merged set to every local file, and re-baselines; drive-only assets are a no-op.
catalog-schema.md bumped to Version 11 in the same commit (the version lands in drive snapshots).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `SidecarExporter`

**Files:** Create `Sources/OpenPhotoCore/Interop/SidecarExporter.swift`, `Tests/OpenPhotoCoreTests/SidecarExporterTests.swift`.

- [ ] **Step 1: Write the failing test** — `Tests/OpenPhotoCoreTests/SidecarExporterTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func sidecarExporterWritesMirrorTreeSkippingEmpties() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try makeJPEG(at: pics.appendingPathComponent("paris/PLAIN.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    try await lib.scanAll()
    let rome = try lib.catalog.timelineItems().first { $0.relPath == "rome/IMG.jpg" }!
    try lib.updateMetadata(for: rome, rating: 4, favorite: false, caption: "hi", tags: ["a", "b"])

    let dest = try t.sub("export")
    let n = try SidecarExporter.export(library: lib, to: dest)
    #expect(n == 1)                                                   // only the tagged one
    let out = dest.appendingPathComponent("rome/IMG.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: out.path))
    let parsed = try XMP.parse(try Data(contentsOf: out))
    #expect(Set(parsed.tags) == ["a", "b"] && parsed.rating == 4)
    #expect(!FileManager.default.fileExists(                          // empty sidecar → skipped
        atPath: dest.appendingPathComponent("paris/PLAIN.jpg.xmp").path))
    #expect(!FileManager.default.fileExists(                          // library NOT polluted
        atPath: pics.appendingPathComponent("rome/IMG.jpg.xmp").path))
}
```

- [ ] **Step 2: Run, confirm fail** — `swift test --filter sidecarExporter 2>&1 | tail -5`.

- [ ] **Step 3: Create `Sources/OpenPhotoCore/Interop/SidecarExporter.swift`:**

```swift
import Foundation

/// Export human-authored metadata as a portable mirror tree of standard XMP sidecars under `dest`,
/// for interop with Lightroom / other XMP tools. One-way; reads the hidden `.openphoto/` store, writes
/// only under `dest`, never touches the library. Naming: `dest/<relPath>.xmp` (append). Skips assets
/// with no human metadata. Returns the count written.
public enum SidecarExporter {
    @discardableResult
    public static func export(library: LibraryService, to dest: URL) throws -> Int {
        var count = 0
        for vault in library.vaults {
            let store = SidecarStore(vault: vault)
            for entry in try Manifest.read(from: vault.manifestURL) {
                let data = try store.read(forMediaRelPath: entry.path)
                guard data != .empty else { continue }
                try AtomicFile.write(Data(XMP.serialize(data).utf8),
                                     to: dest.appendingPathComponent(entry.path + ".xmp"))
                count += 1
            }
        }
        return count
    }
}
```
> `library.vaults` (public `[Vault]`), `vault.manifestURL`, `SidecarStore(vault:)`, `Manifest.read(from:)`, `XMP.serialize`, and `AtomicFile.write` (creates intermediate dirs) all exist.

- [ ] **Step 4: Run + clean build** — `swift test --filter sidecarExporter 2>&1 | tail -6` → pass. `swift test 2>&1 | tail -3` → full suite green. Both warning greps empty.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Interop/SidecarExporter.swift Tests/OpenPhotoCoreTests/SidecarExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(interop): SidecarExporter — portable mirror tree of XMP sidecars

One-way export of human metadata to dest/<relPath>.xmp (append naming), reusing XMP.serialize +
AtomicFile. Skips assets with no metadata; reads the hidden store; never writes into the library.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: AppState wiring + Export command

**Files:** Modify `Sources/OpenPhotoApp/AppState.swift`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift`, `Sources/OpenPhotoApp/OpenPhotoApp.swift`.

- [ ] **Step 1: AppState state + helpers.** In `AppState.swift` add a `// MARK: — Metadata interop` section:
```swift
    var finderTagSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "finderTagSync") {
        didSet {
            UserDefaults.standard.set(finderTagSyncEnabled, forKey: "finderTagSync")
            if finderTagSyncEnabled { syncFinderTagsNow() }   // push existing tags + pull Finder edits
        }
    }

    /// When Finder sync is on, reconcile a tag edit with Finder (writes Finder + baseline) and return
    /// the merged set to persist; otherwise return the user's set unchanged.
    func tagsForSave(item: TimelineItem, proposed: [String]) -> [String] {
        guard finderTagSyncEnabled, let lib = library else { return proposed }
        return (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: proposed)) ?? proposed
    }

    /// Full reconcile pass over every asset (off-main). Picks up Finder-side edits and pushes
    /// OpenPhoto tags to Finder; persists the merged set to the sidecar + catalog when it changed.
    /// No-op when the toggle is off.
    func syncFinderTagsNow() {
        guard finderTagSyncEnabled, let lib = library else { return }
        Task.detached(priority: .utility) {
            let items = (try? lib.catalog.timelineItems()) ?? []
            var seen = Set<String>()
            for item in items where seen.insert(item.hash).inserted {
                let current = (try? JSONDecoder().decode([String].self, from: Data(item.tagsJSON.utf8))) ?? []
                let merged = (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: current)) ?? current
                if Set(merged) != Set(current) {
                    try? lib.updateMetadata(for: item, rating: item.rating, favorite: item.favorite,
                                            caption: item.caption, tags: merged)
                }
            }
            await MainActor.run { [weak self] in try? self?.refreshQueries() }
        }
    }

    /// Export human-metadata sidecars to a user-chosen folder (a portable XMP snapshot).
    func exportSidecars() {
        guard let lib = library else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported .xmp metadata sidecars."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            let n = await Task.detached(priority: .userInitiated) {
                (try? SidecarExporter.export(library: lib, to: dest)) ?? 0
            }.value
            let alert = NSAlert()
            alert.messageText = "Exported \(n) sidecar\(n == 1 ? "" : "s")"
            alert.informativeText = "Standard .xmp metadata files were written to the chosen folder."
            alert.runModal()
        }
    }
```
> `refreshQueries()`, `TimelineItem.tagsJSON/rating/favorite/caption/hash`, and `NSOpenPanel`/`NSAlert` (AppKit, already imported in AppState) all exist.

- [ ] **Step 2: At library-open, run an initial sync when enabled.** Find where `AppState` finishes opening a library (e.g. `openLibrary`/the post-open path that calls `refreshQueries`/`pokeDerivation`); add `if finderTagSyncEnabled { syncFinderTagsNow() }` after the library + queries are ready. (Read `AppState` to place it correctly; a single call is enough.)

- [ ] **Step 3: Route the inspector save through `tagsForSave`.** In `Inspector/InspectorView.swift` `save()` (~line 419), the call `try? lib.updateMetadata(for: item, rating: rating, favorite: favorite, caption: caption.isEmpty ? nil : caption, tags: tags)` becomes `tags: state.tagsForSave(item: item, proposed: tags)`.

- [ ] **Step 4: Add the Export File-menu command** in `OpenPhotoApp.swift`'s `.commands` → the existing `CommandGroup(after: .newItem)` block, add:
```swift
                Button("Export Metadata Sidecars\u{2026}") {
                    MainActor.assumeIsolated { state.exportSidecars() }
                }
```

- [ ] **Step 5: Build, zero warnings** — `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → both empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Inspector/InspectorView.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "$(cat <<'EOF'
feat(interop): AppState Finder-sync opt-in + tagsForSave + sync-now + export action

A persisted finderTagSyncEnabled (default off); tagsForSave reconciles a tag edit with Finder when
on; syncFinderTagsNow reconciles every asset off-main (on enable + at library-open); exportSidecars
runs SidecarExporter to a chosen folder. Inspector save routes tags through tagsForSave; a File-menu
"Export Metadata Sidecars…" command added.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `SettingsView` + the Settings scene

**Files:** Create `Sources/OpenPhotoApp/Settings/SettingsView.swift`; modify `Sources/OpenPhotoApp/OpenPhotoApp.swift`.

- [ ] **Step 1: Create `SettingsView`** — `Sources/OpenPhotoApp/Settings/SettingsView.swift`. A `TabView` with two tabs:
  - **General:** a `Form` with `Toggle("Sync tags with Finder", isOn: $state.finderTagSyncEnabled)`, a caption ("Mirrors your tags to macOS Finder tags on this Mac's files, two-way. Off by default; turning it on writes Finder tags to your originals (non-destructive)."), and a `Button("Sync Finder tags now") { state.syncFinderTagsNow() }.disabled(!state.finderTagSyncEnabled)`. `.tabItem { Label("General", systemImage: "gearshape") }`.
  - **About:** the app name ("OpenPhoto"), a credits line ("On-device analysis uses Apple Vision + Core ML MobileCLIP."), and the **required GeoNames attribution** as a tappable link:
    ```swift
    Link("Place data © GeoNames (https://www.geonames.org), CC BY 4.0.",
         destination: URL(string: "https://www.geonames.org")!)
        .font(.system(size: 12))
    ```
    `.tabItem { Label("About", systemImage: "info.circle") }`.
  - Give the window a sensible `.frame(width: 460, height: 280)` (or similar) and `Theme` styling consistent with the app.

- [ ] **Step 2: Add the Settings scene** in `OpenPhotoApp.swift` — in `var body: some Scene`, after the `WindowGroup { … }.windowStyle(.hiddenTitleBar).commands { … }` block, add:
```swift
        Settings { SettingsView(state: state) }
```
This provides the standard macOS Settings window (⌘,) and the "Settings…" app-menu item.

- [ ] **Step 3: Build, zero warnings, rebuild bundle** — `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → both empty. `./scripts/make-app.sh 2>&1 | tail -2` → "Built build/OpenPhoto.app".

- [ ] **Step 4: Manual smoke (implementer notes; user runs):** ⌘, opens Settings; General shows the toggle (off) + Sync-now (disabled until on); About shows the GeoNames link; toggling on triggers a sync; File ▸ Export Metadata Sidecars… writes a tree.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/Settings/SettingsView.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "$(cat <<'EOF'
feat(interop): Settings window — Finder-sync toggle + GeoNames attribution

A native Settings scene (Cmd-,): General hosts the Finder-tag sync opt-in + a "Sync now" button;
About surfaces the required "Place data © GeoNames, CC BY 4.0" attribution (the Map's documented
follow-up) + on-device-analysis credits. Bundle rebuilt.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Docs — master spec §10.5 DONE

**Files:** Modify `docs/superpowers/specs/2026-06-07-openphoto-design.md`.

- [ ] **Step 1:** In §10.5's **Building** list, mark **"Library import"** unchanged, but mark **Finder-tag interoperability** and **Sidecar-layout export** as **DONE 2026-06-11** (edit their lead-ins). Append a changelog entry as the LAST bullet before "## 8. Error-handling doctrine":

```markdown
- **2026-06-11** — **Phase 5 — metadata interop + Settings (DONE).** **Sidecar export:** a File-menu
  "Export Metadata Sidecars…" writes a portable mirror tree of standard `.xmp` (one per tagged asset,
  `dest/<relPath>.xmp`) to a chosen folder — the library is never touched. **Finder-tag two-way sync
  (opt-in):** OpenPhoto tags and macOS Finder tags stay identical via a pure 3-way `TagMerge` against a
  per-photo baseline (rebuildable `finder_tag_sync` table, **catalog migration v11**), so removals on
  either side propagate; XMP stays authoritative; off by default (writing Finder xattrs to originals is
  non-destructive — content hash unchanged — but gated on opt-in). **Settings window** (native ⌘, scene):
  the Finder-sync toggle + "Sync now", and the **GeoNames CC BY 4.0 attribution** owed from the Map (the
  4.4 follow-up, now satisfied). **Catalog-only, no vault-format change** (`catalog-schema.md` → Version
  11). Spec/plan: `docs/superpowers/specs/2026-06-11-metadata-interop-design.md`,
  `docs/superpowers/plans/2026-06-11-metadata-interop.md`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "$(cat <<'EOF'
docs: metadata interop DONE in master spec §10.5 + changelog (GeoNames attribution satisfied)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review (plan author)

- **Spec coverage:** §2 TagMerge/FinderTags → T1; finder_tag_sync+reconcile+schema doc → T2; SidecarExporter → T3; AppState opt-in/gating/sync/export → T4; SettingsView+scene → T5; docs → T6. Opt-in default-off, 3-way merge, drive-only no-op, union-read/write-all, GeoNames attribution, catalog-schema same-commit — all covered. ✓
- **Placeholder scan:** complete Core code; App tasks give exact bindings + the real save site; no "TBD". ✓
- **Type consistency:** `TagMerge.merge`, `FinderTags.read/write`, `setFinderTagBaseline`/`finderTagBaseline`, `reconcileFinderTags(forHash:proposedTags:)`, `SidecarExporter.export(library:to:)`, `finderTagSyncEnabled`/`tagsForSave`/`syncFinderTagsNow`/`exportSidecars`, `SettingsView` — consistent across tasks and against the real APIs (`XMP.serialize`/`parse`, `SidecarStore`, `AtomicFile.write`, `catalog.instances(forHash:)`, `vault(id:)`, `updateMetadata`, `updateHumanMetadata`, `timelineItems`). ✓
- **Ordering:** T2 depends on T1 (`TagMerge`/`FinderTags`); T3 independent; T4 depends on T2+T3; T5 depends on T4. Execute T1→T6. ✓
- **Doc discipline:** the v11 schema-doc update is IN Task 2's commit (not deferred). ✓
