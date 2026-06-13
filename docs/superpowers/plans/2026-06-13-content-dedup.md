# Content Dedup Implementation Plan

> Implements `docs/superpowers/specs/2026-06-13-content-dedup-design.md`. Built inline (interconnected core-model change), TDD on the query layer, build after each stage.

**Goal:** Timeline/Search show one tile per content (a photo in two folders appears once); Folders stay per-instance; the Inspector lists all locations; Duplicates = exact same-content files (folder/global scope); timeline delete removes all copies, folder/duplicate delete removes one.

---

### Stage 1 — Query layer (Core, TDD)
**Files:** `Catalog/Queries.swift`, `Search/Catalog+Search.swift`, `Catalog+PHash.swift`; test `Tests/.../DedupQueryTests.swift`.

- Rename the shared union: `timelineSQL` → `instanceSQL` (per-instance, unchanged). Add `browseSQL` = same but the local branch keeps only one instance per hash: `AND i.rowid = (SELECT MIN(rowid) FROM instances i2 WHERE i2.hash = a.hash)` (drive branch already dedupes).
- Route: `timelineItems`, `item(hash:)`, `knownSizeDateKeys`, all `Catalog+Search` fetches → `browseSQL`. `items(inDir:)`, `items(instanceIDs:)`, `Catalog+PHash` → `instanceSQL`.
- Add `DuplicateScope { withinFolder, anywhere }` + `duplicateInstanceGroups(scope:) -> [[String]]` (instanceID groups of 2+ same-hash files; withinFolder also same dirPath).
- **Tests:** a hash with 2 local instances → `timelineItems` yields 1 row, `items(inDir:)` for each folder yields it; `duplicateInstanceGroups(.withinFolder)` groups same-folder same-hash, excludes cross-folder; `.anywhere` includes cross-folder.

### Stage 2 — Grid identity → hash (timeline + search)
**Files:** `Timeline/TimelineView.swift`, `Search/SearchView.swift`.
- ForEach/MediaTile/SelectableItem ids for these two grids use `item.hash` instead of `instanceID` (dedup makes hash unique here). Folders keep `instanceID`.

### Stage 3 — Inspector all locations
**Files:** `Inspector/InspectorView.swift`.
- Replace the single "Locations" file row with a list over `catalog.instances(forHash:)` (folder + filename per instance) + drive copies. Reveal-in-Finder per instance.

### Stage 4 — Duplicates = exact content + scope toggle
**Files:** `AppState.swift` (`CullGroup`, `loadCullGroups`), `Cleanup/CleanupView.swift`.
- `CullGroup` keeper/evict become **instanceID**-based (`keepInstanceID`, `suggestedEvict: Set<instanceID>`). Bursts/Similar map their keeper hash → that item's instanceID; Duplicates use `duplicateInstanceGroups(scope:)` → keeper = first instance, evict = rest.
- Add `cullDuplicateScope` to AppState; CleanupView shows a Within-folder/Anywhere segmented toggle in Duplicates mode and reloads on change.
- CleanupView keeper/seed/allSuggested compare `instanceID` not `hash`.

### Stage 5 — Delete semantics
**Files:** `AppState.swift`, `Timeline/TimelineView.swift`, `Viewer/ViewerView.swift`, `Inspector/InspectorView.swift`.
- Add `deletePhotos(_:)` (content-scoped): expand each item to ALL instances of its hash (via `instances(forHash:)` → `items(instanceIDs:)`) and bin them.
- Timeline grid delete, viewer/inspector delete (`removeOpenedItem` closures) → `deletePhotos`. Folders + Cleanup/Duplicates keep instance-scoped `delete`.

### Stage 6 — Full test suite + release
- `swift test`; then bump VERSION 0.1.7, commit, push, `scripts/release.sh` (rotate + dedup together).
