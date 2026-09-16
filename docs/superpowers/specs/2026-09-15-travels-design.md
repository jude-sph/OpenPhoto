# Travels — Design Spec

**Status:** approved — designed interactively through a browser mockup
(`mockups/travel-carousel-DISPOSABLE/ring.html`, disposable); the user then asked for it as a real
feature and delegated autonomy through implementation. Per-section sign-off and the spec-review gate
are exercised by the author on the user's behalf.

**Goal:** A *Travels* section that turns trip folders into a chronological ring of postcards you spin
through (trackpad, drag, arrow keys — with the ratchet click of a revolver cylinder), and lets the
user curate each trip: its name, which folders it spans (subfolders included), its dates (camera
clocks are often wrong), the places visited (auto-detected, editable, **map-recognised**), and its
cover photo. Trips can be discovered automatically from one *Travels folder* or added by hand from
any folder. Nothing moves or copies files.

**Architecture (one line):** A trip is a human-authored record over one or more library folders,
stored as sovereign JSON under `<libraryRoot>/.openphoto/travels/` (authoritative, drive-synced, no
catalog mirror); everything else about a trip — photo count, date span, detected places, default
cover — is derived live from the existing catalog (`instances` by `dirPath`, `geocode`) and never
stored.

**Tech stack:** Swift / SwiftUI (macOS 15), GRDB/SQLite, the `.openphoto/` sovereign-state pattern
(`AlbumStore`, `LockedFolderStore`), `AtomicFile`, the bundled offline GeoNames dataset
(`GeoNamesLoader` / `ReverseGeocoder`), `ThumbnailImage`, `MediaTile`, AVFoundation for the click.

---

## 1. Decisions

- **A trip is a set of folders, recursively.** The mockup's data model: `folders` is a list of
  vault-relative directory paths; every photo whose `dirPath` equals one of them or lies beneath it
  belongs to the trip. Sub-folders (e.g. `Japan 2026/Kyoto`, `…/Osaka`) are part of the trip with no
  extra marking.
- **Two ways in.** (a) *Travels folder*: one folder whose **direct** subfolders each become a trip
  automatically — new trip folders appear on their own. (b) *New trip* from any folder in the library
  (folder-tree context menu or the Travels toolbar). Auto-discovered trips are removable; removed ones
  stay removed (`hidden` list), even though the folder still exists.
- **Derived, not stored.** Photo count, date span, detected places and the default cover are computed
  from the catalog at display time. Only the user's *decisions* are written: name, folders, date
  override, places override, cover override. Consistent with invariant 2 (human-authored → sovereign;
  machine-derived → rebuildable).
- **Auto-discovered trips have no file until edited.** Discovery is a function of `settings.json` +
  the folder tree. The first edit to a discovered trip creates its record (`folders: [<that path>]`);
  from then on it is an ordinary record. A record whose folder list covers a discovered subfolder
  supersedes the discovery (no duplicate).
- **Places are map-recognised.** A typed place is resolved against the bundled GeoNames city list
  (forward search by name / ASCII name / alternate names, ranked by population) and stored with its
  coordinates and GeoNames id, so a later Journey/Globe view or a third-party reader can put it on a
  map without re-resolving free text. A place that matches nothing may still be saved as free text
  (no coordinates) and is shown as "not on the map".
- **No catalog mirror, no schema bump.** Trips are few (tens), stats are cheap aggregate queries
  over indexed `dirPath`. `Catalog.schemaVersion` stays at 13; `docs/format/catalog-schema.md` is
  unchanged.
- **Ring only.** The from-above "Revolver", "Drum" and map-backdrop variants explored in the mockup
  are dropped. The animated hand / F-key flourish is dropped. The ratchet click stays.
- **Sort newest first** by the *effective* start date (override wins), so fixing a wrong camera clock
  moves the trip to its right place on the ring.
- **Out of scope (v1):** undo for trip edits (albums have none either); a map/route view of a trip;
  "who was there" (people) on the trip page; per-photo sidecar writes (a trip is folder-level state,
  not per-asset metadata).

---

## 2. On-disk format (NEW — normative; documented in `docs/format/vault-format-v1.md` §16)

Directory: `<libraryRoot>/.openphoto/travels/`

### 2.1 `settings.json`

```json
{
  "travelsFolder": "Travel",
  "autoDiscover": true,
  "hidden": ["Travel/Scans from Mum"]
}
```

- `travelsFolder` — vault-relative directory path (same form as the catalog's `dirPath`: forward
  slashes, no leading slash, `""` is the vault root) or `null` (none chosen).
- `autoDiscover` — when `true` and `travelsFolder` is non-null, every **direct** subfolder of it is
  a trip unless hidden or covered by a record.
- `hidden` — direct subfolders of `travelsFolder` the user removed from Travels. Paths that are no
  longer direct subfolders are ignored (never pruned eagerly; harmless).

Absent file ⇒ `{ "travelsFolder": null, "autoDiscover": true, "hidden": [] }`.

### 2.2 `<id>.json` — one file per trip record

```json
{
  "id": "5C2E9F1A-…-UUID",
  "name": "Japan 2026",
  "folders": ["Travel/Japan 2026"],
  "startDate": "2026-04-03",
  "endDate": "2026-04-15",
  "places": [
    { "name": "Kyoto", "region": "Kyoto", "country": "Japan", "countryCode": "JP",
      "latitude": 35.02107, "longitude": 135.75385, "geonameID": 1857910 },
    { "name": "Grandma's village", "region": null, "country": null, "countryCode": null,
      "latitude": null, "longitude": null, "geonameID": null }
  ],
  "coverHash": "sha256:…",
  "createdAtMs": 1789000000000,
  "modifiedAtMs": 1789000000000
}
```

- `id` — UUID string, immutable, equals the filename stem.
- `name` — display name, or `null` ⇒ derived: the last path component of `folders[0]`.
- `folders` — **non-empty** ordered array of vault-relative directory paths. Each path includes its
  entire subtree. No path may be equal to or inside another in the same array (writers normalise;
  readers tolerate). A trip whose folders all contain no browse-visible photos is not shown but its
  record is kept.
- `startDate` / `endDate` — ISO-8601 calendar dates (`YYYY-MM-DD`, local calendar, no time zone) or
  `null` ⇒ derived from the earliest/latest `takenAtMs` of the trip's photos. If only one is set the
  other is derived. Writers keep `startDate ≤ endDate`.
- `places` — ordered array, or `null` ⇒ derived from the `geocode` rows of the trip's photos (distinct
  cities, most photos first). Each element: `name` (required), and the GeoNames fields
  `region`/`country`/`countryCode`/`latitude`/`longitude`/`geonameID`, all nullable together for a
  free-text place. `geonameID` is the GeoNames integer id of the matched city (cities15000 extract).
  An **empty array** means "no places" (user removed them all) and is distinct from `null`.
- `coverHash` — content hash (§2 of the vault format) or `null` ⇒ derived: the earliest photo of the
  trip. A cover whose content is not browse-visible falls back to the derived cover at display time
  (the value is kept).
- `createdAtMs` / `modifiedAtMs` — epoch-ms.

Reader obligations: skip an unreadable/corrupt file without affecting the others; treat unknown keys
as ignorable; treat a missing `settings.json` as the defaults above. Writers write atomically.

Drive propagation: the whole `travels/` directory is mirrored one-way to a drive's
`.openphoto/travels/` alongside `albums/` (copy present files, delete absent ones). Folder paths are
vault-relative and drives keep the vault's folder layout, so files copy verbatim.

Attribution: place data © GeoNames (https://www.geonames.org), CC BY 4.0 — already surfaced in the
app's third-party notices for the geocode stage; the same dataset is used here.

---

## 3. Components

### 3.1 Core — records and store (`Sources/OpenPhotoCore/Travels/`)

- `TravelPlace` (`Codable`, `Sendable`, `Equatable`): the place element above.
- `TravelRecord` (`Codable`, `Sendable`, `Equatable`): the `<id>.json` model. `name`, `startDate`,
  `endDate`, `places`, `coverHash` are optionals with the `null` semantics of §2.2.
- `TravelSettings` (`Codable`): the `settings.json` model, with `static let defaults`.
- `TravelStore` (enum, mirrors `AlbumStore`): `directoryURL`, `loadSettings`, `saveSettings`,
  `loadAll -> [TravelRecord]` (skip corrupt), `load(id:)`, `save`, `delete(id:)`,
  `syncToDrive(libraryRoot:driveStateDir:)` (mirror `travels/`, including `settings.json`).
  Pretty-printed, sorted keys, `AtomicFile`.

### 3.2 Core — resolving trips (`TravelResolver`, pure)

Input: `TravelSettings`, `[TravelRecord]`, the folder tree (`[FolderNode]`, already produced by
`LibraryService`). Output: `[TravelDefinition]` — `{ id, source: .record(TravelRecord) | .discovered(path), folders: [String] }`.

Rules:
1. Every record ⇒ one definition (folders normalised: drop any path equal to or inside another).
2. If `autoDiscover` and `travelsFolder` resolves to a node: each direct child path `p` ⇒ a
   `.discovered(p)` definition unless `p ∈ hidden` or some record has a folder `f` with
   `p == f || p.hasPrefix(f + "/")`.
3. A discovered trip's `id` is `"folder:" + p` (stable, never persisted; becomes a UUID when a record
   is created for it).

Pure function; fully unit-tested (discovery, hidden, superseded-by-record, nesting normalisation,
missing travels folder, autoDiscover off).

### 3.3 Core — derived trip stats (`Catalog+Travels.swift`)

Read-only aggregate queries over the browse rows (`instanceSQL`, honouring `lockedFilter` exactly
like `items(inDir:recursive:)`), each taking `dirPaths: [String]` and matching
`dirPath = ? OR dirPath GLOB ?||'/*'` per path:

- `travelStats(dirPaths:) -> TravelStats` — `count`, `minTakenAtMs`, `maxTakenAtMs`,
  `earliestHash` (the derived cover), all from one query.
- `travelPlaces(dirPaths:) -> [PlaceFacet]` — distinct `(city, region, country, countryCode)` from
  `geocode` joined to the visible instances, ordered by photo count desc. Photos without a geocode row
  contribute nothing.
- `travelItems(dirPaths:) -> [TimelineItem]` — the trip's photos, `takenAtMs ASC` (the trip page
  and the cover picker). Union of `items(inDir:recursive:)` semantics across paths, de-duplicated by
  `instanceID`.

Unit-tested against a synthetic catalog (nested folders, a photo in two folders, locked-gate
hidden folder, geocode rows).

### 3.4 Core — place search (`PlaceSearch`, in `Geocode/`)

Forward lookup over the same GeoNames extract. `GeoNamesLoader` is extended to keep, per city,
`geonameID`, `asciiName`, `alternateNames` (split on `,`), `population`, and to build a
`PlaceSearch` alongside the `ReverseGeocoder` (one parse, two indexes; `GeocodeStage` keeps using
only the reverse side). API:

- `PlaceSearch.suggest(_ query: String, limit: Int = 8) -> [TravelPlace]` — case- and
  diacritic-insensitive prefix match on `name`, `asciiName`, or any alternate name; exact-name matches
  rank first, then by population desc. Returns fully populated `TravelPlace`s (coordinates, region,
  country, `geonameID`). Empty query ⇒ `[]`. An unloaded dataset ⇒ `[]` (graceful, like the stage).
- `PlaceSearch.place(matching facet: PlaceFacet) -> TravelPlace?` — resolve a *detected* city
  (`geocode` row: city + countryCode + region) back to its GeoNames entry so derived places also carry
  coordinates when the user first edits them.

Unit-tested with a synthetic city list (prefix, alternate name, diacritics "Hoi An" ↔ "Hội An",
population ranking, exact-first).

### 3.5 Core — `TravelSummary` (view model, computed)

`{ definition, name, folders, startDate, endDate, datesOverridden, places: [TravelPlace],
placesOverridden, count, coverHash, coverOverridden, country (of the first place, for the card) }`.
Built by `TravelResolver.summarise(definition:stats:places:)` — pure, unit-tested for every
override/derive combination (including the empty-array places case and a single overridden date).

### 3.6 App — `AppState+Travels.swift`

- State: `travels: [TravelSummary]` (sorted newest first by effective start), `travelSettings`,
  `selectedTravelID: String?`, `openedTravelID: String?` (the trip page), `travelEditing: Bool`.
- `refreshTravels()`: load settings + records (`TravelStore`), resolve against `folderTree`,
  compute stats/places per definition (one small query each), summarise, sort. Called on library
  open (next to `refreshAlbums()`), on `refreshToken` changes that touch folders (moves/renames/
  deletes already bump it), on lock/unlock reveal changes, and after every travel mutation.
- Mutations (read-modify-write the record, bump `modifiedAtMs`, save, `refreshTravels()`):
  `setTravelName`, `setTravelFolders` / `addTravelFolder` / `removeTravelFolder` (removing the last
  folder removes the trip), `setTravelDates(start:end:)` (nil = derive), `setTravelPlaces([TravelPlace]?)`
  (nil = derive), `setTravelCover(hash:)` (nil = derive), `removeTravel(id:)` (record ⇒ delete file;
  discovered ⇒ append to `hidden`), `createTravel(folder:) -> id`, `setTravelsFolder(path:auto:)`
  (changing the folder clears `hidden`). A mutation on a discovered trip first materialises its record
  (`folders: [p]`, UUID id) and re-targets `selectedTravelID`.
- Drive sync: `TravelStore.syncToDrive` is called at the three sites that call
  `AlbumStore.syncToDrive` (new canonical, adopt, after sync).
- Folder-tree context menu (`FolderTreeView`): "Mark as Travel" (⇒ `createTravel`, switch to
  Travels, select it, open the inspector) and "Use as Travels Folder"; when the folder already is a
  trip: "Show in Travels".

### 3.7 App — `TravelsView` (the section)

`SidebarItem.travels` ("Travels", symbol `globe.europe.africa`), routed like the others.

Layout (from the mockup): toolbar row — title, "N travels · M photos · years", spacer, *Travels
folder* button (label shows the current folder name or "No Travels folder"), *New trip*, hint text.
Below: the ring stage, and to its right the inspector when editing (`Theme.inspectorWidth`).

**`TravelRingView`** — the mockup's inside-the-ring geometry, ported:

- Each card is a `ThumbnailImage` of the cover (250×330 pt, 8 pt radius, caption gradient with name
  and "Country · Year", count badge), placed at
  `translateZ(-pull) · rotateY(θ) · translateZ(-R) · scale(s)` with `R = 400`, `pull = -60`,
  perspective `950`, `k = 0.82`, focus scale bump `+8 %`. In SwiftUI: compute the projected
  x-offset, scale and rotation per card from the same maths (`RingGeometry`, a pure struct with the
  mockup's formulas, unit-tested for the front card, the ±90° edge cards and the off-screen test) and
  apply `.offset` + `.scaleEffect` + `.rotation3DEffect(.degrees(θ), axis: (0,1,0), perspective:)`;
  z-order by proximity to the front. A card is hidden only once it is fully outside the stage or about
  to pass the camera. The stage is zoomed by the minimal factor that puts the edge-on point past the
  stage edges (`zoom = max(1, (width/2 + 36) / edgeX)`), recomputed on resize.
- Spin: an `NSViewRepresentable` overlay forwards `scrollWheel` deltas (velocity += Δ·0.045); drag
  gesture (angle += Δx·-0.16); ← → step one card, Home/End; Return opens; E edits; Esc closes the
  inspector. A 60 Hz `Timer`/display link integrates velocity with damping 0.92 and snaps to the
  nearest card once slow (`target` easing 0.12).
- The ratchet: one short click (square wave 1.8 → 0.6 kHz over 18 ms, gain 0.05 → 0 over 30 ms,
  rendered once into an `AVAudioPCMBuffer` and played through `AVAudioEngine`) each time a card
  crosses the front while `|velocity| > 0.3`. Muted when the system's UI sound effects preference is
  off (`NSUserDefaults` `com.apple.sound.uiaudio.enabled`).
- Chrome: the large light-weight year numeral top-right ("Spin to travel back"); the focused trip's
  name, `date span · places · count` (an amber dot marks hand-set dates); *Edit trip* / *Open trip*;
  the year strip along the bottom (one tick per distinct year, small gaps for empty years, click to
  jump). Empty state when there are no trips.

**`TravelInspector`** (right panel): *Name* (text field, "Use folder name" reset); *Folders* (rows
with count and "incl. N subfolders", ✕ to remove, "Add folder…" opens `FolderPickerSheet`); *Dates*
(two `DatePicker`s, "Photos say …", "Use photo dates" reset); *Places* (chips; typing shows a
suggestion list from `PlaceSearch` as you type — Return picks the highlighted suggestion or saves the
free text; free-text chips are outlined and titled "not on the map"; "Use detected" reset); *Cover*
(a grid of the trip's photos, 4 per row, chosen one outlined, "Automatic" reset); footer *Remove from
Travels* ("Saved automatically"). Inspector text fields set `state.isEditingText` while focused so the
ring's key shortcuts yield.

**`FolderPickerSheet`**: the library folder tree (`LibraryService` `FolderNode`s) as a disclosure
list with photo counts; folders already covered by the trip (or, for New trip, by any trip) are
greyed out; a *Travels folder* mode adds the "Add its subfolders as trips automatically" toggle and a
"Travels" tag on the current folder.

**`TravelDetailView`** (Open trip): hero cover (`ThumbnailImage`, large) with a bottom gradient,
name, `date span · places`; a facts row (Photos, Places, Days, Folders); then the trip's photos as a
`MediaTile` grid grouped by day (section header "Wednesday, April 3 · Kyoto · 84 photos", using the
place of the day when derivable from the day's geocode rows, else omitted). Tap opens the existing
viewer (`state.openedItem`); ‹ Travels closes; *Edit trip* opens the inspector on the ring.

### 3.8 Docs

- `docs/format/vault-format-v1.md`: add `travels/` to the §1 layout tree and a new **§16 Travels
  (`travels/`)** with the schemas and reader/writer obligations of §2 (same commit as the store).
- This spec; the design spec's changelog gets a dated entry pointing here.

---

## 4. Data flow

```
settings.json + <id>.json ──TravelStore──▶ [TravelRecord] ─┐
folder tree (LibraryService) ──────────────────────────────┴─TravelResolver─▶ [TravelDefinition]
                                                                     │ per definition
catalog: travelStats / travelPlaces (dirPaths) ◀─────────────────────┘
                                                                     ▼
                                              TravelResolver.summarise ─▶ [TravelSummary] ─▶ ring / inspector / page
user edit ─▶ AppState mutation ─▶ TravelStore.save ─▶ refreshTravels()
```

## 5. Error handling

- Corrupt/unreadable record or settings file: skipped / defaults; the rest load. A save failure shows
  `NSAlert(error:)` like albums and leaves state unchanged.
- A record whose folders no longer exist (folder deleted/moved): count 0 ⇒ not shown on the ring, file
  kept (the user may move the folder back). Folder moves/renames inside the app (`AppState+FolderReorg`)
  rewrite matching `folders` paths in records and `travelsFolder`/`hidden` in settings in the same
  operation (path-prefix rewrite), so trips follow their folders.
- Dataset absent (no `geonames/`): no suggestions; typed places save as free text; detected places
  come only from existing `geocode` rows.
- Locked folders: derived stats honour the locked gate like every other query, so a locked trip
  folder's photos don't leak into counts/covers until revealed.

## 6. Testing

Core (Swift Testing, synthetic data only — never real photos):
- `TravelStoreTests`: settings defaults/round-trip, record round-trip with nulls and places,
  corrupt file skipped, delete, `syncToDrive` mirrors + propagates deletes (incl. `settings.json`).
- `TravelResolverTests`: discovery, hidden, superseded, nesting normalisation, no travels folder,
  autoDiscover off, discovered id form; `summarise` for every derive/override combination.
- `CatalogTravelsTests`: `travelStats` (count/min/max/earliest across nested dirs, sibling-prefix
  folder not matched, duplicate content in two folders), `travelPlaces` ordering, locked gate,
  `travelItems` order/dedup.
- `PlaceSearchTests`: prefix on name/ascii/alternate, diacritic-insensitive, exact-first then
  population, limit, empty query, unloaded dataset, `place(matching:)`.
- `RingGeometryTests`: front card at θ=0 (offset 0, max scale), symmetric offsets at ±θ, off-screen
  test at the edges, zoom factor.
- `TravelPathRewriteTests`: folder rename/move rewrites record folders and settings paths.

App: build-verified; interactive smoke checklist for the user (ring feel, click, inspector edits
persisting to `.openphoto/travels/`, Travels-folder discovery, context-menu entry points, drive
mirror, trip page, locked-folder gating).

---

## Changelog

- 2026-09-15 — initial spec.
