# Undo Stack + Shift-Drag Deselect + Person Cover — Design & Plan (combined, compact)

**Status:** approved (Jude, 2026-06-12) — three small features, one slice, deliberately lightweight doc per Jude's direction. The undo stack carries the slice's safety burden: *simple, vetted, no chance of negative side effects*.

---

## 1. Shift-drag deselect

Rubber-band drags are additive everywhere (Folders, Timeline, Import, Person grids). New: **holding ⇧ at drag start latches the drag into subtract mode** — swept tiles (and their Live partners) are *removed* from the selection. One drag is consistently add or remove; shift-*click* range-extend is untouched (separate gesture).

- Core (TDD): `SelectionModel.beginDrag(subtracting: Bool = false)` stores the mode; `updateDrag` removes intersecting ids (+partners) when subtracting. Default keeps every existing call site compiling/behaving identically.
- App: `RubberBandModifier.dragGesture.onChanged`, at the `dragRect == nil` first tick: `selection.beginDrag(subtracting: NSEvent.modifierFlags.contains(.shift))`. All grids inherit.

## 2. Undo (⌘Z) — safety-first design

**The invariant: undo introduces ZERO new file operations.** It records small **data-only descriptors** and, on undo, replays *existing, already-tested public operations* with inverse arguments. Stale state can only make an inverse fail the same way it would fail a human — `.missing`, rename-conflict, not-in-bin — never overwrite, never force (collision renames still apply).

### Integration: the native UndoManager (not a custom ⌘Z)
A custom Edit-menu ⌘Z would steal undo from text fields (rename field, captions) — a forbidden side effect. Instead each recorded action registers with the **window's `UndoManager`** (`levelsOfUndo = 50`, `setActionName` → the system menu reads "Undo Move 12 Photos"). Focused text fields keep their own field-editor undo automatically. **No redo:** `applyUndo` never registers anything (guarded by an `isApplyingUndo` flag — also prevents the replayed ops from re-recording themselves), so Redo stays disabled and ⌘Z simply walks history back. Session-scoped, in-memory, nothing persisted, no format/catalog impact.

### Descriptors (Core, `Sources/OpenPhotoCore/Selection/UndoAction.swift`, TDD)

```swift
public struct MovedFileRecord: Sendable, Equatable {
    public let vaultID: String
    public let from: String   // relPath before the user's action
    public let to: String     // relPath after it
}
public enum UndoAction: Sendable, Equatable {
    case deletePhotos(hashes: [String], count: Int)   // asset hashes incl. Live partners; count = user-facing photo count
    case movePhotos(moves: [MovedFileRecord])
    case moveFolder(from: String, to: String)
    case rename(vaultID: String, relPath: String, oldName: String)  // relPath = the CURRENT (post-rename) path
    public var label: String { … }  // "Delete 3 Photos" / "Move 12 Photos" / "Move Folder" / "Rename"
}
public enum UndoPlan {
    /// Inverse plan for a photo move: group by origin dir → [(destDir, instanceIDs at the NEW paths)].
    public static func inverseMoveGroups(_ moves: [MovedFileRecord]) -> [(destDir: String, ids: [String])]
}
```

### What records, what replays (all existing ops)

| Action (record site, AppState) | Descriptor content | `applyUndo` replays |
|---|---|---|
| `delete(_:)` | items' hashes + their `livePairHash`es, photo count | `binItems()` filtered by hash → `LibraryService.restore` each (re-dequeues drive-removal review; Live pair handled by restore) |
| `movePhotos(ids:into:)` | `result.moved` (primary vault) + the drive-only rekeys, as `MovedFileRecord`s | `movePhotos(ids:into:)` once per origin-dir group (full drive parity rides along) |
| `moveFolder(from:into:)` | from/to paths | `moveFolder(from: to, into: parentOf(from))` |
| new `rename(_:to:)` wrapper (InspectorView switches to it) | vaultID + new relPath + old name | resolve via `catalog.items(instanceIDs:)` → `LibraryService.rename` back |

Failure handling: each inverse path collects what it couldn't do (entry no longer in bin, file gone, name re-occupied) into one calm alert ("Couldn't undo N item(s) — things changed since"). Excluded by design: folder delete (composite; Bin UI restores), evict/rehydrate, imports/sends, folder create.

### Wiring
`AppState` gains `weak var windowUndoManager: UndoManager?` (captured in `RootView` via `@Environment(\.undoManager)` + `.task`/`.onChange`), `private var isApplyingUndo`, `recordUndo(_:)` (no-op when nil manager or applying), `applyUndo(_:) async`.

## 3. Person cover ("Use as Thumbnail")

In a person's detail grid, the photo tile's existing context menu gains **"Use as Thumbnail"**: sets that face as the person's cover on the People screen.

- **Catalog v12** (the slice's one schema change; `catalog-schema.md` updated in the SAME commit): `people` gains nullable `coverFaceID` (→ `faces.id`). `Catalog.schemaVersion` 11 → 12.
- `people()` picks `rep = COALESCE((cover face IF it still belongs to this person), (highest-confidence face))` — a reassigned/removed cover face falls back automatically, no dangling state.
- `setPersonCover(personID:faceID:)` setter (Core, TDD with the COALESCE fallback cases).
- App: context-menu item in `FacePhotoTile` → `state.setPersonCover` → people reload; `PersonCard` keeps rendering `representativeFaceID` (now cover-aware) unchanged.
- **Sovereignty note:** the cover choice is a Mac-local *display preference* (mirror-grade, like `people.name` it sits in the rebuildable catalog; unlike names it has no sidecar home — person-level, not photo metadata). A full catalog rebuild loses the cover (names survive via sidecars); accepted. Snapshot readers MAY ignore the column (documented).

## 4. Tasks (subagent-driven; usual hard rules — CLT only, 0 warnings, TDD for Core, exact trailers)

1. **U1 (Core TDD + 1 App line):** SelectionModel subtract mode + RubberBandModifier shift read. Tests: subtract removes swept ids + partners; default beginDrag unchanged; add-mode regression.
2. **U2 (Core TDD):** `UndoAction` + `UndoPlan.inverseMoveGroups` + labels. Tests: grouping by origin dir (multi-dir moves), instanceID composition (`vaultID|newRelPath`), label strings, Equatable.
3. **U3 (App, build-verified):** AppState undo wiring — `windowUndoManager` capture in RootView, `recordUndo`/`applyUndo`/`isApplyingUndo`, recording in `delete`/`movePhotos`/`moveFolder`, new `rename` wrapper + InspectorView switch. Recording only after success; `applyUndo` records nothing.
4. **U4 (Core TDD + format doc, SAME commit):** Catalog v12 `coverFaceID` + `setPersonCover` + cover-aware `people()` with fallback; `docs/format/catalog-schema.md` schemaVersion + people-table + snapshot-reader notes.
5. **U5 (App, build-verified + make-app):** FacePhotoTile "Use as Thumbnail" menu item + `AppState.setPersonCover` + reload.
6. **U6 (docs):** master spec §10.5 item 3 DONE (+ cover noted) + changelog.
7. Final whole-slice review (undo safety is the focus) → merge `--no-ff` (message FILE) → push (pre-authorized).

**Testing note:** the undo descriptors/plan and the catalog change are Core-TDD'd; `applyUndo` is thin dispatch onto ops that all have existing test coverage (restore, movePhotos, moveFolder, rename) — it is build-verified plus Jude's live ⌘Z pass. Stale-undo safety rests on the *existing* failure modes of those ops, which is the point of the design.
