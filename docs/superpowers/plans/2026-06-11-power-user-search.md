# Power-user Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strengthen OpenPhoto's Search with a richer deterministic structured-filter model (multi-person AND, folder/place/camera/tag include+exclude, relative-date presets, kind / people-presence / has-text facets) surfaced through a Simple and a Pro editor over one shared `SearchFilters` state.

**Architecture:** `SearchFilters` (a pure value type) becomes the single source of truth, refactored from single-value fields into include/exclude sets per negatable facet. `Catalog.structuredFilter` composes every facet as parameterised SQL over the existing timeline union (so it reads local ∪ drive-only via the `dirPath` column). `SearchRanker`, `SemanticIndex`, and `runSearch`'s orchestration are unchanged — only the structured lane grows. The UI gets a Simple/Pro toggle; both editors bind the same `AppState.searchFilters`.

**Tech Stack:** Swift 6 · SwiftUI · SwiftPM **Command Line Tools only** (`swift build` / `swift test`, **NO Xcode**) · GRDB (SQLite) · macOS 15.

---

## Hard rules (every task)

- **Toolchain:** `swift build` / `swift test` only. Never invoke Xcode.
- **Zero warnings:** after each task, `swift build 2>&1 | grep -i warning` **and** `swift build --build-tests 2>&1 | grep -i warning` must both be empty.
- **TDD for Core** (Tasks 1–2: Swift Testing, write the failing test first). **Build-verified for App** (Tasks 3–4).
- **No real user data — ever.** All test data is generated in temp dirs via `TestDirs` + the catalog seeding APIs. Never read `~/Pictures`, `~/Movies`, or any personal folder.
- **Machine-derived → catalog only.** No sidecar writes, **no `docs/format/` change, no catalog migration** — `structuredFilter` only *reads* existing tables (`assets`, `instances`, `vault_presence`, `faces`, `geocode`, `ocr`).
- **Commit message** for each task ends with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Do NOT modify** `SearchRanker.combine`, `SemanticIndex`, `runSearch`'s orchestration, the results grid, `Scanner`, `MetadataExtractor`, or any derivation stage.

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OpenPhotoCore/Search/SearchRanker.swift` (modify) | Refactor `SearchFilters` to include/exclude sets; add `KindFilter`, `PeoplePresence`. `SearchRanker.combine` untouched. | 1 |
| `Sources/OpenPhotoCore/Search/DatePreset.swift` (create) | `DatePreset` enum + pure `range(asOf:calendar:)`. | 1 |
| `Tests/OpenPhotoCoreTests/SearchFiltersTests.swift` (create) | `isEmpty` + `DatePreset.range` tests. | 1 |
| `Sources/OpenPhotoCore/Search/Catalog+Search.swift` (modify) | Extend `structuredFilter` with every facet clause. | 2 |
| `Tests/OpenPhotoCoreTests/CatalogSearchTests.swift` (modify) | One test per facet + a composition test. | 2 |
| `Sources/OpenPhotoApp/AppState.swift` (modify) | `SearchMode` enum + persisted `searchMode`; migrate `searchInPlace`. | 3 |
| `Sources/OpenPhotoApp/Inspector/InspectorView.swift` (modify) | Migrate the tag deep-link to the new field. | 1 |
| `Sources/OpenPhotoApp/Search/FilterChip.swift` (create) | Tri-state include/exclude chip view. | 4 |
| `Sources/OpenPhotoApp/Search/SimpleFilterBar.swift` (create) | The Simple-mode bar (≈ today's bar + folder + date presets). | 4 |
| `Sources/OpenPhotoApp/Search/ProFilterBar.swift` (create) | The Pro-mode chip bar + `More▾` toggles. | 4 |
| `Sources/OpenPhotoApp/Search/SearchView.swift` (modify) | Mode toggle, text-box prompt, "+N Pro filters active" hint, host the two bars. | 4 |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` (modify) | §10.4 extension → DONE + changelog. | 5 |

---

### Task 1: `SearchFilters` model refactor + `DatePreset`

**Files:**
- Modify: `Sources/OpenPhotoCore/Search/SearchRanker.swift`
- Create: `Sources/OpenPhotoCore/Search/DatePreset.swift`
- Create: `Tests/OpenPhotoCoreTests/SearchFiltersTests.swift`
- Modify (compile fixes): `Sources/OpenPhotoApp/Inspector/InspectorView.swift:76`, `Sources/OpenPhotoApp/AppState.swift` (`searchInPlace`), `Sources/OpenPhotoApp/Search/SearchView.swift` (field references — minimal, full UI is Task 4)

- [ ] **Step 1: Write the failing tests** — `Tests/OpenPhotoCoreTests/SearchFiltersTests.swift`

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func emptyFiltersIsEmpty() {
    #expect(SearchFilters().isEmpty)
}

@Test func anyActiveFacetIsNotEmpty() {
    var f = SearchFilters(); f.includePeople = [1]
    #expect(!f.isEmpty)
    var g = SearchFilters(); g.hasText = true
    #expect(!g.isEmpty)
    var h = SearchFilters(); h.excludeFolders = ["a"]
    #expect(!h.isEmpty)
    // foldersRecursive alone (a modifier, not a constraint) does NOT make it non-empty.
    var i = SearchFilters(); i.foldersRecursive = false
    #expect(i.isEmpty)
}

// A fixed UTC calendar + fixed `now` make the preset bounds deterministic.
private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

@Test func datePresetSpecificYearSpansThatYear() {
    let cal = utc(); let now = date(2026, 6, 11, cal)
    let r = DatePreset.year(2019).range(asOf: now, calendar: cal)
    #expect(r.lowerBound == cal.date(from: DateComponents(year: 2019, month: 1, day: 1))!)
    // ends just before 2020-01-01
    #expect(r.upperBound < cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!)
    #expect(r.upperBound >= cal.date(from: DateComponents(year: 2019, month: 12, day: 31))!)
}

@Test func datePresetThisYearAndLastYear() {
    let cal = utc(); let now = date(2026, 6, 11, cal)
    let thisY = DatePreset.thisYear.range(asOf: now, calendar: cal)
    #expect(thisY.lowerBound == cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
    let lastY = DatePreset.lastYear.range(asOf: now, calendar: cal)
    #expect(lastY.lowerBound == cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!)
    #expect(lastY.upperBound < cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
}

@Test func datePresetLast7DaysSpansSevenCalendarDays() {
    let cal = utc(); let now = date(2026, 6, 11, cal)
    let r = DatePreset.last7Days.range(asOf: now, calendar: cal)
    #expect(r.lowerBound == cal.startOfDay(for: date(2026, 6, 5, cal)))  // 11 − 6 = 5
    #expect(r.upperBound == now)
}
```

- [ ] **Step 2: Run the tests, verify they fail to compile** (`SearchFilters` has no `includePeople`; no `DatePreset`)

Run: `swift test --filter SearchFilters 2>&1 | tail -5`
Expected: build failure — `value of type 'SearchFilters' has no member 'includePeople'`, `cannot find 'DatePreset'`.

- [ ] **Step 3: Refactor `SearchFilters`** — replace the struct in `Sources/OpenPhotoCore/Search/SearchRanker.swift` (keep `PlaceFilter` and the `SearchRanker` enum below it **unchanged**):

```swift
/// Structured (click-to-narrow) filters. Negatable facets use include/exclude sets:
/// include semantics are per-facet — People/Tags AND (all present), Folders/Places/Cameras OR
/// (any-of); exclude always means "none of these".
public struct SearchFilters: Sendable, Equatable {
    // Negatable, set-valued facets
    public var includePeople: [Int64] = []      // AND — all must be present
    public var excludePeople: [Int64] = []      // none may be present
    public var includeFolders: [String] = []    // OR — in any (subtree if recursive)
    public var excludeFolders: [String] = []
    public var foldersRecursive: Bool = true    // a folder filter includes its subtree
    public var includeTags: [String] = []       // AND
    public var excludeTags: [String] = []
    public var includePlaces: [PlaceFilter] = []  // OR
    public var excludePlaces: [PlaceFilter] = []
    public var includeCameras: [String] = []    // OR
    public var excludeCameras: [String] = []
    // Non-negatable
    public var dateRange: ClosedRange<Date>? = nil
    public var minRating: Int? = nil            // nil/0 = any
    public var favoritesOnly: Bool = false
    public var kind: KindFilter? = nil          // nil = any
    public var peoplePresence: PeoplePresence? = nil
    public var hasText: Bool = false            // Pro only

    public init() {}
    /// Convenience for the inspector tag deep-link.
    public init(includeTags: [String]) { self.includeTags = includeTags }

    public var isEmpty: Bool {
        includePeople.isEmpty && excludePeople.isEmpty
            && includeFolders.isEmpty && excludeFolders.isEmpty
            && includeTags.isEmpty && excludeTags.isEmpty
            && includePlaces.isEmpty && excludePlaces.isEmpty
            && includeCameras.isEmpty && excludeCameras.isEmpty
            && dateRange == nil && (minRating ?? 0) == 0
            && !favoritesOnly && kind == nil && peoplePresence == nil && !hasText
        // foldersRecursive is a modifier, not a constraint — excluded deliberately.
    }
}

public enum KindFilter: String, Sendable, Equatable, CaseIterable { case photo, video, live }
public enum PeoplePresence: Sendable, Equatable { case has, without }
```

- [ ] **Step 4: Create `DatePreset`** — `Sources/OpenPhotoCore/Search/DatePreset.swift`

```swift
import Foundation

/// A relative date filter that resolves to a concrete `ClosedRange<Date>` at pick-time, so the
/// search itself stays deterministic. `now` is injected for testability.
public enum DatePreset: Sendable, Equatable {
    case today, last7Days, last30Days, last90Days, thisYear, lastYear
    case year(Int)

    public func range(asOf now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: startOfToday)! }
        switch self {
        case .today:      return startOfToday...now
        case .last7Days:  return daysAgo(6)...now
        case .last30Days: return daysAgo(29)...now
        case .last90Days: return daysAgo(89)...now
        case .thisYear:   return DatePreset.year(calendar.component(.year, from: now)).range(asOf: now, calendar: calendar)
        case .lastYear:   return DatePreset.year(calendar.component(.year, from: now) - 1).range(asOf: now, calendar: calendar)
        case .year(let y):
            let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1))!
            let startNext = calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1))!
            return start...startNext.addingTimeInterval(-0.001)   // end of Dec 31, y
        }
    }
}
```

- [ ] **Step 5: Fix the broken call sites so the package compiles** (full UI wiring is Task 4 — here, just keep it building)

`Inspector/InspectorView.swift:76` — change `SearchFilters(tags: [tag])` to `SearchFilters(includeTags: [tag])`.

`AppState.swift` `searchInPlace(_:)` — replace the two `searchFilters.place = …` lines:
```swift
// before: searchFilters.place = .city(countryCode: place.countryCode, city: place.city)  /  .country(...)
searchFilters.includePlaces = [place.city.isEmpty
    ? .country(place.countryCode)
    : .city(countryCode: place.countryCode, city: place.city)]
```

`Search/SearchView.swift` — temporarily map the removed single-value fields so it compiles (Task 4 rewrites this view entirely):
- `searchFilters.camera` → use `searchFilters.includeCameras.first` (read) / `searchFilters.includeCameras = cam.map { [$0] } ?? []` (write).
- `searchFilters.person` → `searchFilters.includePeople.first` / `searchFilters.includePeople = id.map { [$0] } ?? []`.
- `searchFilters.place` → `searchFilters.includePlaces.first` / `searchFilters.includePlaces = …`.
- `searchFilters.videoOnly` → `searchFilters.kind == .video` / `searchFilters.kind = on ? .video : nil`.
- `searchFilters.tags` → `searchFilters.includeTags`.

> These five are the only compile breakages (confirmed by grep). Keep them minimal; Task 4 replaces the bar.

- [ ] **Step 6: Run the tests + a clean build**

Run: `swift test --filter SearchFilters 2>&1 | tail -6`
Expected: 5 tests pass.
Run: `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning`
Expected: no output (zero warnings).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Search/SearchRanker.swift \
        Sources/OpenPhotoCore/Search/DatePreset.swift \
        Tests/OpenPhotoCoreTests/SearchFiltersTests.swift \
        Sources/OpenPhotoApp/Inspector/InspectorView.swift \
        Sources/OpenPhotoApp/AppState.swift \
        Sources/OpenPhotoApp/Search/SearchView.swift
git commit -m "$(cat <<'EOF'
feat(search): refactor SearchFilters to include/exclude sets + DatePreset

SearchFilters grows from single-value fields (person/place/camera/tags/videoOnly) into
include/exclude sets per negatable facet, plus KindFilter / PeoplePresence and a pure
DatePreset.range(asOf:) for relative-date presets. Existing call sites migrated to compile;
the Pro/Simple UI lands in a later task. TDD: isEmpty + preset-bound tests.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extend `Catalog.structuredFilter` with all facet clauses

**Files:**
- Modify: `Sources/OpenPhotoCore/Search/Catalog+Search.swift` (replace `structuredFilter`)
- Modify: `Tests/OpenPhotoCoreTests/CatalogSearchTests.swift` (append tests)

**Context for the implementer:** `structuredFilter` runs `SELECT hash FROM (timelineSQL) WHERE … ORDER BY takenAtMs DESC`. `timelineSQL` is the union of local instances and drive-only presence; it exposes the columns `hash, kind, takenAtMs, cameraModel, rating, favorite, livePairHash, tagsJSON, dirPath` (among others). Filter on those columns directly — `dirPath` already covers local ∪ drive-only. Arg order must match placeholder order: append each clause's args to `args` immediately when you append its string to `conditions`.

- [ ] **Step 1: Write the failing tests** — append to `Tests/OpenPhotoCoreTests/CatalogSearchTests.swift`

```swift
// MARK: Power-user structuredFilter facets

/// Seed builder: accumulate assets + ONE local instance each (so they appear in the union),
/// then persist. Faces/geocode/ocr are added per-hash afterwards (additive APIs).
private final class SeedBuilder {
    var assets: [AssetRecord] = []
    var instances: [InstanceRecord] = []
    func add(_ hash: String, dir: String = "", taken: Int64 = 1, camera: String? = nil,
             rating: Int = 0, favorite: Bool = false, kind: String = "photo",
             livePair: String? = nil, tags: [String] = []) {
        let tagsJSON = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
        assets.append(AssetRecord(hash: hash, kind: kind, takenAtMs: taken, pixelWidth: nil,
            pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: camera, lensModel: nil,
            durationSeconds: nil, livePairHash: livePair, isLivePairedVideo: false,
            favorite: favorite, rating: rating, caption: nil, tagsJSON: tagsJSON))
        let rel = dir.isEmpty ? "\(hash).jpg" : "\(dir)/\(hash).jpg"
        instances.append(InstanceRecord(hash: hash, vaultID: "v", relPath: rel, dirPath: dir,
                                        size: 1, mtimeMs: taken))
    }
    func commit(_ cat: Catalog) throws {
        try cat.upsert(assets: assets)
        try cat.replaceInstances(inVault: "v", with: instances)
    }
}
private func h(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }

@Test func filterMultiPersonIsAndExcludeIsNoneOf() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder(); s.add(h("a")); s.add(h("b")); s.add(h("c")); try s.commit(cat)
    let sarah = try cat.createPerson(name: "Sarah")
    let tom = try cat.createPerson(name: "Tom")
    func face(_ hash: String, _ pid: Int64) -> FaceRow {
        FaceRow(id: nil, hash: hash, rect: .zero, embedding: [], confidence: 1, source: "confirmed", personID: pid)
    }
    // a: Sarah+Tom ; b: Sarah only ; c: Tom only
    _ = try cat.insertFaces([face(h("a"), sarah), face(h("a"), tom),
                             face(h("b"), sarah), face(h("c"), tom)])

    var both = SearchFilters(); both.includePeople = [sarah, tom]
    #expect(Set(try cat.structuredFilter(both)) == [h("a")])           // AND → only a

    var either = SearchFilters(); either.includePeople = [sarah]
    #expect(Set(try cat.structuredFilter(either)) == [h("a"), h("b")])

    var notTom = SearchFilters(); notTom.includePeople = [sarah]; notTom.excludePeople = [tom]
    #expect(Set(try cat.structuredFilter(notTom)) == [h("b")])         // Sarah but not Tom
}

@Test func filterPeoplePresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder(); s.add(h("a")); s.add(h("b")); try s.commit(cat)
    let p = try cat.createPerson(name: "X")
    _ = try cat.insertFaces([FaceRow(id: nil, hash: h("a"), rect: .zero, embedding: [],
                                     confidence: 1, source: "confirmed", personID: p)])
    var has = SearchFilters(); has.peoplePresence = .has
    #expect(Set(try cat.structuredFilter(has)) == [h("a")])
    var without = SearchFilters(); without.peoplePresence = .without
    #expect(Set(try cat.structuredFilter(without)) == [h("b")])
}

@Test func filterFoldersRecursiveExactExcludeAndSiblingSafety() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder()
    s.add(h("a"), dir: "canada23")        // direct
    s.add(h("b"), dir: "canada23/day1")   // nested
    s.add(h("c"), dir: "canada23x")       // prefix sibling — must NOT match
    s.add(h("d"), dir: "rome")            // unrelated
    try s.commit(cat)

    var rec = SearchFilters(); rec.includeFolders = ["canada23"]  // recursive default
    #expect(Set(try cat.structuredFilter(rec)) == [h("a"), h("b")])

    var exact = SearchFilters(); exact.includeFolders = ["canada23"]; exact.foldersRecursive = false
    #expect(Set(try cat.structuredFilter(exact)) == [h("a")])

    var excl = SearchFilters(); excl.excludeFolders = ["canada23"]  // recursive exclude
    #expect(Set(try cat.structuredFilter(excl)) == [h("c"), h("d")])
}

@Test func filterFolderMatchesDriveOnlyAsset() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    // Drive-only: an asset with NO local instance, only a presence row in folder "trip".
    try cat.upsert(assets: [AssetRecord(hash: h("a"), kind: "photo", takenAtMs: 1, pixelWidth: nil,
        pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false, favorite: false,
        rating: 0, caption: nil, tagsJSON: "[]")])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: h("a"), relPath: "trip/x.jpg", dirPath: "trip",
                           size: 1, driveRelPath: "Drive/trip/x.jpg")])
    var f = SearchFilters(); f.includeFolders = ["trip"]
    #expect(Set(try cat.structuredFilter(f)) == [h("a")])
}

@Test func filterTagsIncludeAndExclude() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder()
    s.add(h("a"), tags: ["beach", "summer"]); s.add(h("b"), tags: ["beach"]); s.add(h("c"), tags: ["winter"])
    try s.commit(cat)
    var andTags = SearchFilters(); andTags.includeTags = ["beach", "summer"]
    #expect(Set(try cat.structuredFilter(andTags)) == [h("a")])
    var excl = SearchFilters(); excl.includeTags = ["beach"]; excl.excludeTags = ["summer"]
    #expect(Set(try cat.structuredFilter(excl)) == [h("b")])
}

@Test func filterPlacesIncludeOrAndExclude() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder(); s.add(h("a")); s.add(h("b")); s.add(h("c")); try s.commit(cat)
    try cat.upsertGeocode(GeocodeRow(hash: h("a"), city: "Taipei", region: "", country: "Taiwan", countryCode: "TW"))
    try cat.upsertGeocode(GeocodeRow(hash: h("b"), city: "Rome", region: "", country: "Italy", countryCode: "IT"))
    try cat.upsertGeocode(GeocodeRow(hash: h("c"), city: "Osaka", region: "", country: "Japan", countryCode: "JP"))
    var incl = SearchFilters()
    incl.includePlaces = [.city(countryCode: "TW", city: "Taipei"), .country("IT")]  // OR
    #expect(Set(try cat.structuredFilter(incl)) == [h("a"), h("b")])
    var excl = SearchFilters(); excl.excludePlaces = [.country("JP")]
    #expect(Set(try cat.structuredFilter(excl)) == [h("a"), h("b")])  // c excluded
}

@Test func filterCamerasIncludeOrAndExclude() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder()
    s.add(h("a"), camera: "X100"); s.add(h("b"), camera: "iPhone"); s.add(h("c"))  // c: no camera
    try s.commit(cat)
    var incl = SearchFilters(); incl.includeCameras = ["X100", "iPhone"]
    #expect(Set(try cat.structuredFilter(incl)) == [h("a"), h("b")])
    var excl = SearchFilters(); excl.excludeCameras = ["iPhone"]
    #expect(Set(try cat.structuredFilter(excl)) == [h("a"), h("c")])  // NULL camera survives exclude
}

@Test func filterKind() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder()
    s.add(h("a"), kind: "photo")                       // plain photo
    s.add(h("b"), kind: "video")                       // video
    s.add(h("c"), kind: "photo", livePair: h("z"))     // live still
    try s.commit(cat)
    var photo = SearchFilters(); photo.kind = .photo
    #expect(Set(try cat.structuredFilter(photo)) == [h("a")])
    var video = SearchFilters(); video.kind = .video
    #expect(Set(try cat.structuredFilter(video)) == [h("b")])
    var live = SearchFilters(); live.kind = .live
    #expect(Set(try cat.structuredFilter(live)) == [h("c")])
}

@Test func filterHasText() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder(); s.add(h("a")); s.add(h("b")); try s.commit(cat)
    try cat.upsertOCR(hash: h("a"), text: "SALE 50% OFF")
    try cat.upsertOCR(hash: h("b"), text: "")   // no text
    var f = SearchFilters(); f.hasText = true
    #expect(Set(try cat.structuredFilter(f)) == [h("a")])
}

@Test func filterComposesMultipleFacets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = SeedBuilder()
    s.add(h("a"), dir: "canada23", kind: "photo", tags: ["trip"])   // the match
    s.add(h("b"), dir: "canada23", kind: "video", tags: ["trip"])   // wrong kind
    s.add(h("c"), dir: "rome", kind: "photo", tags: ["trip"])       // wrong folder
    try s.commit(cat)
    let sarah = try cat.createPerson(name: "Sarah")
    _ = try cat.insertFaces([FaceRow(id: nil, hash: h("a"), rect: .zero, embedding: [],
        confidence: 1, source: "confirmed", personID: sarah),
        FaceRow(id: nil, hash: h("b"), rect: .zero, embedding: [], confidence: 1,
                source: "confirmed", personID: sarah)])
    var f = SearchFilters()
    f.includePeople = [sarah]; f.includeFolders = ["canada23"]; f.kind = .photo; f.includeTags = ["trip"]
    #expect(Set(try cat.structuredFilter(f)) == [h("a")])
}
```

- [ ] **Step 2: Run the tests, verify they fail** (the new facets aren't composed yet)

Run: `swift test --filter filter 2>&1 | tail -20`
Expected: the new `filter…` tests fail (e.g. `filterMultiPersonIsAndExcludeIsNoneOf` returns `[a, b]` not `[a]`) or fail to compile if a field is referenced before Task 1 — Task 1 must be merged first.

- [ ] **Step 3: Replace `structuredFilter`** in `Sources/OpenPhotoCore/Search/Catalog+Search.swift`

```swift
    public func structuredFilter(_ filters: SearchFilters) throws -> [String] {
        try dbQueue.read { db in
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []

            if let range = filters.dateRange {
                conditions.append("takenAtMs >= ? AND takenAtMs <= ?")
                args.append(Int64(range.lowerBound.timeIntervalSince1970 * 1000))
                args.append(Int64(range.upperBound.timeIntervalSince1970 * 1000))
            }
            if let minRating = filters.minRating, minRating > 0 {
                conditions.append("rating >= ?"); args.append(minRating)
            }
            if filters.favoritesOnly { conditions.append("favorite = 1") }
            if let kind = filters.kind {
                switch kind {
                case .photo: conditions.append("kind = 'photo' AND livePairHash IS NULL")
                case .video: conditions.append("kind = 'video'")
                case .live:  conditions.append("livePairHash IS NOT NULL")
                }
            }
            // Cameras (OR include / none-of exclude; NULL camera survives an exclude)
            if !filters.includeCameras.isEmpty {
                let marks = databaseQuestionMarks(count: filters.includeCameras.count)
                conditions.append("cameraModel IN (\(marks))")
                args.append(contentsOf: filters.includeCameras as [DatabaseValueConvertible])
            }
            if !filters.excludeCameras.isEmpty {
                let marks = databaseQuestionMarks(count: filters.excludeCameras.count)
                conditions.append("(cameraModel IS NULL OR cameraModel NOT IN (\(marks)))")
                args.append(contentsOf: filters.excludeCameras as [DatabaseValueConvertible])
            }
            // Folders on the union's dirPath (covers local ∪ drive-only). Recursive → subtree GLOB.
            func folderClause(_ folder: String) -> (sql: String, args: [DatabaseValueConvertible]) {
                let f = folder.precomposedStringWithCanonicalMapping
                return filters.foldersRecursive
                    ? ("(dirPath = ? OR dirPath GLOB ?)", [f, f + "/*"])
                    : ("dirPath = ?", [f])
            }
            if !filters.includeFolders.isEmpty {
                var ors: [String] = []
                for f in filters.includeFolders {
                    let c = folderClause(f); ors.append(c.sql); args.append(contentsOf: c.args)
                }
                conditions.append("(" + ors.joined(separator: " OR ") + ")")
            }
            for f in filters.excludeFolders {
                let c = folderClause(f); conditions.append("NOT \(c.sql)"); args.append(contentsOf: c.args)
            }
            // Tags (AND include / none-of exclude) via json_each
            for tag in filters.includeTags {
                conditions.append("EXISTS (SELECT 1 FROM json_each(tagsJSON) WHERE json_each.value = ?)")
                args.append(tag)
            }
            for tag in filters.excludeTags {
                conditions.append("NOT EXISTS (SELECT 1 FROM json_each(tagsJSON) WHERE json_each.value = ?)")
                args.append(tag)
            }
            // People (AND include / none-of exclude / presence)
            for p in filters.includePeople {
                conditions.append("hash IN (SELECT hash FROM faces WHERE personID = ?)")
                args.append(p)
            }
            if !filters.excludePeople.isEmpty {
                let marks = databaseQuestionMarks(count: filters.excludePeople.count)
                conditions.append("hash NOT IN (SELECT hash FROM faces WHERE personID IN (\(marks)))")
                args.append(contentsOf: filters.excludePeople as [DatabaseValueConvertible])
            }
            switch filters.peoplePresence {
            case .has?:     conditions.append("hash IN (SELECT hash FROM faces)")
            case .without?: conditions.append("hash NOT IN (SELECT hash FROM faces)")
            case nil:       break
            }
            // Places (OR include / none-of exclude) via geocode
            func placePredicate(_ p: PlaceFilter) -> (sql: String, args: [DatabaseValueConvertible]) {
                switch p {
                case .country(let cc):        return ("countryCode = ?", [cc])
                case .city(let cc, let city): return ("(countryCode = ? AND city = ?)", [cc, city])
                }
            }
            if !filters.includePlaces.isEmpty {
                var ors: [String] = []
                for p in filters.includePlaces { let c = placePredicate(p); ors.append(c.sql); args.append(contentsOf: c.args) }
                conditions.append("hash IN (SELECT hash FROM geocode WHERE \(ors.joined(separator: " OR ")))")
            }
            if !filters.excludePlaces.isEmpty {
                var ors: [String] = []
                for p in filters.excludePlaces { let c = placePredicate(p); ors.append(c.sql); args.append(contentsOf: c.args) }
                conditions.append("hash NOT IN (SELECT hash FROM geocode WHERE \(ors.joined(separator: " OR ")))")
            }
            // Has-text (Pro): a non-empty OCR row
            if filters.hasText {
                conditions.append("hash IN (SELECT hash FROM ocr WHERE text <> '')")
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT hash FROM (\(Self.timelineSQL))
                \(whereClause)
                ORDER BY takenAtMs DESC
                """
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }
```

- [ ] **Step 4: Run the tests + clean build**

Run: `swift test --filter filter 2>&1 | tail -20` — Expected: all `filter…` tests pass.
Run: `swift test 2>&1 | tail -3` — Expected: full suite still green.
Run: `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` — Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Search/Catalog+Search.swift Tests/OpenPhotoCoreTests/CatalogSearchTests.swift
git commit -m "$(cat <<'EOF'
feat(search): compose every power-user facet in Catalog.structuredFilter

Multi-person AND + exclude none-of + presence; folder include/exclude (recursive subtree via
dirPath on the timeline union, so local ∪ drive-only, sibling-safe); tag include AND / exclude;
place OR include / exclude; camera OR include / exclude (NULL survives exclude); kind
(photo/video/live); has-text. Parameterised; reads existing tables only — no migration. TDD:
one test per facet + a multi-facet composition test.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `AppState.searchMode` (persisted)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (near the `— Search state` block, ~line 89)

- [ ] **Step 1: Add the mode enum + persisted property** — in `AppState.swift`, inside the `// MARK: — Search state` section:

```swift
    enum SearchMode: String { case simple, pro }
    var searchMode: SearchMode =
        SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "") ?? .simple {
        didSet { UserDefaults.standard.set(searchMode.rawValue, forKey: "searchMode") }
    }

    /// Count of currently-active filters that the Simple editor can't represent (≥2 of an OR/AND
    /// facet, any exclusion, has-text, or a people-presence constraint). Drives the
    /// "+N Pro filters active" hint shown in Simple mode.
    var proOnlyFilterCount: Int {
        let f = searchFilters
        return max(0, f.includePeople.count - 1) + f.excludePeople.count
            + max(0, f.includeFolders.count - 1) + f.excludeFolders.count
            + max(0, f.includePlaces.count - 1) + f.excludePlaces.count
            + max(0, f.includeCameras.count - 1) + f.excludeCameras.count
            + f.excludeTags.count
            + (f.hasText ? 1 : 0)
            + (f.peoplePresence != nil ? 1 : 0)
    }
```

- [ ] **Step 2: Build + zero warnings**

Run: `swift build 2>&1 | grep -i warning` — Expected: empty.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "$(cat <<'EOF'
feat(search): persisted Simple/Pro searchMode + proOnlyFilterCount helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Search UI — Simple/Pro editors, tri-state chips, text-box prompt

**Files:**
- Create: `Sources/OpenPhotoApp/Search/FilterChip.swift`
- Create: `Sources/OpenPhotoApp/Search/SimpleFilterBar.swift`
- Create: `Sources/OpenPhotoApp/Search/ProFilterBar.swift`
- Modify: `Sources/OpenPhotoApp/Search/SearchView.swift`

**Context:** `SearchView` already debounces the text box and renders the results grid; reuse those. Both bars mutate `state.searchFilters` and then call `state.runSearch()`. Menu data is loaded in `SearchView.task`: cameras (`distinctCameras()`), tags (`distinctTags()`), people (`people()`), places (`distinctPlaces()`); add **folders** by flattening `state.folderTree` to paths. Follow the visual language of the existing `filterChip` helper (rounded, `Theme.accentDim` when active).

- [ ] **Step 1: Create `FilterChip`** — the tri-state include/exclude chip (`Sources/OpenPhotoApp/Search/FilterChip.swift`):

```swift
import SwiftUI
import OpenPhotoCore

enum ChipState { case included, excluded }

/// A negatable filter value: tap to flip include ⇆ exclude, ✕ to remove.
/// Included = accent fill; excluded = red outline + minus.
struct FilterChip: View {
    let label: String
    var symbol: String? = nil
    let state: ChipState
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state == .excluded ? "minus" : (symbol ?? "checkmark"))
                .font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(state == .excluded ? Theme.red : Theme.accent)
        .background(state == .excluded ? Theme.red.opacity(0.12) : Theme.accentDim,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(state == .excluded ? Theme.red.opacity(0.7) : Theme.accent.opacity(0.4),
                          lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(state == .excluded ? "Excluded — click to include" : "Included — click to exclude")
    }
}
```
> If `Theme.red` doesn't exist, add a `static let red = Color(...)` to `Theme` consistent with the existing palette (check `Theme.swift`; `Theme.amber`/`Theme.green`/`Theme.blue` already exist).

- [ ] **Step 2: Create `SimpleFilterBar`** — the current bar, migrated to the new model + a Folder picker + Date presets (`Sources/OpenPhotoApp/Search/SimpleFilterBar.swift`). It exposes single-value editing: Person (writes `includePeople = [id]`), Folder (writes `includeFolders = [path]` + a `foldersRecursive` toggle), Camera (`includeCameras = [cam]`), Date (a preset menu that sets `dateRange = preset.range(asOf: Date())`, plus "Any date"), Rating, Favourites, Kind (Any/Photo/Video/Live), and tag chips (toggling `includeTags`). Reuse the existing `filterChip(label:active:symbol:)` look (move it here or keep a shared copy). Every control calls `state.runSearch()` after mutating. Folder menu source: flatten `state.folderTree`:
```swift
private func folderPaths(_ nodes: [FolderNode]) -> [String] {
    nodes.flatMap { [$0.path] + folderPaths($0.children) }.sorted()
}
```

- [ ] **Step 3: Create `ProFilterBar`** — the chip bar (`Sources/OpenPhotoApp/Search/ProFilterBar.swift`):
  - Leading **facet menus**: `People▾ Folders▾ Places▾ Cameras▾ Tags▾ Date▾ More▾`. Each menu lists values (people from `people()`, folders flattened, places from `distinctPlaces()`, cameras from `distinctCameras()`, tags from `distinctTags()`); choosing one **adds it to the matching include set** (deduped) and runs search.
  - **Active chips** rendered with `FilterChip`: one per value across every negatable set. `state` = `.included` if the value is in the include set, `.excluded` if in the exclude set. `onToggle` moves the value include→exclude→… (remove from include set, add to exclude set, and vice-versa). `onRemove` drops it from both sets. Always `state.runSearch()` after.
  - `More▾` menu holds the non-negatable controls: Rating, Favourites, Kind, **People presence** (Has / Without / Any → `peoplePresence`), **Has text** (toggles `hasText`), and the Folders **Recursive** switch (`foldersRecursive`). Date is its own `Date▾` (presets + custom range + "Any date").
  - Keep it in a horizontal `ScrollView` like today's bar.

- [ ] **Step 4: Rewrite `SearchView` body** to host the toggle + the active bar + the text-box prompt + the hint. Key changes to `SearchView.swift`:
  - **Text-box prompt** (your ask — the box is now only the semantic + OCR + caption/tag "content" lane): change the `TextField` placeholder from `"Search photos…"` to **`"Describe a photo, or find text in it…"`**.
  - **Mode toggle** in the toolbar (right of the text box / count): `Picker("", selection: $state.searchMode) { Text("Simple").tag(AppState.SearchMode.simple); Text("Pro").tag(AppState.SearchMode.pro) }.pickerStyle(.segmented).fixedSize()`.
  - **Bar switch:** `if state.searchMode == .pro { ProFilterBar(state: state, …menus…) } else { SimpleFilterBar(state: state, …menus…) }`.
  - **Hint:** in Simple mode, when `state.proOnlyFilterCount > 0`, show a small inline note next to the bar: `Text("+\(state.proOnlyFilterCount) Pro filters active").font(.system(size: 11)).foregroundStyle(Theme.accent)` (tapping it flips to Pro is a nice-to-have, not required).
  - **Empty-state subtitle:** update to reflect the split — `emptyState("magnifyingglass", "Search your library", "Type to match how a photo looks or text in it — and use filters for people, places, dates, and folders.")`.
  - Pass the loaded `cameras / allTags / allPeople / allPlaces` + flattened folders into both bars. Keep the `.task` loader; add a folders list.

- [ ] **Step 5: Build, zero warnings, rebuild the app bundle**

Run: `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` — Expected: empty.
Run: `./scripts/make-app.sh 2>&1 | tail -2` — Expected: "Built build/OpenPhoto.app".

- [ ] **Step 6: Manual smoke (the implementer notes it; the user runs it)** — Simple/Pro toggle persists across relaunch; Pro chips add/toggle(include⇆exclude)/remove; a query like "Sarah ∧ Tom · in `canada23` · not a screenshot tag · last summer" returns the right photos; flipping to Simple with those active shows "+N Pro filters active"; the text box still does semantic/OCR/caption matching.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoApp/Search/
git commit -m "$(cat <<'EOF'
feat(search): Simple/Pro filter editors with tri-state include/exclude chips

One SearchFilters model, two editors over a persisted searchMode. Pro: chip bar with
add-via-menu + tri-state include/exclude chips + a More menu (rating/favourites/kind/
people-presence/has-text/recursive) + relative-date presets. Simple: the prior bar migrated
to the new model + a folder picker. Search box re-prompted as the content lane
("Describe a photo, or find text in it…"); Simple shows "+N Pro filters active" when it holds
filters it can't display. Bundle rebuilt.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Docs — mark the extension DONE

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1:** In §10.4, change the extension bullet's lead from "**Extension (planned 2026-06-11 …): Power-user search.**" to note it is **DONE**, and append a changelog entry dated 2026-06-11:

```markdown
- **2026-06-11** — **Phase 4 extension — power-user search (DONE).** SearchFilters refactored to
  include/exclude sets per negatable facet; `Catalog.structuredFilter` now composes multi-person AND
  + exclude + presence, folder include/exclude (recursive subtree via the union's `dirPath`, so local
  ∪ drive-only, sibling-safe), tag AND/exclude, place OR/exclude, camera OR/exclude, kind
  (photo/video/live), and has-text — all parameterised, **reading existing tables only (no migration,
  no on-disk format change)**. UI: a persisted **Simple/Pro** toggle over one shared filter model;
  Pro is a tri-state include/exclude chip bar (the LLM rewriter stays deprioritised). The search box
  is re-framed as the content lane (semantic + OCR + caption/tag). TDD for Core (filters + every
  facet + composition); App build-verified. Spec/plan: `docs/superpowers/specs/2026-06-11-power-user-search-design.md`,
  `docs/superpowers/plans/2026-06-11-power-user-search.md`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "$(cat <<'EOF'
docs: power-user search DONE — master spec §10.4 + changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review (done by the plan author)

- **Spec coverage:** §2 model → T1; §3 query → T2; §4 UI (Simple/Pro/chips/hint/prompt) → T3+T4; §7 testing → T1/T2 tests; §8 tasks → T1–T5. Folder facet, multi-person AND, exclusion, relative dates, kind, people-presence, has-text(Pro), has-location-cut all covered. ✓
- **Placeholder scan:** every code step carries real code; SQL and test bodies are complete; no "TBD". ✓
- **Type consistency:** field names (`includePeople`/`excludePeople`/`includeFolders`/`excludeFolders`/`foldersRecursive`/`includeTags`/`excludeTags`/`includePlaces`/`excludePlaces`/`includeCameras`/`excludeCameras`/`kind`/`peoplePresence`/`hasText`), `KindFilter`/`PeoplePresence`/`DatePreset`/`SearchMode`/`ChipState`, and seeding APIs (`upsert(assets:)`, `replaceInstances(inVault:with:)`, `insertFaces`, `createPerson`, `upsertGeocode`, `upsertOCR`, `replaceVaultPresence`) match across tasks and the real codebase. ✓
- **Ordering dependency:** Task 2's tests reference Task 1's new fields — execute in order (T1 → T2 → T3 → T4 → T5). ✓
