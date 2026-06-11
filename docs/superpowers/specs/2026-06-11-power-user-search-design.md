# Power-user search — design

**Date:** 2026-06-11
**Branch:** `power-user-search` (to be created off `main`)
**Status:** Approved in brainstorming (2026-06-11); ready for the implementation plan.
**Phase:** Phase 4 (Intelligence) extension — see master design spec §10.4.

> Strengthen OpenPhoto's existing three-lane Search (OCR full-text · caption/tag · MobileCLIP
> semantic, intersected with structured filters) with a richer **deterministic** structured-filter
> model — multi-person AND, folder/place/camera/tag include **and** exclude, relative-date presets,
> kind / people-presence / has-text facets — surfaced through a **Simple** and a **Pro** editor over
> one shared filter state. No ML, no on-disk format change. Chosen over an on-device LLM query-rewriter
> (deprioritised; master spec §10 changelog 2026-06-11): MobileCLIP's text encoder already answers
> natural-language *appearance* queries, so the genuine gaps are named-entity / date *composition* —
> delivered here far more cheaply, deterministically, and testably.

---

## 1. Goal & scope

Make Search expressive enough that you rarely wish you could "type a sentence": compose precise
queries from people, folders, places, cameras, tags, dates, and a few presence facets — with
**negation** and **multi-value** support — while keeping a fast, low-friction path for the common
single-facet case.

### Key decisions (the non-obvious ones)

1. **One filter model, two editors.** `SearchFilters` is the single source of truth; **Simple** and
   **Pro** are two renderings of it that run the *same* search via the *same* `runSearch()` →
   `Catalog.structuredFilter` → `SearchRanker.combine` path. Flipping modes never loses state or
   changes results. The only divergence is *which* fields each editor exposes.
2. **Tri-state chips for negation (Pro).** A facet menu adds a chip (included by default); clicking
   the chip flips include → exclude; `✕` removes it. Included = accent fill, excluded = red outline +
   minus. This is the compact, consistent affordance; no second set of menus, no separate zones.
3. **Per-facet include semantics, baked into the data model and SQL:**
   - facets where one photo can hold *many* values — **People, Tags** → include is **AND** (all
     present);
   - facets where one photo holds *one* value — **Folders, Places, Cameras** → include is **OR**
     (any-of);
   - **exclude always means "none of these"** for every negatable facet.
4. **Search-tab only.** Filtering Timeline/Folders *in place* is a separate backlog item; this
   extension lives entirely in the Search surface.
5. **No catalog migration, no on-disk format change.** Filtering only *reads* existing tables
   (`assets`, `instances`, `vault_presence`, `faces`, `geocode`, `ocr`). Pure machine-derived reads;
   nothing is written.

### Non-goals (deferred)

- The on-device **LLM query-rewriter** (Phase 5).
- **In-place filtering** of Timeline / Folders (separate backlog item).
- **OR across people** ("Sarah *or* Tom, either one") — rare; muddies the chip model (YAGNI).
- **Saved / pinned searches** (the brainstorm's "Tier 3" — defer until the filters have been lived
  with).
- **Has-location** facet (judged not worth it) and a **Pro-only has-text** is the only presence facet
  beyond people-presence.

---

## 2. The filter model — `SearchFilters`

`SearchFilters` (today in `Sources/OpenPhotoCore/Search/SearchRanker.swift`) is refactored from its
current single-value fields (`person`, `place`, `camera`, `tags`, `videoOnly`) into explicit
include/exclude sets per negatable facet. It stays a **pure, `Sendable`, `Equatable` value type** so
it remains the unit-tested heart.

```swift
public struct SearchFilters: Sendable, Equatable {
    // Negatable, set-valued facets ----------------------------------------
    public var includePeople: [Int64]      = []   // AND — all must be present
    public var excludePeople: [Int64]      = []   // none may be present
    public var includeFolders: [String]    = []   // OR — in any of these (subtree if recursive)
    public var excludeFolders: [String]    = []   // in none of these
    public var foldersRecursive: Bool      = true // a folder filter includes its subtree
    public var includeTags: [String]       = []   // AND (today's behaviour)
    public var excludeTags: [String]       = []
    public var includePlaces: [PlaceFilter] = []  // OR
    public var excludePlaces: [PlaceFilter] = []
    public var includeCameras: [String]    = []   // OR
    public var excludeCameras: [String]    = []
    // Non-negatable -------------------------------------------------------
    public var dateRange: ClosedRange<Date>? = nil
    public var minRating: Int?             = nil   // nil/0 = any
    public var favoritesOnly: Bool         = false
    public var kind: KindFilter?           = nil   // .photo | .video | .live | nil = any
    public var peoplePresence: PeoplePresence? = nil  // .has | .without | nil = any
    public var hasText: Bool               = false // Pro only: has non-empty OCR text

    public var isEmpty: Bool { /* all sets empty + all scalars nil/false */ }
}

public enum KindFilter: Sendable, Equatable { case photo, video, live }
public enum PeoplePresence: Sendable, Equatable { case has, without }
```

`PlaceFilter` (`country` / `city`) is unchanged.

**Relative dates.** A pure helper converts a preset to a concrete range so the *query* stays
deterministic (the range is resolved at pick-time; `SearchFilters.dateRange` is the only thing the
query reads):

```swift
public enum DatePreset: Sendable, Equatable, CaseIterable {
    case today, last7Days, last30Days, last90Days, thisYear, lastYear
    case year(Int)            // a specific calendar year
    // Pure + testable: `now` is injected so tests are deterministic.
    public func range(asOf now: Date, calendar: Calendar = .current) -> ClosedRange<Date>
}
```

The Pro/Simple UI calls `range(asOf: Date())` when a preset is chosen and stores the result in
`dateRange`; a custom range bypasses the preset. The chosen preset label is held in **view state**
for chip display/re-edit (not in `SearchFilters`, which only needs the resolved range).

**Migration of existing call sites** (mechanical): the inspector tag deep-link
(`SearchFilters(tags: [tag])`) and `AppState.searchInPlace(place)` are updated to the new field names
(`includeTags`, `includePlaces`). No behavioural change.

---

## 3. Query composition — `Catalog.structuredFilter`

`Catalog.structuredFilter(_ filters:) -> [String]` (in `Catalog+Search.swift`) is extended to AND
every active facet into one parameterised SQL query over `assets a`, returning hashes newest-first
(`ORDER BY a.takenAtMs DESC`). `SearchRanker.combine` and `runSearch()` are **unchanged** — only the
structured lane grows. Each facet contributes a clause:

| Facet | Clause (sketch; all parameterised) |
|---|---|
| **People — include (AND)** | one `EXISTS (SELECT 1 FROM faces f WHERE f.hash = a.hash AND f.personID = ?)` **per** included person |
| **People — exclude** | `NOT EXISTS (SELECT 1 FROM faces f WHERE f.hash = a.hash AND f.personID IN (…))` |
| **People-presence** | has → `EXISTS (SELECT 1 FROM faces f WHERE f.hash = a.hash)`; without → `NOT EXISTS(…)` |
| **Folders — include (OR, subtree)** | `EXISTS` a local instance **or** drive-presence row whose `dirPath` matches **any** included folder: `(i.dirPath = ? OR i.dirPath GLOB ?)` (`folder`, `folder/*`) when recursive, `i.dirPath = ?` when exact; OR'd across folders; checked against **both** `instances` and `vault_presence` so drive-only assets are covered |
| **Folders — exclude** | `NOT EXISTS (… dirPath matches any excluded folder …)` across `instances` ∪ `vault_presence` |
| **Tags — include (AND)** | one `json_each`-EXISTS per included tag (today's pattern) |
| **Tags — exclude** | `NOT EXISTS (SELECT 1 FROM json_each(a.tagsJSON) WHERE value IN (…))` |
| **Places — include (OR)** | `EXISTS (SELECT 1 FROM geocode g WHERE g.hash = a.hash AND (<place> OR <place> …))` (country = `countryCode = ?`; city = `countryCode = ? AND city = ?`) |
| **Places — exclude** | `NOT EXISTS (… any excluded place …)` |
| **Cameras — include (OR)** | `a.cameraModel IN (…)` |
| **Cameras — exclude** | `(a.cameraModel IS NULL OR a.cameraModel NOT IN (…))` |
| **Date range** | `a.takenAtMs BETWEEN ? AND ?` |
| **Rating** | `a.rating >= ?` |
| **Favourites** | `a.favorite = 1` |
| **Kind** | photo → `a.kind = 'photo' AND a.livePairHash IS NULL`; video → `a.kind = 'video'`; live → `a.livePairHash IS NOT NULL` |
| **Has-text (Pro)** | `EXISTS (SELECT 1 FROM ocr o WHERE o.hash = a.hash AND o.text <> '')` |

Always excludes the Live-paired video half (`a.isLivePairedVideo = 0`), matching today's queries. The
GLOB folder idiom is the existing one from `items(inDir:recursive:)`; an explicit predicate guards the
`folder` vs `folderX` sibling case (covered by a test).

`distinctCameras()` / `distinctTags()` already exist for the menus; add `distinctPeople()` (id+name+
count, ordered) and reuse `folderTree()` / `distinctPlaces()` for the Folder and Place menus.

---

## 4. UI — Simple and Pro

`SearchView` gains a **`Simple · Pro` segmented toggle** in its toolbar, persisted in `UserDefaults`
(`searchMode`). Both editors bind to the shared `AppState.searchFilters` and trigger the existing
(debounced for the text box) `runSearch()` on change.

**Simple mode** (≈ today's bar + folder): single **Person** dropdown · single **Folder** dropdown +
*recursive* toggle · single **Camera** dropdown · **Date** (range/preset) · **Rating** · **Favourites**
· **Kind** · tag chips (existing). Writes the corresponding single-element include sets. If Pro left
behind anything Simple can't show (≥2 people, any exclusion, places, has-text), Simple shows a small,
non-destructive hint — **"+N Pro filters active"** — and keeps them in effect (flip to Pro to edit).

**Pro mode** — the chip bar:
- Facet **menus** (`People▾ Folders▾ Places▾ Cameras▾ Tags Date▾ More▾`) each **add a chip** (included
  by default). `More▾` carries the toggles: Rating, Favourites, Kind, People-presence (Has / Without /
  Any), **Has-text**, and the Folders *recursive* switch.
- **`FilterChip`** (new, `Sources/OpenPhotoApp/Search/FilterChip.swift`): renders one facet value;
  click toggles include ⇆ exclude (accent fill ⇆ red outline + minus); `✕` removes. Non-negatable
  toggles render as plain on/off chips.
- New focused view files keep `SearchView` from ballooning: `FilterChip.swift`, `ProFilterBar.swift`,
  `SimpleFilterBar.swift`; `SearchView` hosts the toggle + results grid (the existing shared
  `MediaTile` grid) and owns nothing facet-specific.

Both modes are **build-verified + manual** (the project's App-layer convention).

---

## 5. Data flow

```
user edits a facet (Simple or Pro)
  → mutates AppState.searchFilters  (one shared value)
  → runSearch()  (debounced for the text box; immediate for filter chips)
      ├─ Catalog.structuredFilter(filters)         → [hash]  (all facets AND-composed in SQL)
      ├─ (if text) Catalog.textMatches(q)           → [hash]
      ├─ (if text) SemanticIndex.query(embedText q) → [(hash,score)]
      ├─ SearchRanker.combine(structured, text, semantic, hasText:)   (UNCHANGED)
      └─ Catalog.items(forHashes:preservingOrder:)  → [TimelineItem] → searchResults
```

The only changed Core unit is `structuredFilter`; `SearchRanker`, `SemanticIndex`, `runSearch`'s
orchestration, and the results grid are untouched.

---

## 6. Error handling / edge cases

| Case | Behaviour |
|---|---|
| Empty box **and** empty filters | `searchResults = []` (today's behaviour). |
| Folder `2025` vs sibling `2025x` | GLOB predicate + exact-segment guard never matches the sibling (test-pinned, mirrors `items(inDir:recursive:)`). |
| A drive-only photo in a filtered folder | Matched via the `vault_presence` branch of the folder clause — same Mac-aligned `dirPath` the folder tree uses. |
| Same person included **and** excluded | Include-AND + exclude-none-of yields no rows (the user's contradiction; not an error). |
| A person/folder/tag that no longer exists (renamed/removed) | Its clause simply matches nothing; the chip can be removed. No crash. |
| Flip Pro→Simple with un-representable filters | Filters stay active; Simple shows "+N Pro filters active". Flip-back restores full editing. |
| Live-paired video half | Excluded from results as in every existing query (`isLivePairedVideo = 0`). |

---

## 7. Testing

**Core (TDD, Swift Testing — extend `CatalogSearchTests` + a new `SearchFiltersTests`):**
1. `DatePreset.range(asOf:)` — each preset resolves to the expected bounds for a fixed injected `now`
   (deterministic); `year(2019)` spans that calendar year.
2. `structuredFilter`, each facet isolated on a seeded catalog (the existing `upsert(assets:)` +
   `replaceVaultPresence` + `insertFaces` + `upsertGeocode` patterns):
   - **People AND** — two included people return only photos containing **both**; one returns either.
   - **People exclude** — drops photos containing any excluded person.
   - **People-presence** — has / without.
   - **Folders** — include recursive (folder + subtree) vs exact; the `2025` / `2025x` sibling stays
     out; exclude removes a subtree; a **drive-only** (`vault_presence`) asset is matched.
   - **Tags** — include AND (existing) + exclude.
   - **Places** — include OR (two cities) + exclude.
   - **Cameras** — include OR + exclude (incl. NULL camera handling).
   - **Kind** — photo / video / live.
   - **Has-text** — only photos with non-empty OCR.
   - **Date / rating / favourites** — bounds correct.
3. **Composition** — a multi-facet query (e.g. include people A∧B, folder F recursive, exclude tag T,
   kind photo, date range) returns exactly the intended intersection.
4. `SearchFilters.isEmpty` true/false cases.

**App (build-verified + manual):** Simple/Pro toggle persists; chips add/toggle/remove; the "+N Pro
filters active" hint appears when expected; a representative query ("Sarah ∧ Tom, in `canada23`, not a
screenshot, last summer") returns the right photos. Rebuild the bundle via `./scripts/make-app.sh`.

No new on-disk format, no catalog migration, no sidecar writes — so `docs/format/` is **unchanged**;
the master spec §10.4 extension entry is updated to **DONE** with a dated changelog line at merge.

---

## 8. Task decomposition (for the plan)

1. **Core (TDD)** — `SearchFilters` refactor to include/exclude sets + `KindFilter`/`PeoplePresence`
   enums + `isEmpty`; `DatePreset` + `range(asOf:)`. Update the two existing call sites
   (`searchInPlace`, inspector tag deep-link) to compile. Tests: §7.1, §7.4.
2. **Core (TDD)** — extend `Catalog.structuredFilter` with every facet clause (and `distinctPeople()`).
   Tests: §7.2, §7.3.
3. **App** — `AppState.searchMode` (persisted) + any helper wiring; confirm `runSearch()` unchanged.
4. **App** — `FilterChip` + `ProFilterBar` + `SimpleFilterBar`; `SearchView` toggle + the "+N Pro
   filters active" hint; rebuild the bundle.
5. **Docs** — master spec §10.4: mark the extension **DONE** + a 2026-06-11 changelog line. No
   `docs/format/` change.

`SemanticIndex`, `SearchRanker`, `runSearch` orchestration, and the results grid are **used, not
modified**.
