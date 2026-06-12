# New Import Sources (Apple Photos / iCloud + Google Takeout) — Design

**Status:** approved (Jude, 2026-06-12) — build end-to-end (spec → plan → implementation), PhotoKit source first, then Takeout.

**Goal:** Let the user import their existing photo libraries into OpenPhoto: the Mac's **Apple Photos** library (which is also their **iCloud** library), and **Google Photos** via a **Google Takeout** export folder. Both copy *out* into plain files and never write back to the source.

**Architecture in one line:** two new read-only `ImportSource` conformances feeding the **existing** ImportView grid + `ImportEngine` pipeline (copy → hash → dedup → place → rescan → verify → registry). No new import screen, no new pipeline.

---

## 1. Scope & decisions (from the brainstorm)

- **Two sources, one slice, PhotoKit first.** Apple Photos/iCloud via PhotoKit, then Google Takeout. They're independent subsystems sharing the "import a whole library" framing.
- **"iCloud" is not a separate source.** The Mac's Photos library *is* the iCloud library; PhotoKit downloads iCloud-only originals on demand (`isNetworkAccessAllowed`). One `PhotosLibrarySource` covers Apple gallery + iCloud.
- **Google = Takeout, not a live API.** The Google Photos Library API was restricted in 2025 (apps can only read media they uploaded). Takeout (a user-exported folder of originals + per-photo JSON) is the sovereignty-correct path.
- **Edited photos: keep both.** Import the pristine original *and* the edited render as a sibling (`IMG_1234.heic` + `IMG_1234 (edited).heic`). The pair will surface in Tidy Up as a near-dup — accepted.
- **Flat import.** Everything lands in **one destination folder** the user picks (exactly like phone import). Organizing into folders afterward is a **separate, deferred slice** ("Move photos between folders", recorded in the master spec backlog).
- **Reuse the existing import screen.** Both sources enumerate into the same selectable grid (Select-all-new, deselect, rubber-band/shift, the "already imported" fingerprint, the drive glyph, live-pair expansion, the destination picker). Thousands is smooth (lazy grid); tens of thousands → import in chunks.
- **Fold metadata into self-describing files.** Google Takeout's JSON is folded into each copied file (standard embedded EXIF + XMP) and **discarded** — no JSON enters the library. To surface the folded human metadata, the scanner learns to read **embedded XMP** (reusing `XMP.parse`). The `.openphoto/` sidecar still takes precedence for the user's later edits.

---

## 2. `PhotosLibrarySource` (PhotoKit) — Apple Photos + iCloud

A new `OpenPhotoCore/Import/PhotosLibrarySource.swift`, `@unchecked Sendable`, `sourceKey = "photoslib"`.

### Authorization
- `PHPhotoLibrary.requestAuthorization(for: .readWrite)` on first use (reading the existing library needs `.readWrite` on macOS). States: `.authorized`/`.limited` → enumerate; `.denied`/`.restricted` → the import screen shows a "grant access in System Settings → Privacy → Photos" view instead of a grid.
- Bundling: `make-app.sh`'s Info.plist gains `NSPhotoLibraryUsageDescription`.

### Enumerate — asset → ImportItem(s)
`PHAsset.fetchAssets(with:)`, `sortDescriptors = creationDate descending`; Hidden and Recently-Deleted excluded by default. Each `PHAsset` expands into 1–3 items (the wrinkle vs a DCIM folder, where each file is already separate):

| Asset | Items produced |
|---|---|
| Plain photo | original (`.photo`) |
| Edited photo | original (`.photo`) **+** edited sibling (`.fullSizePhoto`), name `… (edited).ext` |
| Live Photo | still (`.photo`, + edited sibling if edited) **+** paired video (`.pairedVideo`), `livePartnerID`-linked |
| Video | original (`.video`) **+** edited (`.fullSizeVideo`) if present |

- `id` encodes the asset + which resource to pull, e.g. `photoslib:<localIdentifier>:<role>` where role ∈ `{original, edited, video}`. The source holds a `[id: (PHAsset, PHAssetResource)]` map built during enumeration.
- `name` ← primary resource `originalFilename`; `byteSize` ← resource size (`resource.value(forKey: "fileSize")`); `takenAt` ← `asset.creationDate`; `kind` ← `mediaType`.
- `isFavorite` is carried as per-item human metadata (folded at fetch, §4).

### Fetch
`PHAssetResourceManager.default().writeData(for: resource, toFile: stagingURL, options:)` with `options.isNetworkAccessAllowed = true` (pulls iCloud-only originals down on demand), wrapped in a continuation. Writes straight to the engine's staging path, so `fetch(item, to:)` is a thin wrapper. After the original is staged, fold favorite into it (§4).

### Thumbnail
`PHImageManager.default().requestImage(for: asset, targetSize:, contentMode: .aspectFill, options:)` (`isNetworkAccessAllowed = true`, opportunistic delivery) → `CGImage`.

### Not supported
`delete` returns "not supported" for every item (we never modify Apple's library); `reclaimableTrashCount`/`emptyTrash` are the protocol defaults.

---

## 3. `TakeoutSource` (Google) — folder + per-photo JSON, folded into files

A new `OpenPhotoCore/Import/TakeoutSource.swift`, built like `VolumeSource` (walks a folder) but with JSON discovery + a metadata fold.

### What Takeout looks like
`Takeout/Google Photos/<album or "Photos from 2019">/photo.jpg` + a sidecar JSON: `photo.jpg.json` or `photo.jpg.supplemental-metadata.json` (2024+). Fields used: `photoTakenTime.timestamp` (epoch seconds), `geoData.{latitude,longitude}`, `description`, `favorited`. Edited photos export as `photo.jpg` **and** `photo-edited.jpg` (both imported). Live Photos export as `.jpg`/`.heic` + `.mov` (existing basename live-pairing).

### The JSON matcher (`TakeoutJSONMatcher`, the fiddly part — unit-tested)
Given a media filename, generate an ordered list of candidate JSON names and return the first that exists; if none, return nil and fall back to EXIF/mtime. Candidates cover Google's quirks:
1. `<fullname>.json`
2. `<fullname>.supplemental-metadata.json`
3. **Truncation:** Google caps the combined name (~46–51 chars) — try the truncated base.
4. **`(n)` counter relocation:** `IMG_1234(1).JPG` → JSON `IMG_1234.JPG(1).json` (counter moved after the extension).
5. Truncated/abbreviated suffix variants (`.suppl…`).

### Detection (which folders become a `TakeoutSource`)
Added via the existing **"Add import source…"** panel. The chosen folder is a `TakeoutSource` if it (recursively, sampled) contains media with resolvable JSON sidecars; otherwise a plain `VolumeSource`. New `ConnectedDevice.takeout` case (import-only; never a send target).

### Enumerate
Walk media files (like `VolumeSource`); `takenAt` = EXIF `DateTimeOriginal` (cheap header read) else the JSON's `photoTakenTime`. `id` = relpath, as `VolumeSource`.

### Fetch — fold then discard JSON
1. Copy the original media file to staging.
2. **Images:** losslessly fold metadata in (§4): inject EXIF `DateTimeOriginal`/GPS **only if missing**; embed `description` → XMP, `favorited` → XMP, via `XMP.serialize`. Set the staged file's **mtime = takenAt** (so EXIF-less files still get the right date through the scanner's mtime fallback).
3. **Videos:** copy as-is; set **mtime = takenAt**; a description/favorite on a *video* (rare) falls back to a `.openphoto/` sidecar (can't embed cleanly in `.mov`).
4. The JSON is **never** copied into the library.

---

## 4. Metadata fold + scanner reads embedded XMP

This is the shared mechanism that makes Takeout/Apple imports self-describing, plus the one Core extension it needs. New `OpenPhotoCore/Media/EmbeddedMetadata.swift`.

### Writing (the fold) — `embed(_:exifDate:gps:intoImageAt:)`
- Build a `SidecarData {caption, favorite, rating, tags, faces}` from the source's metadata (Google `description`/`favorited`; Apple `isFavorite`).
- Serialize with the **existing `XMP.serialize`** → an XMP packet (`xmp:Rating`, `xmp:Label="Favorite"`, `dc:description` — same vocabulary as our sidecars).
- Losslessly write into the image via ImageIO: `CGImageMetadataCreateFromXMPData` for the XMP packet + EXIF `DateTimeOriginal`/GPS tags (only when absent), applied with `CGImageDestinationCopyImageSource(dest, src, [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true], …)` — **pixels are not recompressed**. The result is the file the engine hashes/places/verifies normally.
- Degrades gracefully: if ImageIO refuses a particular file, copy it unmodified + set mtime, and write caption/favorite to a `.openphoto/` sidecar instead. The photo always imports.

### Reading — scanner learns embedded XMP
- `EmbeddedMetadata.read(from:) -> SidecarData?`: `CGImageSourceCopyMetadataAtIndex` → `CGImageMetadataCreateXMPData` → the **existing `XMP.parse`**. (EXIF date/GPS are already read by `MetadataExtractor`.)
- The scan applies embedded human metadata as a **base layer** (caption/rating/favorite/tags/faces), then `.openphoto/` sidecar ingestion **overrides** where a sidecar exists. **Precedence: sidecar > embedded > defaults.** Sidecar-less files keep their embedded values; the user's later OpenPhoto edits (written to the sidecar) always win.
- Cheap: the scanner already opens a `CGImageSource` per image for EXIF; reading the XMP packet is one more call in the same pass. This is a *general* capability — any file dragged in with an embedded caption/rating is now respected.

### Why the fold is allowed (sovereignty)
Folding happens **once, while copying the file in, before it is a tracked OpenPhoto original** — so it never modifies a library original and never churns the content hash the catalog/dedup/sync key on. Embedding OpenPhoto's *ongoing* edits into files is explicitly **out of scope** (deferred note in the master spec: it would rewrite originals + change hashes on every edit).

---

## 5. App wiring

- **`ConnectedDevice`** gains `.photosLibrary` (permanent sidebar entry "Apple Photos", symbol e.g. `photo.on.rectangle.angled`) and `.takeout` (added via the panel; symbol e.g. `arrow.down.circle`). Both return `nil` from `sendDestination(for:)` (import-only) and are skipped by send-reverify.
- **`DeviceWatcher`**: surfaces the permanent Apple Photos entry; `source(for:)` builds `PhotosLibrarySource` / `TakeoutSource`; the "Add import source…" panel detects Takeout vs plain folder.
- **`ImportView`**: a denied/restricted-Photos-access state (button → open System Settings).
- **`make-app.sh`**: `NSPhotoLibraryUsageDescription`. No `Package.swift` change — `Photos` is a system framework auto-linked by `import Photos`, exactly like `ImageCaptureCore`.

---

## 6. Error handling (follows §8 doctrine — per-item, never fail the batch)

- iCloud original won't download (offline/unavailable) → item goes to `BatchResult.failed` ("N FAILED" footer); the rest import.
- Fold can't rewrite a file → unmodified copy + mtime + sidecar fallback (above).
- Takeout JSON missing/unparseable → import with EXIF/mtime date, no description.
- Hash-verify still gates registry entry exactly as today (fold happens before hashing).
- Photos access denied → access-needed screen, no crash.

---

## 7. Testing

- **TDD (Core, synthetic data only — never real photos):**
  - `TakeoutMetadata` JSON parser (synthetic JSON → date/geo/description/favorited).
  - `TakeoutJSONMatcher` (the Google naming quirks — truncation, `(n)` counters, `supplemental-metadata`, extension handling).
  - `EmbeddedMetadata` round-trip: build `SidecarData` → embed into a Core-Graphics-generated JPEG → read back via `XMP.parse`; EXIF date/GPS inject → read back via `MetadataExtractor`.
  - Scanner embedded-XMP read + **sidecar-precedence** (generate a JPEG with embedded `xmp:Rating`/`dc:description` → scan → catalog populated; add a sidecar → it overrides).
- **Build-verified + Jude's hardware test:** `PhotosLibrarySource` (`PHAsset` can't be constructed off a real library; verified like `CameraSource`). All generated media lives in `TestDirs`/temp dirs only.

---

## 8. Out of scope (this slice)

- The batch **"Move photos between folders"** organizer → the agreed next slice (master-spec backlog note).
- Embedding OpenPhoto's **own ongoing** rating/caption into files → deferred note.
- **Other people's** Apple/iCloud and **per-folder import from others' OpenPhoto drives** → deferred note.
- Apple **keywords/albums** (not exposed / non-exclusive); **video** GPS/description embedding; importing Google **people** tags (unreliable).

---

## 9. File structure

**Create (Core):** `Import/PhotosLibrarySource.swift`, `Import/TakeoutSource.swift`, `Import/TakeoutMetadata.swift`, `Import/TakeoutJSONMatcher.swift`, `Media/EmbeddedMetadata.swift`.
**Modify (Core):** `Media/MetadataExtractor.swift` and/or `Scanner/Scanner.swift` + `LibraryService` ingest (embedded-XMP base layer + precedence).
**Modify (App):** `Devices/DeviceWatcher.swift` (new cases, factory, Apple Photos entry, Takeout detection), `AppState.swift` (panel detection, Photos auth), `Devices/ImportView.swift` (denied state), `scripts/make-app.sh` (Info.plist key).

## 10. Sovereignty invariants check

1. Originals never modified — ✅ the fold edits *incoming copies* before they become originals; library originals untouched.
2. Human-authored → XMP / machine-derived → catalog — ✅ folded human metadata is standard XMP (in-file at import; sidecar for ongoing edits); date/GPS ride in EXIF; catalog stays rebuildable.
3. Nothing hard-deletes — ✅ sources are read-only; nothing is deleted from Apple Photos or the Takeout folder.
4. Atomic writes / hash-verified copies — ✅ unchanged pipeline (staging → verify → place); fold precedes hashing so the placed file verifies normally.
5. One-way / passive — ✅ import only copies out; never writes to the source library.
