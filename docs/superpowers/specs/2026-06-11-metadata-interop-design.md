# Metadata interop + Settings — design

**Date:** 2026-06-11
**Branch:** `phase5-metadata-interop`
**Status:** Approved in brainstorming (2026-06-11); ready for the implementation plan.
**Phase:** Phase 5 (Extras & integrations) — two of the rescoped "Building" items + a Settings home.

> Make OpenPhoto's human-authored metadata visible to the outside world, three small pieces in one slice:
> - **(A) Sidecar export** — an on-demand action that writes a mirror tree of standard `.xmp` sidecars
>   into a chosen destination (a portable metadata snapshot); the live library is never touched.
> - **(B) Finder-tag two-way sync** — an **opt-in** bridge where OpenPhoto tags and macOS Finder tags
>   stay identical, reconciled by a **3-way merge** (against a per-photo baseline) so removals on either
>   side propagate. XMP sidecars stay the authoritative, portable record.
> - **(C) Settings window** — the home for the Finder-sync opt-in + a "Sync now" action, and the
>   **GeoNames CC BY 4.0 attribution** owed from the Map (a documented follow-up, now satisfied).
>
> Catalog-only; the one on-disk-format touch is a rebuildable `finder_tag_sync` table (migration v11).
> No `vault-format-v1` change.

---

## 1. Goal & scope

Bridge OpenPhoto's tags/rating/caption/people to other tools without compromising sovereignty: export a
portable copy on demand, and keep tags in lock-step with Finder for users who opt in.

### Key decisions (the non-obvious ones)

1. **Sidecar export is one-way to a NEW folder (no in-place clutter, no format change).** The hidden
   `.openphoto/` store stays canonical; export writes a mirror tree of `<dest>/<relPath>.xmp` (append
   naming, `IMG_1.heic.xmp`). It's a portable metadata *snapshot/archive* — not colocated with photos, so
   not for live Lightroom pairing (documented). Reads only; library + originals untouched.
2. **Finder-tag sync is a true two-way mirror via a 3-way merge.** A pure `TagMerge.merge(baseline,
   openphoto, finder)` reconciles using a stored per-photo **baseline** (last-synced set), so an add OR a
   remove on either side propagates, deterministically and conflict-free. The merged set is always
   written to the **XMP sidecar (authoritative) + catalog + the file's Finder tags**, and the baseline is
   updated.
3. **Finder sync is OPT-IN (default off).** Writing Finder tags sets an OS xattr on *original* files —
   non-destructive (the image bytes, and therefore the content hash/asset identity, are unchanged) but
   still a write to the original, so it requires the user's explicit opt-in to honour invariant #1.
   Colours are out of scope (the `tagNames` API is plain strings).
4. **Settings window (native `Settings` scene, ⌘,).** Hosts the opt-in toggle + a "Sync Finder tags now"
   button + the GeoNames attribution. Export lives in the **File menu**.
5. **One rebuildable catalog table, one migration.** `finder_tag_sync(hash, baseline)` (**v11**); dropping
   it degrades the *next* sync to additive for one cycle (no data loss). `catalog-schema.md` updates in
   the **same commit** as the migration (the schema version lands in drive snapshots).

### Non-goals (v1)
- Reading external beside-file sidecars back into OpenPhoto (export is one-way for v1).
- Finder-tag **colours** (label strings only).
- Syncing Finder tags for **drive-only** assets (no local file to tag) — skipped.
- A general preferences surface beyond what's listed (keep Settings minimal: Finder sync + credits).

---

## 2. Architecture

### Core (`OpenPhotoCore`, TDD)

**`TagMerge` (`Sources/OpenPhotoCore/Interop/TagMerge.swift`)** — pure, the tested heart:
```swift
public enum TagMerge {
    /// 3-way set merge. A tag survives iff it wasn't removed on either side; a tag is added iff it
    /// appeared on either side. removed/added never overlap, so the result is unambiguous.
    public static func merge(baseline: Set<String>, openphoto: Set<String>, finder: Set<String>) -> Set<String> {
        let removed = baseline.subtracting(openphoto).union(baseline.subtracting(finder))
        let added   = openphoto.subtracting(baseline).union(finder.subtracting(baseline))
        return baseline.subtracting(removed).union(added)
    }
}
```

**`FinderTags` (`Sources/OpenPhotoCore/Interop/FinderTags.swift`)** — read/write a file's Finder tags via
Foundation: read = `(try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []`; write = set
`URLResourceValues.tagNames` (mutable copy of the URL). Returns `[]` / no-ops on a missing file.

**`Catalog+FinderTags.swift`** — the `finder_tag_sync` table (migration **v11**) + `setFinderTagBaseline(
hash:tags:)` (INSERT OR REPLACE, JSON-encoded array) + `finderTagBaseline(forHash:) -> [String]` (`[]`
when absent).

**`LibraryService.reconcileFinderTags(forHash:proposedTags:) -> [String]`** — the orchestration:
1. Resolve the asset's **local** instance file URLs (`catalog.instances(forHash:)` → each local vault's
   `absoluteURL`, existing files only). If none, return `proposedTags` unchanged (drive-only: no Finder).
2. `finder` = the **union** of all those files' current Finder tags; `baseline` = `finderTagBaseline`;
   `openphoto` = `proposedTags`.
3. `merged = TagMerge.merge(baseline:, openphoto:, finder:)`.
4. Write `merged` to **every** local instance file's Finder tags (so copies converge), and
   `setFinderTagBaseline(hash:, tags: merged)`.
5. Return `merged` (the caller persists it to the sidecar + catalog via `updateMetadata`).

**`SidecarExporter` (`Sources/OpenPhotoCore/Interop/SidecarExporter.swift`)** —
`export(library:, to dest: URL) -> Int`: for each local vault, walk its `Manifest`; for each entry,
`SidecarStore.read` the asset's `SidecarData`; if non-empty, `AtomicFile.write(XMP.serialize(data),
to: dest/<entry.path>.xmp)` (creating intermediate dirs). Returns the count written. Reuses the existing
`XMP.serialize`; never reads/writes the library.

### App (`OpenPhotoApp`, build-verified)

**`AppState`:**
- `var finderTagSyncEnabled: Bool` (persisted `UserDefaults` key `finderTagSync`, default `false`);
  `didSet` → when flipped on, kick `syncFinderTagsNow()`.
- **Edit gating:** the inspector's metadata save routes through `tagsForSave(item:, proposed:) -> [String]`
  = `finderTagSyncEnabled ? lib.reconcileFinderTags(forHash: item.hash, proposedTags: proposed) : proposed`,
  then `lib.updateMetadata(... tags: result)`. So an OpenPhoto edit reconciles live (writes Finder +
  baseline) and persists the merged set.
- `func syncFinderTagsNow()` — off-main: for every asset (`catalog` tag set as `proposedTags`),
  `reconcileFinderTags`; if the result differs, persist via `updateHumanMetadata` (+ sidecar). Idempotent
  (no Finder write when nothing changed). Called on enable, at library-open when enabled, and from the
  Settings button. (Runs only when enabled.)
- `func exportSidecars()` — `NSOpenPanel` (choose-directory) → off-main `SidecarExporter.export` → an
  alert with the count.

**`SettingsView` (`Sources/OpenPhotoApp/Settings/SettingsView.swift`)** — a `TabView`:
- **General:** a `Toggle("Sync tags with Finder", isOn: $state.finderTagSyncEnabled)` with a one-line
  explanation ("Mirrors your tags to macOS Finder tags on this Mac's files. Two-way; off by default."),
  and a "Sync Finder tags now" button (`state.syncFinderTagsNow()`, disabled when off).
- **About:** app name + version; **"Place data © GeoNames (https://www.geonames.org), CC BY 4.0."** as a
  tappable `Link`; a short credits line (Apple Vision / Core ML MobileCLIP for on-device analysis).

**`OpenPhotoApp.swift`:** add a `Settings { SettingsView(state: state) }` scene (gives the standard
Settings window + ⌘, + the "Settings…" app-menu item); add a File-menu command **"Export Metadata
Sidecars…"** → `state.exportSidecars()`.

---

## 3. Data flow

```
EXPORT:  File ▸ Export Metadata Sidecars… → choose dest → SidecarExporter.export
         (read hidden sidecars → XMP.serialize → AtomicFile write dest/<relPath>.xmp) → "N exported"

FINDER SYNC (only when opt-in ON):
  edit tags in OpenPhoto → reconcileFinderTags(hash, proposed=new UI set)
      read union(Finder of local files) + baseline + proposed → TagMerge → merged
      write merged to all local files' Finder tags + baseline=merged
    → updateMetadata(tags: merged)  (XMP sidecar + catalog)
  add/remove a tag in Finder → (at library-open / Settings "Sync now") syncFinderTagsNow()
      per asset: reconcileFinderTags(proposed = current catalog tags) → merged → persist if changed
```

---

## 4. Error handling / edge cases

| Case | Behaviour |
|---|---|
| Drive-only asset (no local file) | Finder sync skipped (`reconcileFinderTags` returns `proposedTags`); export still writes its sidecar if metadata exists. |
| Finder sync OFF | No xattr is ever written; `tagsForSave` returns the user's set verbatim. Originals untouched. |
| Baseline table dropped/missing | `finderTagBaseline` = `[]` → the next merge is additive for one cycle (union), then the new baseline is stored. No loss. |
| Same photo in two local folders | `reconcileFinderTags` reads the **union** of both files' Finder tags and writes the merged set to **both**; one baseline per asset. |
| Interleaved edits both sides | The 3-way merge resolves correctly (the baseline disambiguates add vs remove). |
| Export destination = inside the library | Allowed but pointless; documented. Export never writes into `.openphoto/` or beside originals. |
| Unreadable/locked file during Finder write | That file is skipped (`try?`); others proceed; not fatal. |
| Content hash | A Finder-tag xattr does **not** change the data fork, so the `sha256:` content hash / asset identity is unchanged. |

---

## 5. Testing

**Core (TDD, Swift Testing — temp dirs + generated files only, never `~/Pictures`):**
1. `TagMerge` — add-on-one-side propagates; remove-on-one-side propagates; add+remove on opposite sides
   both apply; empty baseline → union (additive); no-op when all three equal.
2. `FinderTags` — write `["a","b"]` to a temp file, read back `["a","b"]`; overwrite with `["a"]` → read
   `["a"]`; read a no-tags file → `[]`.
3. `Catalog+FinderTags` — `setFinderTagBaseline`/`finderTagBaseline` round-trip (incl. replace); migration
   v11 (`Catalog.schemaVersion == 11`).
4. `LibraryService.reconcileFinderTags` — on a temp vault with a real local file: pre-seed Finder tags +
   a baseline, call with `proposedTags`, assert the merged result, the file's Finder tags, and the stored
   baseline all match; a drive-only hash returns `proposedTags` and writes nothing.
5. `SidecarExporter` — a temp library with tagged + untagged assets exports `<dest>/<relPath>.xmp` for the
   tagged ones (valid XMP, re-parses via `XMP.parse`), skips empties, and never writes into the library.

**App:** build-verified + manual — the Settings window (⌘,) shows the toggle + GeoNames link; toggling on
triggers a sync; "Sync Finder tags now" works; File ▸ Export Metadata Sidecars… writes the tree;
round-trip a tag through Finder. Rebuild the bundle via `./scripts/make-app.sh`.

---

## 6. Documentation

`docs/format/catalog-schema.md` gains the **`finder_tag_sync`** table (v11, rebuildable/machine-derived
sync-state — droppable), bumped to **Version 11**, **in the same commit as the migration** (the version
lands in drive snapshots). **No `vault-format-v1.md` change** (Finder tags are an OS xattr, not a vault
artifact; the durable record stays XMP; export writes outside the library). Master spec §10.5 marks
**sidecar export + Finder-tag interop DONE** and notes the **GeoNames attribution satisfied** (the 4.4
follow-up), with a 2026-06-11 changelog entry.

---

## 7. Task decomposition (for the plan)

1. **Core (TDD)** — `TagMerge` (pure 3-way) + `FinderTags` (read/write `tagNames`). Tests §5.1–5.2.
2. **Core (TDD)** — `finder_tag_sync` table (migration **v11**, `schemaVersion` 10→11, **+ `catalog-schema.md`
   in the same commit**) + `Catalog+FinderTags` + `LibraryService.reconcileFinderTags`. Tests §5.3–5.4.
3. **Core (TDD)** — `SidecarExporter`. Test §5.5.
4. **App** — `AppState.finderTagSyncEnabled` (persisted) + edit gating (`tagsForSave`) wired into the
   inspector save + `syncFinderTagsNow()` + `exportSidecars()`; the File-menu Export command.
5. **App (build-verified)** — `SettingsView` (General: toggle + sync-now; About: GeoNames attribution +
   credits) + the `Settings` scene. Rebuild the bundle.
6. **Docs** — master spec §10.5 DONE (sidecar export + Finder tags) + GeoNames-attribution-satisfied note
   + changelog. (`catalog-schema.md` v11 already landed in Task 2.)

`XMP`, `SidecarStore`, `AtomicFile`, `Scanner`, `SyncEngine`, the `delete` path, and `updateMetadata` are
**used, not modified** (except the inspector's save routes tags through `tagsForSave`).
