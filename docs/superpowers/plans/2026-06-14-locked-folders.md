# Locked folders (Touch ID) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** App-level Touch-ID-locked folders — locked folders' photos vanish from every browse surface until the user authenticates, then reappear for the session. Files stay plaintext on disk (casual-snooping threat model).

**Architecture:** Per-instance `locked` flag (migration v16) derived from a persisted locked-folder list; a single in-memory `Catalog.revealLocked` switch gates whether user-facing browse queries filter locked rows. Touch ID (LocalAuthentication) flips it for the session. Mirrors the already-shipped reversible `hidden`-faces flag, library-wide.

**Reference spec:** `docs/superpowers/specs/2026-06-14-locked-folders-design.md`
**Direct precedent in-repo:** the faces `hidden` flag (migration v15, `setFacesHidden`, `AND hidden = 0` filters) — same shape; follow it.

---

### Task 1: Core — migration v16, `locked` projection, `revealLocked`, `applyLockedFolders`, browse filters (TDD)

**Files:** `Catalog.swift` (migration), `Queries.swift` (projections + filters + new methods), new `Tests/OpenPhotoCoreTests/LockedFoldersTests.swift`.

- [ ] **Step 1: Migration v16.** In `Catalog.swift`, after the `"v15"` migration:
```swift
        migrator.registerMigration("v16") { db in
            // Per-instance "locked" flag for app-level Touch-ID-hidden folders. Derived (rebuildable)
            // from the locked-folder list; gates browse visibility only — NOT encryption.
            try db.alter(table: "instances") { t in
                t.add(column: "locked", .integer).notNull().defaults(to: 0)
            }
        }
```

- [ ] **Step 2: Thread `locked` through the shared projections** (`Queries.swift`):
  - `localSelect`: add `i.locked` to the column list (after `i.size`).
  - `driveSelect`: add `0 AS locked` to the column list (drive-only rows are never locked in v1).
  Now `browseSQL`/`instanceSQL` expose a `locked` column. (Internal callers like `knownSizeDateKeys` keep working — they just don't reference it.)

- [ ] **Step 3: `revealLocked` flag + `applyLockedFolders` + a lock filter helper** (`Queries.swift` or `Catalog.swift`):
```swift
    /// When false (default), the user-facing browse methods hide locked rows. The App flips it true
    /// for the session after Touch ID. In-memory only — re-locks naturally on quit.
    public var revealLocked: Bool {
        get { lock.withLock { _revealLocked } }
        set { lock.withLock { _revealLocked = newValue } }
    }
```
(Add a private `_revealLocked = false` + reuse the catalog's existing lock, or a dedicated `NSLock`. If `Catalog` has no instance lock, add one.) Plus:
```swift
    /// SQL fragment appended to user-facing browse queries. Empty when revealed.
    var lockedFilter: String { revealLocked ? "" : "AND locked = 0" }

    /// Re-derive instances.locked from the locked-folder list: clear all, then mark instances whose
    /// dirPath equals or is nested under a locked folder (same GLOB match the Folders view uses).
    public func applyLockedFolders(_ dirPaths: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE instances SET locked = 0")
            for p in dirPaths {
                try db.execute(sql: "UPDATE instances SET locked = 1 WHERE dirPath = ? OR dirPath GLOB ?",
                               arguments: [p, p + "/*"])
            }
        }
    }
```

- [ ] **Step 4: Filter the user-facing browse methods** in `Queries.swift`. Append the lock filter where each wraps a shared projection (mind `WHERE` vs `AND`):
  - `timelineItems`: the outer `SELECT * FROM (browseSQL)` — add `WHERE locked = 0` (conditionally) before the `videoOnly`/`ORDER BY`. Restructure so the filter and `videoOnly` compose (e.g. build a `[String]` of conditions).
  - `items(inDir:vaultID:recursive:)`: it already has a `WHERE` — append ` \(lockedFilter)`.
  - `items(instanceIDs:)`: append the lock filter to its `WHERE`.
  - `item(hash:)`: append the lock filter (a locked item must not resolve into the viewer while hidden).
  - `folderCounts(...)`: filter locked instances out of the per-folder counts.
  - `duplicateInstanceGroups(scope:)`: exclude locked instances.
  - `librarySize()`: reflect the revealed set (user-facing count).
  - Leave **unchanged**: `knownSizeDateKeys()` (import dedup), anything under derivation/scan/sync/integrity.

- [ ] **Step 5: Tests** (`LockedFoldersTests.swift`). Build a temp catalog with assets+instances in two folders (use the existing catalog test helpers — grep `TestDirs`/`CatalogIngestTests` for how to insert assets+instances). Assert:
  - `applyLockedFolders(["/A"])` sets `locked=1` for instances under `/A` (incl. `/A/sub`), `0` elsewhere.
  - With `revealLocked = false`: `timelineItems()` and `items(inDir: "/A")` exclude the locked rows; `folderCounts` omits them; `duplicateInstanceGroups` excludes them.
  - With `revealLocked = true`: all rows return.
  - `knownSizeDateKeys()` is UNAFFECTED (still includes locked — import dedup must see them).
  - `applyLockedFolders([])` clears all locks.

- [ ] **Step 6:** `swift test --filter LockedFolders` (pass) + `swift test` (full suite green) + commit.

---

### Task 2: Core — filter faces/people, search, and map (TDD)

**Files:** `Catalog+Faces.swift`, `Catalog+Search.swift` (find it), `Catalog+Derivation.swift` (searchOCR), `Catalog+Geocode.swift`, append to `LockedFoldersTests.swift`.

A face/photo is locked iff it has a locked instance and no unlocked instance (match `browseSQL`'s "visible" notion: a photo is visible if it has any non-locked instance). Define a reusable predicate:
```swift
    /// True for a hash with at least one non-locked instance (matches browse visibility). Used to
    /// keep locked photos' faces/markers/search-hits out of the revealed-gated surfaces.
    /// In SQL: `EXISTS (SELECT 1 FROM instances i WHERE i.hash = <hash> AND i.locked = 0)` OR revealed.
```

- [ ] **Step 1 (TDD):** write tests first (faces of a locked photo absent from `unassignedAutoFaceIDs`/`people` when `!revealLocked`; map coordinate query excludes locked; `searchOCR` excludes locked; all return when revealed).
- [ ] **Step 2:** add `AND (\(revealLocked) OR EXISTS(SELECT 1 FROM instances i WHERE i.hash = <faceHashCol> AND i.locked = 0))` to:
  - `unassignedAutoFaceIDs`, `unassignedFacesWithEmbeddings`, `faces(forPerson:)`, and the `people()` representative/count query.
  - `searchOCR` (joins hash → text), the semantic-search candidate fetch in `Catalog+Search.swift`, and any filter-search fetch.
  - the geocoded-coordinates query in `Catalog+Geocode.swift` (the `SELECT hash, latitude, longitude, takenAtMs` one — map markers).
  (Use a small `lockedVisibilityClause(hashColumn:)` helper to avoid drift. Internal face mutations — assign/insert/derivation — are NOT filtered.)
- [ ] **Step 3:** filtered-suite + full suite green; commit.

---

### Task 3: App/Core — locked-folder list persistence (`.openphoto/locked-folders.json`)

**Files:** new `Sources/OpenPhotoCore/LockedFolderStore.swift` (Core, testable) + test.

- [ ] A small store that reads/writes a JSON array of relative folder dirPaths at `<libraryRoot>/.openphoto/locked-folders.json` (atomic write via the existing AtomicFile helper — grep `AtomicFile`). API: `load(libraryRoot:) -> [String]`, `save(_ paths:[String], libraryRoot:)`. TDD: round-trip, missing-file → `[]`, add/remove.

---

### Task 4: App — `BiometricGate` (Touch ID)

**Files:** new `Sources/OpenPhotoApp/BiometricGate.swift`.

- [ ] 
```swift
import LocalAuthentication
enum BiometricGate {
    /// Touch ID with automatic password fallback (.deviceOwnerAuthentication). Returns true on success.
    /// Works on Macs without Touch ID (password) and in the ad-hoc-signed bundle — no entitlement needed.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}
```
- [ ] Build verifies (App layer). No Info.plist change (Touch ID on macOS needs none).

---

### Task 5: App — AppState lock state + actions + refresh

**Files:** `AppState.swift` (+ wherever library-open happens).

- [ ] State: `var lockedRevealed = false`. On library open: load the locked list → `library.catalog.applyLockedFolders(list)`; set `catalog.revealLocked = false`, `lockedRevealed = false`.
- [ ] `func isFolderLocked(_ dirPath: String) -> Bool` (against the in-memory list).
- [ ] `func lockFolder(_ dirPath:)` / `func unlockFolder(_ dirPath:)`: edit list → `LockedFolderStore.save` → `catalog.applyLockedFolders` → refresh browse (`refreshQueries()` + people/map/search reload + `refreshToken += 1`). (Adding a lock needs no auth; removing a lock requires `lockedRevealed` — i.e. you must be authenticated to manage locks.)
- [ ] `func revealLockedContent()`: `await BiometricGate.authenticate(...)` → on success `catalog.revealLocked = true; lockedRevealed = true; refresh all browse`. `func relock()`: set both false + refresh.
- [ ] Build verifies.

---

### Task 6: App — Folders context menu + lock badge + sidebar control

**Files:** `Folders/FolderTreeView.swift`, `Folders/FolderGridView.swift`/`FoldersView.swift`, `Sidebar/SidebarView.swift`.

- [ ] Folder tree row: 🔒 badge when `state.isFolderLocked(node.dirPath)`. Context menu: **Lock (Touch ID)** when unlocked, **Unlock** when locked (Unlock gated on `lockedRevealed`, prompting reveal first). Opening a locked folder while `!lockedRevealed` triggers `revealLockedContent()`.
- [ ] Sidebar: a small lock control — when any folder is locked and `!lockedRevealed`, show 🔒 "Locked hidden" → tap → `revealLockedContent()`; when `lockedRevealed`, show 🔓 + **Lock now** → `relock()`. Hide the control entirely when no folders are locked.
- [ ] Build + manual smoke: lock a folder → its photos vanish from timeline/folders/search; unlock via Touch ID → they reappear. (Visual smoke is the user's; the agent's bar is a clean build.)

---

### Task 7: Leak audit + final verification

- [ ] grep every `FROM (\(Self.browseSQL))` / `FROM (\(Self.instanceSQL))` / face/coordinate/OCR/search fetch and confirm each user-facing one applies the lock filter and each internal one intentionally does not. List the classification in the commit message.
- [ ] `swift build` + `swift test` (full green) + `swift build -c debug --arch x86_64` (stays Intel-clean).

---

## Self-review

**Spec coverage:** migration+flag+derive (T1), all browse surfaces — timeline/folders/dedup/counts (T1), faces/people/search/map (T2), persistence (T3), Touch ID (T4), session state+actions (T5), UI (T6), leak audit (T7). ✓
**Internal-not-filtered:** knownSizeDateKeys/derivation/integrity explicitly excluded (T1 step 4, T7). ✓
**Placeholders:** none — concrete SQL/migration/Touch-ID code given; query-filter sites enumerated; tests specified. The face/search exact SQL is left to the implementer to match each query (precedent: the `hidden` filter), with the `lockedVisibilityClause` helper to prevent drift. ✓
**Type/name consistency:** `revealLocked`, `applyLockedFolders`, `lockedFilter`, `lockedVisibilityClause`, `LockedFolderStore`, `BiometricGate`, `AppState.lockedRevealed`/`isFolderLocked`/`lockFolder`/`unlockFolder`/`revealLockedContent`/`relock` used consistently. ✓
