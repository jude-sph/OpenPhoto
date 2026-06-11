# Folder reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Drag-drop nest / create / delete folders in the Folders view, moving the real vault directories on disk and keeping connected drives path-aligned.

**Architecture:** A Core `VaultReorganizer` does the on-disk move/create/delete + manifest path-rewrite; `folderTree` also walks real filesystem dirs so empty folders show; `AppState` orchestrates the Mac op + propagation to connected durable drives + rescan + UI fixups; `FolderTreeView` gets drag-drop + context menus.

**Tech Stack:** Swift 6 / SwiftPM CLT (no Xcode), GRDB, SwiftUI drag-drop.

## Hard rules (every task)
- CLT only (`swift build`/`swift test`); **0 warnings** (`swift build 2>&1 | grep -i warning` empty).
- **Never** touch `~/Pictures`/personal dirs — tests use generated files in `TestDirs` temp vaults (mirror `Tests/OpenPhotoCoreTests` patterns: `Vault.openOrCreate`, `Catalog(at:)`, `makeJPEG`/raw `Data`).
- Invariants: atomic ops (`FileManager.moveItem` same-volume rename; `AtomicFile`/`Manifest.write` for the manifest); **nothing hard-deletes** (delete → `BinStore`); originals only **moved** on explicit user action.
- Do **not** modify `Scanner`, `MetadataExtractor`, `ThumbnailStore`, `SyncEngine`. `Manifest`/`BinStore` are **used**, not changed.
- Each task commits with the exact message ending in `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- TDD for Core (T1–T2), build-verified for App (T3–T4).

## Reference (from codebase exploration)
- `Vault`: `rootURL`, `manifestURL`, `absoluteURL(forRelativePath:)`, `relativePath(of:)`, `binDirURL`, state dir `.openphoto`. Sidecar at `<mediaDir>/.openphoto/<file>.xmp` — travels with the dir on a subtree move.
- `Manifest.read(from:) -> [ManifestEntry]`; `Manifest.write(_ entries:to:)` (atomic full rewrite, sorted by path). `ManifestEntry(hash: ContentHash, path: String, size: Int64, mtime: String)`.
- `LibraryService.folderTree()` (LibraryService.swift:147) → uses `Catalog.folderCounts()` (Queries.swift:73); materializes zero-count ancestors. `FolderNode(path, name, count, children)` (LibraryService.swift:13).
- Path update is wholesale: move on disk, then `AppState.rescan()` re-walks → `Catalog.replaceInstances(inVault:with:)`. No per-row SQL rename needed.
- `LibraryService.delete(_ items:)` (LibraryService.swift:232): bins each + Live pair, `enqueuePendingDeletion`, rescans. Reuse for folder-delete.
- Durable drives: `AppState.durableVaults` / `connectedDrivesCanonicalFirst()`; drive-relpath mapping = `<vaultBasename>/<relPath>` (see `SyncEngine.driveRelPath(forSourceVault:relPath:)`).
- `FolderTreeView.swift` `FolderRow` HStack ~line 29; `state.selectedFolder: String?`, `state.expandedFolders: Set<String>`, `state.refreshQueries()`.

---

## Task 1: Core (TDD) — `VaultReorganizer`

**Files:** Create `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift`; Test `Tests/OpenPhotoCoreTests/VaultReorganizerTests.swift`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func seed(_ vault: Vault, relPath: String, bytes: String = "x") throws -> ContentHash {
    let url = vault.absoluteURL(forRelativePath: relPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url)
    return try ContentHash.ofFile(at: url)
}

@Test func moveFolderRelocatesFilesAndRewritesManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: t.root.appendingPathComponent("V"), role: .canonical)
    let h = try seed(vault, relPath: "a/x.jpg")
    try Manifest.write([ManifestEntry(hash: h, path: "a/x.jpg", size: 1,
                        mtime: ISO8601Millis.string(from: Date()))], to: vault.manifestURL)

    let newPath = try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "b")
    #expect(newPath == "b/a")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/a/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    let entries = try Manifest.read(from: vault.manifestURL)
    #expect(entries.count == 1 && entries[0].path == "b/a/x.jpg" && entries[0].hash == h)
}

@Test func moveIntoSelfOrDescendantThrows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: t.root.appendingPathComponent("V"), role: .canonical)
    _ = try seed(vault, relPath: "a/b/x.jpg")
    #expect(throws: (any Error).self) { try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "a/b") }
    #expect(throws: (any Error).self) { try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "a") }
}

@Test func moveOntoExistingNameThrows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: t.root.appendingPathComponent("V"), role: .canonical)
    _ = try seed(vault, relPath: "a/x.jpg")
    _ = try seed(vault, relPath: "b/a/y.jpg")   // b already has an "a"
    #expect(throws: (any Error).self) { try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "b") }
}

@Test func createAndDeleteEmptyFolder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: t.root.appendingPathComponent("V"), role: .canonical)
    try VaultReorganizer.createFolder(in: vault, relPath: "new/sub")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "new/sub").path))
    try VaultReorganizer.deleteEmptyFolder(in: vault, relPath: "new/sub")
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "new/sub").path))
    _ = try seed(vault, relPath: "full/x.jpg")
    #expect(throws: (any Error).self) { try VaultReorganizer.deleteEmptyFolder(in: vault, relPath: "full") }
}
```

- [ ] **Step 2:** Run `swift test --filter VaultReorganizer` → FAIL (type missing).

- [ ] **Step 3: Implement** `VaultReorganizer.swift`:
```swift
import Foundation

/// Real on-disk folder moves/creates/deletes within a vault, with manifest path rewrites.
/// Same-volume FileManager.moveItem is an atomic rename; the moved subtree carries its
/// per-dir `.openphoto/` sidecars for free. Machine state (catalog) is rebuilt by a rescan.
public enum VaultReorganizer {
    public enum ReorgError: Error { case invalidTarget, destinationExists, notEmpty, missing }

    /// Move `relPath` to be a child of `intoParentRelPath` ("" = vault root). Returns the new relPath.
    @discardableResult
    public static func moveFolder(in vault: Vault, relPath: String,
                                  intoParentRelPath parent: String) throws -> String {
        let src = norm(relPath)
        let dstParent = norm(parent)
        guard !src.isEmpty else { throw ReorgError.invalidTarget }
        // no move into self or a descendant
        if dstParent == src || dstParent.hasPrefix(src + "/") { throw ReorgError.invalidTarget }
        let name = (src as NSString).lastPathComponent
        let newPath = dstParent.isEmpty ? name : dstParent + "/" + name
        if newPath == src { return src }   // dropped onto current parent: no-op
        let fm = FileManager.default
        let srcURL = vault.absoluteURL(forRelativePath: src)
        let dstURL = vault.absoluteURL(forRelativePath: newPath)
        guard fm.fileExists(atPath: srcURL.path) else { throw ReorgError.missing }
        if fm.fileExists(atPath: dstURL.path) { throw ReorgError.destinationExists }
        try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: srcURL, to: dstURL)          // atomic same-volume rename
        try rewriteManifest(vault, from: src, to: newPath)
        return newPath
    }

    public static func createFolder(in vault: Vault, relPath: String) throws {
        let p = norm(relPath); guard !p.isEmpty else { throw ReorgError.invalidTarget }
        try FileManager.default.createDirectory(at: vault.absoluteURL(forRelativePath: p),
                                                withIntermediateDirectories: true)
    }

    public static func deleteEmptyFolder(in vault: Vault, relPath: String) throws {
        let p = norm(relPath); guard !p.isEmpty else { throw ReorgError.invalidTarget }
        let url = vault.absoluteURL(forRelativePath: p)
        // empty = no media; ignore a lone `.openphoto/` (sidecar dir) which we also remove.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if contents.contains(where: { $0 != ".openphoto" && !$0.hasPrefix(".") }) {
            throw ReorgError.notEmpty
        }
        try? FileManager.default.removeItem(at: url.appendingPathComponent(".openphoto"))
        try FileManager.default.removeItem(at: url)
    }

    private static func rewriteManifest(_ vault: Vault, from oldDir: String, to newDir: String) throws {
        let entries = try Manifest.read(from: vault.manifestURL)
        let prefix = oldDir + "/"
        let updated = entries.map { e -> ManifestEntry in
            guard e.path == oldDir || e.path.hasPrefix(prefix) else { return e }
            let rest = String(e.path.dropFirst(oldDir.count))   // keeps leading "/"
            return ManifestEntry(hash: e.hash, path: newDir + rest, size: e.size, mtime: e.mtime)
        }
        try Manifest.write(updated, to: vault.manifestURL)
    }

    private static func norm(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
```
> Verify `ContentHash.ofFile`, `ISO8601Millis.string`, `Vault.openOrCreate`, `ManifestEntry`/`Manifest.read/write` signatures against the codebase and adjust if they differ. If `Vault.openOrCreate` requires more args, mirror the existing Vault tests.

- [ ] **Step 4:** `swift test --filter VaultReorganizer` → PASS. `swift build 2>&1 | grep -i warning` empty.
- [ ] **Step 5: Commit** `feat: VaultReorganizer — on-disk folder move/create/delete + manifest rewrite`.

---

## Task 2: Core (TDD) — `folderTree` shows real (empty) directories

**Files:** Modify `Sources/OpenPhotoCore/LibraryService.swift` (`folderTree()` ~line 147); Test add to `Tests/OpenPhotoCoreTests/` (e.g. a `FolderTreeTests.swift`).

- [ ] **Step 1: Failing test** — create a vault with one cataloged photo in `a/` and an **empty** real dir `b/`; build the catalog; assert `library.folderTree()` contains a node for `b` (count 0) as well as `a`.
```swift
@Test func folderTreeIncludesEmptyDirectories() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    // … open vault + catalog, scan one photo into a/, mkdir an empty b/ …
    try FileManager.default.createDirectory(at: vault.absoluteURL(forRelativePath: "b"),
                                            withIntermediateDirectories: true)
    let tree = try library.folderTree()
    let paths = flatten(tree).map(\.path)          // helper that recurses children
    #expect(paths.contains("a") && paths.contains("b"))
}
```

- [ ] **Step 2:** Run → FAIL (`b` absent; tree is catalog-only).

- [ ] **Step 3: Implement** — in `folderTree()`, union the catalog `folderCounts` keys with a filesystem dir walk of the **primary vault** root:
```swift
private func directoriesUnder(_ root: URL) -> [String] {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
    var dirs: [String] = []
    for case let url as URL in en {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if url.lastPathComponent == ".openphoto" { en.skipDescendants(); continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                .precomposedStringWithCanonicalMapping
            if !rel.isEmpty { dirs.append(rel) }
        }
    }
    return dirs
}
```
Merge these (count 0 where the catalog has none) into the same node-assembly that consumes `folderCounts` — so existing zero-count-ancestor logic and counts stay correct. Use the primary vault's `rootURL`.

- [ ] **Step 4:** Run → PASS; 0 warnings.
- [ ] **Step 5: Commit** `feat: folderTree includes real filesystem directories (empty folders show)`.

---

## Task 3: App — `AppState+FolderReorg` orchestration

**Files:** Create `Sources/OpenPhotoApp/AppState+FolderReorg.swift`; reference `AppState` (durable drives, `rescan`, `delete`, `items(inDir:)`, `selectedFolder`, `expandedFolders`).

- [ ] **Step 1:** Implement three `@MainActor` async methods on `AppState`:
  - `func moveFolder(from src: String, into parent: String) async` — (a) if a connected-set check finds a durable drive that **has** `src` but is **offline**, show an `NSAlert` warning (Continue/Cancel) and abort on Cancel; (b) `try VaultReorganizer.moveFolder(in: primaryVault, relPath: src, intoParentRelPath: parent)` (catch → `NSAlert(error:)`, return); (c) for each **connected** durable drive whose root holds `<vaultBasename>/src`, run `VaultReorganizer.moveFolder` on that drive vault (drive-relpath-mapped) off-main; (d) `await rescan()`; (e) remap `selectedFolder` and every `expandedFolders` entry with the `src`/`src/` prefix to the new path.
  - `func createFolder(named name: String, under parent: String?) async` — `VaultReorganizer.createFolder` on the primary vault + each connected durable drive; `try? refreshQueries()`; select/expand the new folder.
  - `func deleteFolder(_ path: String) async` — fetch `library.items(inDir: path, recursive: true)`; `await delete(items)` (bins media + queues `pending_deletions` for drive review); then `VaultReorganizer.deleteEmptyFolder` on the primary vault + connected durable drives (ignore `notEmpty` if a stray remains); `await rescan()`.
- Use the existing primary-vault accessor (the one `rescan`/`openVault` use) and `connectedDrivesCanonicalFirst()` / `durableVaults` for drives. Drive file ops run off the `@MainActor` via `Task.detached`.

- [ ] **Step 2:** `swift build`; 0 warnings. (No unit test; build-verified — the Core logic is tested in T1.)
- [ ] **Step 3: Commit** `feat: AppState folder reorg — Mac op + connected-drive propagation + rescan`.

---

## Task 4: App — Folders-view drag-drop + create/delete UI

**Files:** Modify `Sources/OpenPhotoApp/Folders/FolderTreeView.swift` (+ a small create sheet if needed).

- [ ] **Step 1:** On `FolderRow`'s row HStack add `.draggable(node.path)` and `.dropDestination(for: String.self) { items, _ in guard let s = items.first, s != node.path, !node.path.hasPrefix(s + "/") else { return false }; Task { await state.moveFolder(from: s, into: node.path) }; return true }` with a drop-highlight (e.g. a `@State var dropTargeted` via the `isTargeted:` closure → ring/background).
- [ ] **Step 2:** Add a `.contextMenu` on each row: **New Folder Inside…** (presents a name field → `state.createFolder(named:under:node.path)`), **Delete Folder…** (confirmation showing the recursive item count → `state.deleteFolder(node.path)`). Add a **New Folder** button at the tree header for root-level creation.
- [ ] **Step 3:** `swift build`; 0 warnings; `./scripts/make-app.sh`. Manual: drag to nest (files move on disk + connected drive), create/delete, delete bins media.
- [ ] **Step 4: Commit** `feat: Folders view drag-drop nesting + create/delete folders`.

---

## Task 5: Docs — record the feature + drive-interaction decisions

**Files:** Modify `docs/superpowers/specs/2026-06-07-openphoto-design.md` (changelog) — **no** `vault-format`/`catalog-schema` change (manifest schema unchanged; no new artifact; no migration).

- [ ] **Step 1:** Add a `2026-06-11` changelog entry: folder reorganization (drag-drop nest/create/delete moving real vault dirs); the **path-keyed sync** interaction and the **connected-drive propagation** decision; the **disconnected-drive warning + deferred pending-ops queue**; folderTree now reflects filesystem dirs. Note it touches no on-disk format.
- [ ] **Step 2: Commit** `docs: record folder reorganization + drive-propagation decision`.

---

## After all tasks
- [ ] Final whole-slice review: move is atomic + manifest rewrite correct; connected drives stay path-aligned (no sync duplication); delete bins (no hard-delete); empty folders show; self/descendant/collision rejected; 0 warnings; suite green.
- [ ] Rebuild bundle. **Do NOT merge** (user-gated; report at end).
