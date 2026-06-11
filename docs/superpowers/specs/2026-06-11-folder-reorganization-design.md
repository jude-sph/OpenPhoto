# Folder reorganization (drag-drop nest / create / delete) — design

**Date:** 2026-06-11
**Branch:** `folder-reorg`
**Status:** Approved (autonomous — Jude asked for this built; key decisions documented here for his sign-off)

> In the Folders view: **drag a folder onto another to nest it**, **create** a new folder, and **delete** a folder — all moving the **real underlying folders/files** on disk. "The library is just files," so reorganizing the library means reorganizing the actual vault directories.

---

## 1. Goal & scope

Let the user reorganize their library's folder structure directly: nest folders by drag-drop, create empty folders, delete folders. Operations mutate the real Mac vault (atomic on-disk moves, catalog + manifest updates) and stay consistent with connected canonical/backup drives.

### Key decisions (the non-obvious ones — flagged for sign-off)

1. **Drives must stay path-aligned (the critical one).** The canonical sync (`SyncEngine.plan`) is keyed by **path, not hash** — a Mac-only folder move would, on the next sync, **copy the moved files to the drive at their new paths while the old-path copies remain** (duplication), because a hash already on the drive at a different path is not skipped. So a reorg operation **propagates to every *connected* durable drive** (canonical + backups): it performs the same structural move/create/delete on the drive and rewrites the drive's `manifest.jsonl`, keeping paths aligned so the next sync is a no-op. This is an explicit-user-action structural change (like deletion propagation), not "merge logic" — invariant #5 holds in spirit (the drive only ever receives Mac-driven changes).
2. **Disconnected durable drives → v1 warns, defers a queue.** If a durable drive that holds the folder is **not connected**, v1 **warns** ("<Drive> is offline; reorganize it after reconnecting, or its copy may duplicate on next sync — Continue / Cancel") and proceeds on the Mac + connected drives only. A persistent **pending-folder-ops queue** that auto-applies on connect (mirroring `pending_deletions`) is the documented **follow-up** (out of v1). Rationale: Jude's setup is a single, usually-connected canonical, so the common path is fully safe; the queue is real work for an uncommon case.
3. **Empty folders must be visible.** The folder tree is **catalog-derived** today (built from photo instance paths), so empty/just-created folders don't appear. v1 makes `folderTree` **also include real filesystem directories** under the vault root (dir-only walk, skipping `.openphoto/` + hidden), unioned with the catalog counts. Cheap, and it makes the tree reflect filesystem truth — consistent with the sovereignty model.
4. **Delete = move media to the bin, never hard-delete (invariant #3).** Deleting a folder bins all its media (the existing `LibraryService.delete` path → `.openphoto/bin/`, queues `pending_deletions` for drive review) and then removes the now-empty real directory. An empty folder deletes its directory directly.
5. **Single primary vault only.** Reorg targets the Mac's **primary** local vault (the one whose tree the Folders view shows). Multi-local-vault reorg is out of scope.

### Non-goals (v1)
- The pending-folder-ops queue for disconnected drives (decision 2 — follow-up).
- Reorganizing across separate local vaults; moving the canonical onto the Mac.
- Multi-folder / multi-select drag (one folder at a time).
- Undo (the bin covers delete; moves are reversible by dragging back).

---

## 2. Architecture

### Core (`OpenPhotoCore`, TDD)

**`VaultReorganizer` (`Sources/OpenPhotoCore/Vault/VaultReorganizer.swift`)** — pure, testable filesystem+manifest ops on one `Vault`:
- `moveFolder(relPath:intoParentRelPath:) throws -> String` — validates (not moving into self/descendant; destination free), `FileManager.moveItem` the directory subtree (atomic same-volume `rename`; sidecars in each dir's `.openphoto/` travel with it), then rewrites the manifest: every entry whose `path` is under `relPath/` gets its prefix rewritten to `<newParent>/<lastComponent>/…`. Returns the new relPath. Refuses if the destination path already exists (collision → error surfaced to the caller).
- `createFolder(relPath:) throws` — `createDirectory(withIntermediateDirectories:)`; no manifest change (empty).
- `deleteEmptyFolder(relPath:) throws` — refuses if the directory still contains media (caller bins first); removes the empty directory (and its empty `.openphoto/` if present).
- All paths NFC-normalized, "/"-separated, validated to stay within the vault root (no `..` escape).

**`LibraryService.folderTree()` change** — union the catalog-derived folders (existing `folderCounts`) with a **filesystem directory walk** of the primary vault (`directoriesUnder(root:)`, skipping `.openphoto`/hidden), so empty/created dirs appear as zero-count nodes. Existing zero-count-ancestor materialization stays.

### App (`OpenPhotoApp`)

**`AppState` reorg orchestration (`AppState+FolderReorg.swift`)** — each method: (a) runs the `VaultReorganizer` op on the primary vault, (b) **for each connected durable drive that holds the folder**, runs the matching op on the drive (move the drive folder via the drive-relpath mapping + rewrite the drive manifest), (c) `await rescan()` (rebuilds catalog instances + `folderTree`), (d) fixes up `selectedFolder` / `expandedFolders`, (e) if a durable drive is disconnected, shows the decision-2 warning first.
- `moveFolder(from:into:) async`
- `createFolder(named:under:) async`
- `deleteFolder(_ path:) async` — bins the folder's media (`items(inDir:recursive:true)` → `delete`), then removes the empty dir on Mac + connected drives.

**`FolderTreeView` UI**:
- Each `FolderRow` gains `.draggable(node.path)` + `.dropDestination(for: String.self)` that calls `state.moveFolder(from:into:)`, with a drop-highlight on the row. Reject self/descendant drops.
- A **context menu** on each row: "New Folder Inside…", "Delete Folder…". A small **"New Folder"** affordance at the tree's top creates at root.
- Create uses a tiny inline text field / sheet for the name; Delete uses a confirmation (`N` items will move to the Bin).

---

## 3. Data flow (move)

```
drag "rome2022" onto "trips" →
  AppState.moveFolder(from:"rome2022", into:"trips")
   ├─ (warn if a durable drive holding "rome2022" is offline) → Cancel aborts
   ├─ VaultReorganizer.moveFolder on primary vault:
   │    rename rome2022 → trips/rome2022 (dir subtree, sidecars included)
   │    manifest: path "rome2022/…"  →  "trips/rome2022/…"  (full atomic rewrite)
   ├─ for each connected durable drive that has "rome2022":
   │    rename <driveRoot>/<vaultBasename>/rome2022 → …/trips/rome2022 + rewrite drive manifest
   ├─ await rescan()  → Scanner rebuilds instances (new dirPath/relPath) + folderTree
   └─ expandedFolders/selectedFolder: "rome2022*" → "trips/rome2022*"
```

Create: mkdir on Mac + connected drives → folderTree shows the empty dir. Delete: bin media (→ pending_deletions for drive review) → remove empty dirs on Mac + connected drives.

---

## 4. Error handling / edge cases

| Case | Behavior |
|---|---|
| Drop onto self or a descendant | Rejected (no-op); the drop is refused in the UI predicate. |
| Destination already has a folder of that name | Refuse with a surfaced error ("A folder named X already exists there"). No merge. |
| A durable drive holding the folder is offline | Warn + confirm (decision 2); proceed on Mac + connected drives only. |
| Delete a folder with media | Media → Bin (recoverable; `pending_deletions` queued for drive review); then empty dirs removed. |
| Move/rename mid-flight failure | The on-disk `moveItem` is atomic (same-volume rename); manifest rewrite is atomic (`AtomicFile`). A drive-propagation failure leaves the Mac moved + that drive stale → surfaced; re-runnable. |
| Cross-volume move (vault on a different volume than dest — N/A within one vault) | Same vault root ⇒ same volume ⇒ atomic rename always. |
| Empty folder (no media) | `createFolder`/`deleteEmptyFolder`; no manifest/bin involvement. |

---

## 5. Testing

**Core (TDD, temp vaults + generated fixtures, never `~/Pictures`):**
1. `VaultReorganizer.moveFolder` — build a temp vault with `a/x.jpg` (+ sidecar) and a manifest; move `a` into `b`; assert the file is at `b/a/x.jpg` on disk, the sidecar moved, and the manifest entry path rewrote (hash/size unchanged). Moving into self/descendant throws; destination-collision throws.
2. `createFolder` / `deleteEmptyFolder` — dir appears/removed; delete refuses when non-empty.
3. `folderTree` includes a real empty directory (zero-count node) not present in the catalog.
4. Manifest prefix-rewrite correctness for nested subtrees (`a/b/c.jpg` → `dest/a/b/c.jpg`).

**App:** build-verified + manual — drag a folder to nest it (files move on disk + drive); create/delete; confirm the connected canonical mirrors the change (no duplication on a follow-up sync); delete bins the media.

---

## 6. Task decomposition (for the plan)

1. **Core (TDD)** — `VaultReorganizer` (move/create/deleteEmpty + manifest rewrite + validation). Tests 1–2, 4.
2. **Core (TDD)** — `folderTree` filesystem-dir union (empty folders visible) + `directoriesUnder`. Test 3.
3. **App** — `AppState+FolderReorg` (Mac op + connected-drive propagation + rescan + UI-state fixups + offline-drive warning), reusing `delete` for folder-delete binning.
4. **App** — `FolderTreeView` drag-drop + create/delete context menu + confirmations; rebuild bundle.
5. **Docs** — `vault-format-v1`/`catalog-schema` need **no change** (no new on-disk artifact; manifest schema unchanged — only path values move). Record the feature + the **decisions 1–2** (drive propagation; disconnected-drive deferral) in the master spec changelog so the sync-interaction contract is documented.

No catalog migration. `Scanner`/`MetadataExtractor`/`ThumbnailStore` untouched; `SyncEngine`/`Manifest`/`BinStore` are **used**, not modified (manifest rewrite uses the existing `Manifest.write`; binning uses existing `delete`).
