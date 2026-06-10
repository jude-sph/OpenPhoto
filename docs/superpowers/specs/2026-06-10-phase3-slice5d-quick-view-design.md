# Phase 3 Slice 5d — Quick View (ephemeral, trace-free drive peek) (design)

**Date:** 2026-06-10
**Branch:** `phase3-drives`
**Status:** Approved
**Builds on:** 5b (`CatalogSnapshot.import` reads a drive snapshot into a `Catalog`), 5a (`driveSource` / drive full-res), the existing `ThumbnailStore.displayImage(for:sourceURL:kind:maxPixel:)`, `ThumbView`, `ZoomableImageView`, the Import/Viewer **main-window-takeover** pattern (`RootView.detail` swaps on `openedDevice`; `ViewerView` overlays on `openedItem`), `MediaKind.of(filename:)`, the Scanner's media-walk.

> **The final Phase 3 slice.** After it, merge `phase3-drives` → `main`.

---

## 1. Goal

Plug in a drive — or point at any folder — and **browse it without adopting it**: a sandboxed, ephemeral peek that writes **nothing** to the drive or the Mac. On Done / eject / quit it's gone — "like it was never here." The payoff of "the library is just files": you can look at any OpenPhoto drive (or any folder of photos) on any Mac, instantly, with zero commitment.

Handles **both** source kinds in this first version:
- an **OpenPhoto drive with a catalog-snapshot** (instant — read the snapshot's index + thumbnails);
- a **raw folder / non-OpenPhoto drive** (lazy-scan + thumbnail as you scroll, like the Import preview).

### Non-goals
- No write to the drive (read-only), no persistence on the Mac (temp dir discarded). It is **never** mixed into the main timeline/catalog.
- Not wired into the sidebar / main browse layer (kept single-source) — a self-contained peek surface.
- No editing, tagging, send, evict, or any library mutation from within a peek (it's view-only).

---

## 2. Hard invariants honored

| Invariant | How |
|---|---|
| Drives passive / read-only | Snapshot DB opened read-only (5b); the raw walk only *reads* files; **a raw folder is never `openOrCreate`d** (that would write a `vault.json` to it). |
| Nothing persisted on the Mac | All peek state (temp catalog, temp thumbnail cache) lives under one temp dir, deleted on teardown. The live catalog + live thumbnail cache are never touched. |
| Originals never modified | Peek only reads file bytes for thumbnails + full-res. |

---

## 3. Components

### 3.1 `PeekItem` / `PeekContext` (Core)

```swift
/// One peekable photo/video, backend-agnostic.
public struct PeekItem: Sendable, Identifiable, Equatable {
    public var id: String          // stable (the source file path)
    public var name: String        // filename, for display
    public var kind: MediaKind
    public var sourceURL: URL      // the file on the drive/folder — thumbnail source AND full-res
    public var thumbHash: ContentHash  // real asset hash (snapshot) or a path-derived synthetic (raw)
}

/// A loaded, ephemeral peek: the items + a THROWAWAY thumbnail cache, all under `tempDir`.
public struct PeekContext: Sendable {
    public var sourceName: String              // drive/folder display name (the banner)
    public var items: [PeekItem]
    public var thumbnails: ThumbnailStore      // temp cache (cacheDir under tempDir)
    public var tempDir: URL                    // deleted wholesale on teardown
}
```

### 3.2 `PeekSource` (Core) — the two backends behind one loader

```swift
public enum PeekSource {
    /// Build a peek for `root` into a fresh `tempDir`. If `root` carries a catalog-snapshot it's read
    /// instantly (snapshot backend); otherwise its media files are enumerated (raw backend). Reads
    /// only; never writes to `root`.
    public static func load(root: URL, tempDir: URL) throws -> PeekContext

    /// Recursive, read-only walk of media files under `root` (skips `.openphoto/`, hidden files, and
    /// non-media), newest-first by name is fine. Shared raw-backend enumeration.
    public static func mediaFiles(under root: URL) -> [URL]
}
```

- **Snapshot backend** (`root/.openphoto/catalog-snapshot/catalog.sqlite` exists → it's an OpenPhoto vault, so `vault.json` already exists and `Vault.openOrCreate(at: root, role: .canonical)` only *reads* it): create a temp `Catalog(at: tempDir/catalog.sqlite)` + `ThumbnailStore(cacheDir: tempDir/thumbs)`, `CatalogSnapshot.import(from: drive, into: tempCatalog, thumbnails: tempThumbs)`, then `items = tempCatalog.timelineItems()` mapped to `PeekItem` with `sourceURL = drive.absoluteURL(forRelativePath: item.driveRelPath!)`, `thumbHash = ContentHash(stringValue: item.hash)`. Thumbnails come from the imported snapshot cache (cache hits); full-res from the drive file.
- **Raw backend** (no snapshot): `ThumbnailStore(cacheDir: tempDir/thumbs)`; `items = mediaFiles(under: root).map { PeekItem(sourceURL: $0, kind: MediaKind.of(filename:)!, name: lastPathComponent, thumbHash: synthetic($0)) }`, where `synthetic(url)` is a path-derived `ContentHash` (`"sha256:" + sha256hex(url.path)` — hashes the *path string*, not the file bytes, so it's instant and stable; keys the temp cache). Thumbnails are **generated lazily** from the file on first display; full-res from the file.

### 3.3 The peek surface (App, self-contained)

- **`PeekGridCell(item: PeekItem, thumbnails: ThumbnailStore)`** — renders a thumbnail via `thumbnails.displayImage(for: item.thumbHash, sourceURL: item.sourceURL, kind: item.kind, maxPixel:)` (falling back to `cachedDisplayImage`), with the same async + memory-cache approach as `ThumbView` (keyed by `item.id@px`, so a recycled cell shows instantly and raw thumbs generate once). This single cell serves **both** backends — a snapshot item's hash hits the imported cache; a raw item's synthetic hash misses → generated from the file.
- **`PeekView(context: PeekContext, onDone: () -> Void)`** — a top banner *"Viewing '<sourceName>' — temporary · not added to your library"* + **Done**, and a `LazyVGrid` of `PeekGridCell`s. Tapping a cell opens **`PeekViewer`** (full-screen, reusing `ZoomableImageView`, loading full-res from `item.sourceURL`; arrow-key/`esc` nav within `context.items`). No inspector, no selection, no library actions.

### 3.4 Presentation + lifecycle (AppState + RootView)

- `AppState.peekContext: PeekContext?` (state). When non-nil, `RootView.detail` shows `PeekView` (a takeover, like `ImportView`) — the sidebar stays but the detail is the clearly-labeled peek.
- `func startQuickView(root: URL) async` — make a fresh temp dir, `PeekSource.load(root:tempDir:)` **off-main**, set `peekContext`. (Errors → a brief alert; no peek.)
- `func endQuickView()` — clear `peekContext` and **delete its `tempDir`** (idempotent; ignore errors).
- **Teardown triggers:** Done (`onDone` → `endQuickView`); the peeked drive **ejecting/disconnecting** mid-peek (`deviceWatcher.onVolumesChanged` / the eject path → if the peek's root is gone, `endQuickView`); app quit (best-effort cleanup; temp dirs are OS-temp anyway). Eject mid-peek just closes the peek — nothing was persisted.

### 3.5 Entry points (App)

- **Drives panel:** a **"Quick View"** action on a connected drive's row (`startQuickView(root: vr.rootPath)`).
- **A "Quick View Folder…" command** (File menu + a button): `NSOpenPanel` → pick any folder/drive → `startQuickView(root:)`. This is the raw-folder entry (a folder that isn't a registered drive).
- **The 5b unknown-drive prompt** gains a third option: **Adopt / Quick View / Not now** — peek before committing.

---

## 4. Data flow

`startQuickView(root)` → temp dir → `PeekSource.load` (snapshot import *or* raw walk, off-main) → `peekContext` set → `RootView` shows `PeekView` → cells lazily resolve thumbnails (snapshot cache hit / raw generate) → tap → `PeekViewer` full-res from the file → **Done/eject** → `endQuickView` deletes the temp dir. The live catalog, live thumbnail cache, and the drive are all untouched throughout.

---

## 5. Error handling / edge cases

| Case | Behavior |
|---|---|
| Snapshot present but unreadable/corrupt | `CatalogSnapshot.import` is best-effort; fall back to the raw walk (still a valid peek), or show an empty-state if no media. |
| Raw folder with thousands of files | Enumeration is cheap (paths only, no hashing); thumbnails generate lazily per visible cell — same as the Import preview. |
| A file's thumbnail can't be generated | The cell shows the empty tile (no crash); full-res shows the "isn't available" fallback (reuse the viewer's). |
| Drive/folder ejected mid-peek | `endQuickView` closes the peek; thumbnails already shown stay until close; full-res of an unopened item just fails gracefully. Nothing persisted. |
| `startQuickView` on a folder with neither snapshot nor media | Empty-state peek ("No photos here") + Done. |
| Two peeks at once | Single `peekContext`; starting a new peek ends the prior one first (delete its temp dir). |

---

## 6. Testing

**Core (unit, temp dirs + generated mock media — never `~/Pictures`):**
1. `mediaFiles(under:)`: a temp tree with JPEGs/MOVs + a `.openphoto/` dir + a `.DS_Store` + a `.txt` → returns exactly the media files, skips `.openphoto/` and non-media.
2. Raw `PeekSource.load`: a temp folder of mock images (no snapshot) → `PeekContext` with one `PeekItem` per media file, `sourceURL` = the file, `kind` correct, distinct synthetic `thumbHash`s, a temp `thumbnails` under `tempDir`.
3. Snapshot `PeekSource.load`: build a drive with a snapshot (reuse the 5b `CatalogSnapshot.write` fixture) → load → `PeekContext.items` match the drive's catalog (hash-keyed `thumbHash`, `sourceURL` = the drive file). Confirm **nothing was written to the live catalog** (the peek uses its own temp Catalog).
4. Trace-free: after building a `PeekContext` and deleting `tempDir`, the temp dir is gone and no app-support/live paths were touched (assert the temp Catalog/thumbs lived under `tempDir`).

**App:** build-verified (0 warnings) + manual — Quick View a snapshot drive (instant grid, full-res from the drive); Quick View a raw folder (thumbnails generate as you scroll); Done discards; eject mid-peek closes cleanly; after a peek, the live timeline/Drives/catalog are unchanged (no new presence, no thumbs in the live cache).

---

## 7. Task decomposition (for the plan)

1. **Core** — `PeekItem`/`PeekContext` + `PeekSource.mediaFiles(under:)` + `PeekSource.load(root:tempDir:)` (both backends). TDD (tests 1–4).
2. **App** — `PeekGridCell` + `PeekView` + `PeekViewer` (reusing the `ThumbView` async pattern + `ZoomableImageView`). Build-verified.
3. **App** — `AppState.peekContext` + `startQuickView`/`endQuickView` (off-main load, temp-dir teardown) + `RootView` takeover wiring + eject-mid-peek teardown. Build-verified.
4. **App** — entry points: Drives-row "Quick View", "Quick View Folder…" command, the Adopt/**Quick View**/Not-now prompt option. Build-verified + manual; rebuild bundle.
5. **Docs** — master-spec §10 (Quick View as implemented) + changelog; note **Phase 3 complete → merge `phase3-drives` → `main`** (the merge is a separate, user-gated step).

No catalog migration, no on-disk format change (a peek writes nothing). The `SyncEngine` copy spine, `VerifiedCopy`, `Manifest`, and send destinations are untouched.
