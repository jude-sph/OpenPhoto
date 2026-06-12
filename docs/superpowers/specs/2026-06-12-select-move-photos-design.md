# Select & Move Photos (Folders screen) — Design

**Status:** approved (Jude, 2026-06-12) — build end-to-end (spec → plan → subagent-driven implementation). Phase 5.5 slice 1.

**Goal:** Organize a flat import: in the Folders screen, multi-select photos (rubber-band drag) and move the selection into another folder — either by dragging it onto a folder in the left tree, or by picking a destination from a dropdown and clicking Move. Files physically move inside the vault (with sidecars and Live-pair partners), mirrored to durable drives exactly like folder reorg.

**Architecture in one line:** the existing Folders-screen Select mode gains two move affordances (drag-to-move toggle + destination dropdown), backed by a new file-grain `VaultReorganizer.moveFile` primitive and the **existing** folder-reorg propagation machinery (connected drives now, offline drives queued, presence cache rekeyed, one rescan).

---

## 1. Scope & decisions (from the brainstorm)

- **Extend the existing Select mode** (Jude, brainstorm Q1) — no separate "organize mode". The Folders screen already has Select → rubber-band drag-select (additive) → `SelectionActionBar`. That bar gains the move controls, in the Folders screen only. The Timeline screen is untouched.
- **Drive-only photos move too** (Jude, brainstorm Q2) — full parity with folder moves. A photo freed from the Mac but kept on the canonical drive moves on the drive (now if connected, queued if offline) and appears in its new folder immediately via a presence-cache rekey.
- **Two independent move mechanisms**, per Jude's original design:
  - **(a) Drag onto the left tree:** a "Drag to move" toggle flips grid dragging from rubber-band-select to dragging the selection; drop onto any folder row in `FolderTreeView` (reusing its existing drop-target highlight).
  - **(b) Dropdown + Move button:** a destination picker exactly like the import screen's (folder dropdown + "New folder…" text field), plus a **Move** button.
- **No on-disk format change.** Files move within the vault; the vault manifest entry's `path` updates (already-specified manifest semantics). No catalog `schemaVersion` bump: the offline-drive queue reuses `pending_folder_ops` with a new op-kind **string** `"moveFile"` (the `op` column is TEXT). If `docs/format/catalog-schema.md` documents op kinds, it gains `"moveFile"` in the same commit.
- **No undo system.** Nothing is destructive — a move is reversed by moving back. Collisions auto-rename (never overwrite, never prompt).

---

## 2. Core — per-photo atomic move primitive

### 2.1 `VaultReorganizer.moveFile`

File-grain sibling of `moveFolder`, same file (`Sources/OpenPhotoCore/Vault/VaultReorganizer.swift`):

```swift
static func moveFile(in vault: Vault, relPath: String, intoDirRelPath: String) throws -> String
```

- Validates: source exists (else `.missing`); destination dir exists (else `.invalidTarget`); a same-dir move returns the input path unchanged (no-op).
- Destination name is collision-safe: the existing `collisionFreeURL` logic (today duplicated privately in `ImportEngine` and `VolumeCopyDestination`) is **extracted to a shared internal helper** (e.g. `FileNaming.collisionFreeURL(for:in:)`) and reused here — `IMG_1.jpg` → `IMG_1 (2).jpg`.
- Atomic `FileManager.moveItem` (same-volume rename; carries Finder-tag xattrs natively).
- Moves the sidecar `.openphoto/<name>.xmp` if present → destination's `.openphoto/` dir (created on demand), renamed to match any collision-renamed media name.
- Rewrites that one entry's `path` in the vault `manifest.jsonl` (read → update matching entry → atomic `Manifest.write`), preserving hash/size/mtime. A file absent from the manifest moves anyway (manifest catches up at rescan).
- Returns the new relPath.

### 2.2 Live-pair carry (LibraryService)

`LibraryService.movePhotos(_ items: [TimelineItem], toDir: String)` handles the batch for **local** instances:

- For each item: `moveFile` the photo. If `livePairHash` is set, look up the partner video's instance in the same vault (same lookup the delete path uses) and `moveFile` it too, with its own sidecar and its own collision-safe name. Grids only ever surface the photo half (`isLivePairedVideo` rows are hidden), so pairs can't be half-selected.
- Items whose `dirPath` already equals the destination are skipped.
- Per-file failures are collected and the batch continues; the function returns `(moved: [String: String] /* old→new relPath */, failures: [(relPath, Error)])`.
- **No incremental catalog surgery**: after the batch (and drive propagation), the caller runs one `rescan()` — the proven reconciliation pattern.

---

## 3. Drive parity (mirrors `AppState+FolderReorg` exactly)

New `AppState.movePhotos(_ items: [TimelineItem], into dest: String)` (in `AppState+FolderReorg.swift` or a sibling extension), shaped like `moveFolder(from:into:)`:

1. **Mac primary vault first:** `LibraryService.movePhotos` for all items with a local file (`driveRelPath == nil`).
2. **Connected durable drives** (off-main, `Task.detached`): for each moved file (including Live partners), if the drive holds the file at the mapped old path (`<sourceVaultBasename>/<relPath>`, NFC), `moveFile` it on the drive vault into the mapped destination dir. Skips silently if absent (next send places it at the new path).
3. **Offline durable drives:** enqueue one op per moved file: `enqueueFolderOp(vaultID:, op: "moveFile", src: oldRelPath, dst: newRelPath)` (Mac-aligned relPaths, as folder ops are). `applyPendingFolderOps` gains a `"moveFile"` case: map both paths to drive form, `moveFile` into `dst`'s parent dir; a `.missing` source means the drive never had it — count the op handled. Unknown op kinds still fall through untouched (older queues stay safe).
4. **Drive-only items** (`driveRelPath != nil`, no local file): rekey their `vault_presence` row to the destination dirPath via a new file-grain catalog op (`rewriteVaultPresencePath(vaultID:fromRelPath:toDir:)`, sibling of the existing dir-grain `rewriteVaultPresencePaths`) so the photo appears in its new folder immediately; connected drive → move the drive file now (step 2 path), offline → enqueue `"moveFile"` (step 3).
5. `reloadCanonicalPresence()`, then one `rescan()`. `selectedFolder` is unchanged (the user stays put); no UI path remap needed (no folder paths changed).
6. Errors: aggregate failures into **one** `NSAlert` summary at the end (count + first few file names); successes are silent.

**New-folder destination:** the action bar's "New folder…" path calls the existing `createFolder(named:under:)` first (which already propagates + queues), then runs the move into it.

---

## 4. UI — Folders screen

### 4.1 `SelectionActionBar` additions (Folders screen only)

The bar (Select mode active) gains, alongside Send/Delete/Evict/Rehydrate:

- **Destination picker + Move:** the import screen's pattern — `Picker` listing all folders from `state.folderTree` (recursively collected, sorted) + a "New folder…" `TextField` + a **Move** button. Move is enabled when the selection is non-empty and a destination is chosen (or a new-folder name typed). The picker excludes nothing: moving into the current folder is simply a per-item skip.
- **"Drag to move" toggle** (button-style `Toggle`, like the toolbar's "Include subfolders"). Resets to off when Select mode exits.

The Timeline's `SelectionActionBar` usage is untouched — the bar gains an optional `@ViewBuilder` extra-controls slot (default empty); `FolderGridView` passes the move controls into it, `TimelineView` passes nothing.

### 4.2 Grid drag behavior

- Toggle **off** (default): exactly today's behavior — rubber-band select.
- Toggle **on**: the `RubberBandModifier` gesture is disabled; tiles become draggable. Dragging a **selected** tile carries the whole selection; dragging an **unselected** tile carries just that tile (Finder-like). Checkbox taps still toggle selection.
- The drag payload is the list of selected `instanceID`s, encoded so the tree can tell photo drops from folder drops (see 4.3).

### 4.3 `FolderTreeView` drop handling

Folder rows currently accept `String` drops carrying a folder path (`.dropDestination(for: String.self)` → `state.moveFolder`). SwiftUI allows only one effective `dropDestination` per view, so the photo payload **shares the String channel with a marker prefix**: the grid drags `"photos:" + JSON([instanceID])`. The row's existing drop closure branches:

- payload starts with `"photos:"` → decode IDs, resolve to `TimelineItem`s from the current grid items, call `state.movePhotos(items, into: node.path)`;
- otherwise → existing folder-move validation + `state.moveFolder`.

The root drop targets (header + empty space) gain the same branch (move photos to library root). The existing `dropTargeted` row highlight works unchanged.

### 4.4 After a move

Stay in the current folder; moved items vanish at rescan; selection clears; Select mode stays on; "Drag to move" stays as the user left it. No success toast — same silent-success convention as folder moves.

---

## 5. Error handling

- Per-file move failures (vanished file, permission) collect; batch continues; one summary `NSAlert` at the end. Zero-failure batches are silent.
- Collisions never error — auto-rename via the shared collision-free helper (applies independently on Mac and each drive; paths may legitimately diverge in rare collision races, reconciled by normal sync verification).
- Same-folder destination and already-in-destination items: silent skips.
- Drive copy of a file missing at the mapped path: silent skip (sync places it later).
- Queued `"moveFile"` op whose source is missing on connect: counted as handled (mirrors the folder-delete `notEmpty` leniency).

---

## 6. Testing

Core TDD (generated media in `TestDirs` only — never real user data):

- `VaultReorganizer.moveFile`: file+sidecar move, manifest entry rewrite, collision rename (media + sidecar stay matched), same-dir no-op, `.missing`/`.invalidTarget` errors.
- Shared `FileNaming.collisionFreeURL` extraction: `ImportEngine`/`VolumeCopyDestination` behavior unchanged (existing import tests stay green).
- `LibraryService.movePhotos`: Live-pair partner carried (photo+video+both sidecars), skip-already-in-destination, failure aggregation, rescan lands instances at new paths.
- Catalog: `rewriteVaultPresencePath` (file-grain rekey), `enqueueFolderOp`/`pendingFolderOps` round-trip with op `"moveFile"`.
- Queue replay: `applyPendingFolderOps`-equivalent core logic for `"moveFile"` (drive-vault move on connect; missing source handled). App-layer glue build-verified.

App layer (action bar, drag toggle, tree drop branch) is **build-verified** (0 warnings, both `swift build` and `swift build --build-tests`), validated by Jude live — consistent with every prior slice.

---

## 7. Out of scope

- Timeline-screen moves; moving between vaults; undo; progress UI for huge batches (moves are same-volume renames — effectively instant); folder-grain anything (exists already).
