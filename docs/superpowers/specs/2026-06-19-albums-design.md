# Albums — Design Spec

**Status:** approved (Approach A) — user delegated full autonomy through implementation + release; per-section sign-off and the spec-review gate are exercised by the author on the user's behalf.

**Goal:** Manual, ordered, drive-synced *virtual* photo collections ("albums") that group photos by association — e.g. "Birthdays", "Esoteric", "Show these to sister" — **without** moving or duplicating the underlying files. A photo can belong to any number of albums; deleting an album never deletes photos.

**Architecture (one line):** Each album is a sovereign JSON file under `<libraryRoot>/.openphoto/albums/<uuid>.json` (authoritative, human-authored); a rebuildable catalog mirror (`albums`, `album_members`) backs fast, locked-gate-aware queries; the existing one-way drive sync copies the album files to canonical/backup drives.

**Tech stack:** Swift / SwiftUI, GRDB/SQLite, the existing `.openphoto/` sovereign-state pattern (`LockedFolderStore`), `AtomicFile`, `MediaTile` grid, `SelectionActionBar`.

---

## 1. Decisions (from brainstorming)

- **Manual albums only.** Smart/rule-based (saved-search) albums are out of scope for v1; the data model does not preclude adding them later.
- **Ordered.** An album is an *ordered* list; the user drags to rearrange.
- **Drive-synced.** Album definitions propagate to canonical & backup drives (one-way), so they survive a Mac loss and a future server can read them from a canonical drive.
- **Storage = Approach A:** one sovereign JSON file per album in `.openphoto/albums/`, with a rebuildable catalog mirror. (Rejected: album-as-XMP-tag — can't express order/empty/metadata; album-as-symlink-folder — fragile.)
- **Members by content hash.** An album references *content* (a photo), not a physical instance — so membership survives renames/moves and is portable to a drive (which holds the same content by hash) with no path remapping.
- **No per-photo XMP mirror in v1** (YAGNI): it can't store order and would make album rename rewrite every member's sidecar. The documented album-file format is the sovereign record.

---

## 2. On-disk format (NEW — normative; must be documented in `docs/format/`)

One file per album: `<libraryRoot>/.openphoto/albums/<id>.json`

```json
{
  "id": "5C2E…-UUID",
  "name": "Birthdays",
  "description": null,
  "coverHash": null,
  "createdAtMs": 1718800000000,
  "modifiedAtMs": 1718800000000,
  "members": ["sha256:…", "sha256:…"]
}
```

- `id` — UUID string, **immutable**, equal to the filename stem. The album's stable identity across catalog rebuilds and across drives.
- `name` — display name (human-authored, editable). Trimmed, non-empty. Uniqueness is **not** enforced (the id is identity).
- `description` — optional free text (no v1 UI beyond display; field reserved).
- `coverHash` — optional content hash to use as the album cover; `null` → cover derives from the first member.
- `createdAtMs` / `modifiedAtMs` — epoch-ms timestamps.
- `members` — **ordered** array of content hashes. A hash appears at most once. Each is resolved to a browse-visible instance via the catalog/manifest at display time (honoring the locked-folder gate).

Sovereignty: these files are the authoritative, human-authored record. The catalog mirror is rebuildable from them (consistent with invariant: human metadata is durable, the catalog is rebuildable). Because members are content hashes, the files are directly portable to a drive (same content, same hashes) with no rewriting.

---

## 3. Components

### 3.1 `AlbumRecord` (Core, `Codable`)
The JSON model above. Pure value type; `Sendable`, `Equatable`.

### 3.2 `AlbumStore` (Core) — sovereign file CRUD
Mirrors `LockedFolderStore`. Directory: `<libraryRoot>/.openphoto/albums/`.
- `loadAll(libraryRoot:) -> [AlbumRecord]` — read every `*.json`; **skip** an unreadable/corrupt file (log, don't fail the whole load); sort by `name` (case-insensitive) for stable presentation.
- `save(_ album: AlbumRecord, libraryRoot:)` — atomic write of one file (`AtomicFile`, now crash-durable).
- `delete(id:, libraryRoot:)` — remove one file.
- `directoryURL(libraryRoot:)` — the `albums/` dir (used by sync).

### 3.3 Catalog mirror (rebuildable)
New migration **v18** (and bump `Catalog.schemaVersion`, documenting the new tables in `catalog-schema.md`):
- `albums(id TEXT PK, name TEXT NOT NULL, coverHash TEXT, createdAtMs INT NOT NULL, modifiedAtMs INT NOT NULL)`
- `album_members(albumID TEXT NOT NULL, hash TEXT NOT NULL, position INT NOT NULL, PRIMARY KEY(albumID, hash))`, `hash` indexed.

Catalog query/mutation methods (`Catalog+Albums.swift`):
- `replaceAlbums(_ albums: [AlbumRecord])` — rebuild the whole mirror from the loaded JSON (open-time + after external change). Transactional.
- `upsertAlbum(_ album: AlbumRecord)` / `deleteAlbumMirror(id:)` — incremental mirror update after a single mutation.
- `itemsInAlbum(id:) -> [TimelineItem]` — `JOIN album_members m ON m.hash = base.hash WHERE m.albumID = ?` over the existing `instanceSQL`/browse query, **ordered by `m.position`**, with `lockedVisibilityClause` applied so locked-folder members are hidden when not revealed. Drops members with no browse-visible instance.
- `albumSummaries() -> [AlbumSummary]` — `(id, name, coverHash, count)` where `count` honors the locked gate; for the sidebar.
- `albumIDsContaining(hash:) -> Set<String>` — for "Add to Album" checkmarks.

### 3.4 `AppState` (App) — state + use-cases
- `var albums: [AlbumSummary] = []`, `var selectedAlbumID: String?`.
- On library open: `let recs = AlbumStore.loadAll(...)`; `catalog.replaceAlbums(recs)`; `refreshAlbums()`. On close: clear.
- Use-cases (each: mutate `AlbumRecord` → `AlbumStore.save`/`delete` → `catalog.upsertAlbum`/`deleteAlbumMirror` → `refreshAlbums()` + bump `refreshToken`):
  - `createAlbum(name:) -> String` (returns id); `createAlbum(name:, fromHashes:)`.
  - `renameAlbum(id:, to:)`, `deleteAlbum(id:)`.
  - `addToAlbum(hashes:[String], albumID:)` — append those not already present (dedup), preserving existing order; new ones appended in given order.
  - `removeFromAlbum(hashes:, albumID:)`.
  - `reorderAlbum(id:, orderedHashes:)` — set the full member order from a drag result.
  - `setAlbumCover(id:, hash:)`.
- `refreshAlbums()` — reload `albumSummaries()` into `albums`.

The album mutation use-cases live in a small `AppState+Albums.swift` (keep `AppState` from growing further).

### 3.5 UI (App, `Sources/OpenPhotoApp/Albums/`)
- `SidebarItem.albums` case (auto-appears in the sidebar via `allCases`); routed in `OpenPhotoApp` RootView `detail` to `AlbumsView`.
- `AlbumsView` = `HStack { AlbumsListView (width: Theme.folderTreeWidth); Divider; AlbumGridView }` (mirrors `FoldersView`).
- `AlbumsListView` (sidebar): list of albums (cover thumb + name + count), selection bound to `selectedAlbumID`, a "＋ New Album" header button, per-row context menu: **Rename…**, **Delete Album…**, and it is a `.dropDestination` so dragging photos onto an album row adds them.
- `AlbumGridView` (detail): `MediaTile` grid of `itemsInAlbum(selectedAlbumID)`; **drag-to-reorder** (writes `reorderAlbum`); a `SelectionActionBar` with **Remove from Album**, Share, Tag, and the standard actions; per-tile context menu includes **Set as Album Cover** and **Remove from Album**.
- **Empty / onboarding state (faint, on-page, no popup):** when there are no albums, or no album is selected, `AlbumGridView` shows centered, low-opacity explanatory text distinguishing albums from folders, e.g.:
  > **Albums vs Folders**
  > Folders are where your photos physically live on disk — each photo sits in exactly one folder, and moving it changes its location.
  > Albums are flexible collections — add a photo to as many albums as you like (Birthdays, Esoteric, Show Sister) without moving or copying the file.
  > Deleting an album never deletes the photos.

  Rendered as faint `Theme.textFaint` text watermark-style in the grid background (same spirit as existing empty states, but explanatory).
- **"Add to Album" everywhere photos are selected:** a new optional `albumControls: AnyView?` slot on `SelectionActionBar`, injected by Timeline / Folders / Search as a `Menu("Add to Album…")` listing albums (✓ when all selected are already in it) + "New Album from Selection…". The same menu is offered as a per-photo right-click `.contextMenu` (reusing the established `FaceTileMenu`-style modifier).

### 3.6 Drive sync
Album files reference content hashes; a synced drive holds the same content by hash, so **a straight file copy is correct — no path remapping**. During the existing per-drive sync (alongside the catalog-snapshot write), mirror the source `.openphoto/albums/` to the drive's `.openphoto/albums/`: copy every current album file (atomic/overwrite), and delete drive album files whose id no longer exists on the source (so deletions propagate). One-way; idempotent. Offline drives pick this up on their next connect/sync like everything else.

---

## 4. Data flow

- **Mutation:** UI → `AppState` use-case → update `AlbumRecord` → `AlbumStore.save`/`delete` (sovereign JSON) → `catalog.upsertAlbum`/`deleteAlbumMirror` (mirror) → `refreshAlbums()` + `refreshToken`.
- **Display:** `selectedAlbumID` → `catalog.itemsInAlbum(id)` (order + locked gate) → `AlbumGridView`.
- **Open:** `AlbumStore.loadAll` → `catalog.replaceAlbums` → `albumSummaries`.
- **Sync:** copy `.openphoto/albums/` → drive.

---

## 5. Locked-folder interaction

Album views resolve members through `itemsInAlbum`, which applies `lockedVisibilityClause`: a member whose only instances are in locked folders is hidden when the session isn't revealed (the album simply shows fewer items), and reappears after Touch ID. Counts in the sidebar honor the same gate. Albums themselves are not lockable in v1.

---

## 6. Error handling

- `AlbumStore.loadAll` skips a corrupt/unreadable album file (logs) — one bad file never wipes all albums.
- All writes are atomic + crash-durable (`AtomicFile`).
- A member hash with no browse-visible instance (binned, missing, or fully locked) is silently omitted from the album view — not an error.
- `name` is trimmed and required non-empty; create/rename reject empty.
- Mutations on a missing album id are no-ops (defensive).

---

## 7. Testing (Core unit tests; UI follows the codebase's no-unit-test convention)

- `AlbumRecord` JSON round-trips (incl. null cover/description, ordered members).
- `AlbumStore`: save→loadAll round-trip; a corrupt file is skipped while others load; delete removes one file.
- Catalog mirror: `replaceAlbums` rebuilds; `itemsInAlbum` returns members **in stored order**; a locked-folder member is hidden when `revealLocked=false` and shown when `true`; `addToAlbum` dedups; `reorderAlbum` updates positions; `albumIDsContaining(hash)` is correct; `albumSummaries` counts honor the locked gate.

---

## 8. Out of scope (v1)

Smart/rule-based albums; nested albums / album groups; per-photo XMP membership mirror; exporting/sharing an album as a unit; album-level locking.

---

## 9. Documentation discipline

- Add a normative section to `docs/format/` describing `.openphoto/albums/<id>.json` (the schema in §2) for third-party readers.
- Record the `albums` / `album_members` tables in `docs/format/catalog-schema.md` and bump `Catalog.schemaVersion`.
