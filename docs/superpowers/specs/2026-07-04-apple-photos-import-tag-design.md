# "From Apple Photos" import tag — design

**Date:** 2026-07-04
**Status:** approved

## Goal

Photos imported from the Mac's Apple Photos library automatically gain the keyword tag
`From Apple Photos`, gated by a user setting (default on).

## Behaviour

- **Scope:** only imports from the Apple Photos source (`PhotosLibrarySource`, `sourceKey == "photoslib"`).
  Other sources (SD card / volume, camera, Google Takeout / foreign vault) are unaffected.
- **Only newly imported photos** get the tag. A photo already in the library that is skipped as a
  duplicate during an Apple Photos import is left untouched (it is never placed, so it never gets the
  tag). Applies going forward only — not retroactively.
- **The tag is a normal keyword tag** — the same kind set by hand via `updateMetadata`. It is written to
  the XMP sidecar (human-authored metadata, per vault invariant 2) and mirrored to the catalog, so it is
  searchable, appears in the tag list, and can be removed like any tag. It **merges** with any existing
  tags — never replaces them.
- **Fixed text:** `From Apple Photos` (constant, not user-editable).

## Setting

- `AppState.tagApplePhotosImports: Bool`, `UserDefaults`-backed (key `"tagApplePhotosImports"`),
  **default on** (using the `object(forKey:) == nil ? true : bool(forKey:)` idiom so it stays on until
  explicitly turned off — mirrors `viewerGalleryShown` / `sidebarShown`).
- Surfaced in `SettingsView` as a toggle **"Tag Apple Photos imports"** with a one-line explanation,
  next to the existing "Sync tags with Finder" toggle (both are import/tag-related preferences).

## Integration point

In `ImportView.startImport()`, after `ImportEngine.run(...)` returns: when
`source.sourceKey == "photoslib"` and `state.tagApplePhotosImports` is on, apply the tag to each
`result.imported` item through the canonical `LibraryService.updateMetadata(...)` path (read existing
metadata, append the tag if absent, write sidecar + catalog). Skipped duplicates are ignored.

Chosen over writing the tag into the sidecar during `ImportEngine`'s `postPlace` hook (which the single
post-import rescan would fold in) because `updateMetadata` reads post-rescan state and merges correctly
with anything the import already captured. If a very large Apple Photos import proves slow, batch the
catalog side later; correctness first.

The tag policy lives in the app layer (`ImportView`) — the Core `ImportEngine` stays generic.

## Testing

- Importing a mock item from a stub Apple Photos source (sourceKey `"photoslib"`) tags the placed
  item's sidecar + catalog with `From Apple Photos`.
- A non-Apple source does **not** apply the tag.
- The tag **merges** with a pre-existing tag rather than replacing it.
- The setting gates it (off → no tag).
- A skipped duplicate is not tagged.

## Out of scope

- Editable tag text; a per-import prompt; retroactive tagging of already-imported Apple Photos items;
  applying the tag to duplicates.
