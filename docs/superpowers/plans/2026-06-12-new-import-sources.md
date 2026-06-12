# New Import Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two read-only import sources — Apple Photos/iCloud (PhotoKit) and Google Takeout — that feed the existing ImportView grid + `ImportEngine`, folding source metadata into self-describing files.

**Architecture:** New `ImportSource` conformances in `OpenPhotoCore/Import/`. A shared `EmbeddedMetadata` losslessly writes/reads standard EXIF+XMP in image files (reusing `XMP.serialize`/`XMP.parse`); the scanner reads embedded XMP as a base layer with `.openphoto/` sidecar precedence. Takeout folds its per-photo JSON into each copied file and discards it. Flat import only.

**Tech Stack:** Swift 6, SwiftPM (CLT only — `swift build`/`swift test`, NO Xcode), ImageIO/CGImageMetadata, Photos (PhotoKit), GRDB catalog, Swift Testing (`import Testing`, `@Test`, `#expect`).

**Hard rules for every task:**
- 0 warnings: `swift build` AND `swift build --build-tests` must both show no warnings.
- TDD for Core-pure pieces (write the failing test first); build-verified for `PhotosLibrarySource` + App wiring.
- NEVER access `~/Pictures`, `~/Movies`, or any personal folder. ALL test media is generated (`makeJPEG` / Core Graphics / `Data`) in `TestDirs` temp dirs.
- Every commit message ends with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Branch: `phase5-import-sources` (already created off `main`). Do NOT run finishing-a-development-branch; the controller merges + pushes at the end.

**Existing APIs to reuse (verified signatures):**
- `XMP.serialize(_ d: SidecarData) -> String`; `XMP.parse(_ data: Data) throws -> SidecarData`.
- `SidecarData(rating: Int, favorite: Bool, caption: String?, tags: [String], faces: [FaceRegion])`; `SidecarData.empty`.
- `MetadataExtractor.extract(from: URL, kind: MediaKind) async -> MediaMetadata`; reads EXIF `DateTimeOriginal`/GPS/camera; mtime fallback for date.
- `ImportSource` protocol: `sourceKey`, `displayName`, `enumerateItems() async throws -> [ImportItem]`, `fetch(_:to:)`, `delete(_:) -> [DeleteResult]`, `thumbnail(_:maxPixel:)`, default `reclaimableTrashCount`/`emptyTrash`/`close`.
- `ImportItem(id:name:byteSize:takenAt:kind:livePartnerID:)`; `pairLiveItems(_:)`.
- `VolumeSource` (the folder-walk + thumbnail template).
- Test helper `makeJPEG(at: URL, dateTimeOriginal: String?, lat: Double?, lon: Double?) throws` (in `MetadataExtractorTests.swift`); `TestDirs` (`.root`, `.sub(_)`, `.file(_,_)`, `.cleanup()`).

---

## Task 1: `EmbeddedMetadata` — lossless write/read of EXIF+XMP, and XMP.parse robustness

**Files:**
- Create: `Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift`
- Modify: `Sources/OpenPhotoCore/Sidecar/XMP.swift` (make rating/label parse accept element form)
- Test: `Tests/OpenPhotoCoreTests/EmbeddedMetadataTests.swift`

ImageIO re-serializes XMP when it writes a packet, and may emit `xmp:Rating`/`xmp:Label` as **child elements** rather than attributes. `XMP.parse` today reads them only as attributes (`attr(desc, "Rating")`). So the round-trip needs `XMP.parse` to accept both forms.

- [ ] **Step 1: Write the failing test for element-form XMP parsing**

Add to `Tests/OpenPhotoCoreTests/EmbeddedMetadataTests.swift`:

```swift
import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotoCore

@Test func xmpParseAcceptsElementFormRatingAndLabel() throws {
    // ImageIO often serializes xmp:Rating / xmp:Label as child ELEMENTS, not attributes.
    let xml = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/">
       <xmp:Rating>4</xmp:Rating>
       <xmp:Label>Favorite</xmp:Label>
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">hello</rdf:li></rdf:Alt></dc:description>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """
    let d = try XMP.parse(Data(xml.utf8))
    #expect(d.rating == 4)
    #expect(d.favorite == true)
    #expect(d.caption == "hello")
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `swift test --filter xmpParseAcceptsElementFormRatingAndLabel`
Expected: FAIL (`rating == 0`, `favorite == false` — current parse only reads attributes).

- [ ] **Step 3: Make `XMP.parse` read rating/label as attribute OR element**

In `Sources/OpenPhotoCore/Sidecar/XMP.swift`, replace these two lines in `parse(_:)`:

```swift
        let rating = Int(attr(desc, "Rating") ?? "0") ?? 0
        let favorite = (attr(desc, "Label") == "Favorite")
```

with:

```swift
        // xmp:Rating / xmp:Label may be an attribute (our serializer) OR a child
        // element (ImageIO's re-serialization). Accept both.
        let ratingStr = attr(desc, "Rating")
            ?? (try? desc.nodes(forXPath: "./*[local-name()='Rating']").first?.stringValue) ?? nil
        let rating = Int(ratingStr ?? "0") ?? 0
        let labelStr = attr(desc, "Label")
            ?? (try? desc.nodes(forXPath: "./*[local-name()='Label']").first?.stringValue) ?? nil
        let favorite = (labelStr == "Favorite")
```

- [ ] **Step 4: Run it — expect PASS**

Run: `swift test --filter xmpParseAcceptsElementFormRatingAndLabel`
Expected: PASS.

- [ ] **Step 5: Write the failing round-trip + EXIF-inject test**

Append to `Tests/OpenPhotoCoreTests/EmbeddedMetadataTests.swift`:

```swift
@Test func embedThenReadRoundTripsHumanMetadata() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("p.jpg")
    try makeJPEG(at: url, dateTimeOriginal: "2021:07:04 12:00:00", lat: nil, lon: nil)

    let data = SidecarData(rating: 4, favorite: true, caption: "beach day", tags: [], faces: [])
    try EmbeddedMetadata.embed(data, exifDate: nil, latitude: nil, longitude: nil, intoImageAt: url)

    let back = try #require(EmbeddedMetadata.read(from: url))
    #expect(back.rating == 4)
    #expect(back.favorite == true)
    #expect(back.caption == "beach day")
}

@Test func embedInjectsExifDateAndGpsReadableByMetadataExtractor() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("nodate.jpg")
    try makeJPEG(at: url, dateTimeOriginal: nil, lat: nil, lon: nil)   // EXIF-less

    let when = Date(timeIntervalSince1970: 1_600_000_000)              // 2020-09-13
    try EmbeddedMetadata.embed(.empty, exifDate: when, latitude: 51.5, longitude: -0.12, intoImageAt: url)

    let m = await MetadataExtractor.extract(from: url, kind: .photo)
    #expect(abs(m.takenAt.timeIntervalSince1970 - when.timeIntervalSince1970) < 2)
    #expect(m.latitude != nil && abs((m.latitude ?? 0) - 51.5) < 0.001)
    #expect(m.longitude != nil && abs((m.longitude ?? 0) - (-0.12)) < 0.001)
}
```

- [ ] **Step 6: Run them — expect FAIL**

Run: `swift test --filter EmbeddedMetadata`
Expected: FAIL (`EmbeddedMetadata` type does not exist).

- [ ] **Step 7: Implement `EmbeddedMetadata`**

Create `Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift`:

```swift
import Foundation
import ImageIO
import CoreGraphics

/// Lossless read/write of standard EXIF + XMP metadata inside image files. The
/// import-time "fold" (Takeout JSON / Apple favorite → self-describing file) and
/// the scanner's embedded-metadata read both go through here, reusing the same
/// `XMP.serialize`/`XMP.parse` as the `.openphoto/` sidecars. Pixels are never
/// recompressed (CGImageDestinationCopyImageSource copies the encoded image).
public enum EmbeddedMetadata {
    public enum EmbedError: Error { case unreadable, badXMP, cantWrite }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Write `data` (as an XMP packet) plus optional EXIF date/GPS into the image,
    /// losslessly, replacing the file in place. A no-op if there is nothing to write.
    public static func embed(_ data: SidecarData, exifDate: Date?,
                             latitude: Double?, longitude: Double?,
                             intoImageAt url: URL) throws {
        if data == .empty && exifDate == nil && latitude == nil { return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { throw EmbedError.unreadable }

        // Start from our XMP packet; mutate to add EXIF/GPS tags.
        let meta: CGMutableImageMetadata
        if data != .empty {
            guard let base = CGImageMetadataCreateFromXMPData(Data(XMP.serialize(data).utf8) as CFData),
                  let mutable = CGImageMetadataCreateMutableCopy(base) else { throw EmbedError.badXMP }
            meta = mutable
        } else {
            meta = CGImageMetadataCreateMutable()
        }
        if let exifDate {
            CGImageMetadataSetValueMatchingImageProperty(
                meta, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal,
                exifDateFormatter.string(from: exifDate) as CFString)
        }
        if let latitude, let longitude {
            func set(_ dict: CFString, _ key: CFString, _ value: CFTypeRef) {
                CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, value)
            }
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(latitude) as CFNumber)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (latitude >= 0 ? "N" : "S") as CFString)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(longitude) as CFNumber)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (longitude >= 0 ? "E" : "W") as CFString)
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw EmbedError.cantWrite
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: kCFBooleanTrue as Any,
        ]
        var err: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err)
        guard ok else { throw (err?.takeRetainedValue() as Error?) ?? EmbedError.cantWrite }
        let fm = FileManager.default
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }

    /// Read the embedded XMP packet (if any) back into a `SidecarData`. Nil when the
    /// file has no XMP or it carries no human metadata.
    public static func read(from url: URL) -> SidecarData? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let xmp = CGImageMetadataCreateXMPData(meta, nil) as Data? else { return nil }
        guard let parsed = try? XMP.parse(xmp), parsed != .empty else { return nil }
        return parsed
    }
}
```

- [ ] **Step 8: Run the full new test file — expect PASS**

Run: `swift test --filter EmbeddedMetadata`
Expected: PASS (all three tests). If `embedThenReadRoundTripsHumanMetadata` fails on `caption`, confirm Step 3 landed; the round-trip is the contract.

- [ ] **Step 9: Verify zero warnings**

Run: `swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift Sources/OpenPhotoCore/Sidecar/XMP.swift Tests/OpenPhotoCoreTests/EmbeddedMetadataTests.swift
git commit -m "$(cat <<'EOF'
feat(import): EmbeddedMetadata — lossless in-file EXIF+XMP fold/read

Shared primitive for the import metadata fold: writes a SidecarData (reusing
XMP.serialize) plus optional EXIF date/GPS into a JPEG/HEIC losslessly via
CGImageDestinationCopyImageSource (no pixel recompress), and reads the embedded
XMP back via XMP.parse. XMP.parse now accepts xmp:Rating/xmp:Label as attribute
OR child element (ImageIO re-serializes them as elements).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Scanner reads embedded XMP as a base layer (sidecar still wins)

**Files:**
- Modify: `Sources/OpenPhotoCore/Scanner/Scanner.swift:92-100`
- Test: `Tests/OpenPhotoCoreTests/EmbeddedScanTests.swift`

Today the scanner sets `caption: nil, favorite: false, rating: 0, tagsJSON: "[]"`, and `ingestSidecars` overrides from `.openphoto/` sidecars. We make embedded XMP a base layer: scanner reads it for new photo assets; sidecars still override (precedence: **sidecar > embedded > defaults**).

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/EmbeddedScanTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func scanReadsEmbeddedCaptionAndRating() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pics")
    let img = pics.appendingPathComponent("a.jpg")
    try makeJPEG(at: img, dateTimeOriginal: "2022:05:01 09:00:00", lat: nil, lon: nil)
    try EmbeddedMetadata.embed(
        SidecarData(rating: 5, favorite: true, caption: "sunset", tags: [], faces: []),
        exifDate: nil, latitude: nil, longitude: nil, intoImageAt: img)

    let lib = try LibraryService(vaultRoots: [pics])
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    #expect(item.caption == "sunset")
    #expect(item.rating == 5)
    #expect(item.favorite == true)
}

@Test func sidecarOverridesEmbedded() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pics")
    let img = pics.appendingPathComponent("a.jpg")
    try makeJPEG(at: img, dateTimeOriginal: "2022:05:01 09:00:00", lat: nil, lon: nil)
    try EmbeddedMetadata.embed(
        SidecarData(rating: 5, favorite: true, caption: "embedded", tags: [], faces: []),
        exifDate: nil, latitude: nil, longitude: nil, intoImageAt: img)

    let lib = try LibraryService(vaultRoots: [pics])
    try await lib.scanAll()
    // User edits the caption in OpenPhoto → sidecar must win on the next scan.
    let vault = try #require(lib.vaults.first)
    try SidecarStore(vault: vault).write(
        SidecarData(rating: 2, favorite: false, caption: "edited", tags: [], faces: []),
        forMediaRelPath: "a.jpg")
    try await lib.rescan(vaultID: vault.descriptor.vaultID)

    let item = try #require(try lib.catalog.timelineItems().first)
    #expect(item.caption == "edited")
    #expect(item.rating == 2)
    #expect(item.favorite == false)
}
```

> Note: confirm `LibraryService(vaultRoots:)` is the constructor used by existing tests (see `LibraryServiceTests.swift`); if the initializer differs, match the pattern there. `TimelineItem` exposes `caption`, `rating`, `favorite` (see `Queries.swift` select list).

- [ ] **Step 2: Run them — expect FAIL**

Run: `swift test --filter "scanReadsEmbeddedCaptionAndRating"`
Expected: FAIL (`caption == nil`, scanner ignores embedded XMP).

- [ ] **Step 3: Read embedded XMP in the scanner**

In `Sources/OpenPhotoCore/Scanner/Scanner.swift`, inside the `if isNew {` block, replace the `AssetRecord(...)` construction's human-metadata fields. Currently:

```swift
                    livePairHash: nil, isLivePairedVideo: false,
                    favorite: false, rating: 0, caption: nil, tagsJSON: "[]"))
```

Change the block to read embedded metadata first:

```swift
            if isNew {
                progress(Progress(stage: .extracting, done: idx, total: aligned.count))
                let m = await MetadataExtractor.extract(from: f.url, kind: f.kind)
                meta = m
                // Base layer: human metadata embedded in the file (Takeout/Apple imports,
                // or any file dragged in with embedded XMP). The `.openphoto/` sidecar
                // ingested after the scan still overrides this (sidecar > embedded).
                let embedded = (f.kind == .photo) ? EmbeddedMetadata.read(from: f.url) : nil
                let embeddedTagsJSON = embedded.flatMap {
                    try? String(data: JSONEncoder().encode($0.tags), encoding: .utf8) ?? "[]"
                } ?? "[]"
                newAssets.append(AssetRecord(
                    hash: entry.hash.stringValue, kind: f.kind.rawValue,
                    takenAtMs: Int64(m.takenAt.timeIntervalSince1970 * 1000),
                    pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                    latitude: m.latitude, longitude: m.longitude,
                    cameraModel: m.cameraModel, lensModel: m.lensModel,
                    durationSeconds: m.durationSeconds,
                    livePairHash: nil, isLivePairedVideo: false,
                    favorite: embedded?.favorite ?? false,
                    rating: embedded?.rating ?? 0,
                    caption: embedded?.caption,
                    tagsJSON: embeddedTagsJSON))
            }
```

- [ ] **Step 4: Run them — expect PASS**

Run: `swift test --filter "EmbeddedScan"`
Expected: PASS (both tests).

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (existing scan/ingest tests unaffected — sidecar precedence preserved).

- [ ] **Step 6: Verify zero warnings**

Run: `swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Scanner/Scanner.swift Tests/OpenPhotoCoreTests/EmbeddedScanTests.swift
git commit -m "$(cat <<'EOF'
feat(scan): read embedded XMP (caption/rating/favorite/tags) as a base layer

New photo assets now pick up human metadata embedded in the file via
EmbeddedMetadata.read; the .openphoto/ sidecar ingested after the scan still
overrides it (precedence sidecar > embedded > defaults). Makes folded
Takeout/Apple imports — and any file with embedded XMP — self-describing.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `TakeoutMetadata` — parse Google Takeout per-photo JSON

**Files:**
- Create: `Sources/OpenPhotoCore/Import/TakeoutMetadata.swift`
- Test: `Tests/OpenPhotoCoreTests/TakeoutMetadataTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/TakeoutMetadataTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func parsesTakeoutJSONFields() throws {
    let json = """
    {
      "title": "IMG_1234.JPG",
      "description": "Beach trip",
      "photoTakenTime": { "timestamp": "1600000000", "formatted": "..." },
      "geoData": { "latitude": 51.5, "longitude": -0.12, "altitude": 0.0 },
      "favorited": true
    }
    """
    let m = try #require(TakeoutMetadata.parse(Data(json.utf8)))
    #expect(m.description == "Beach trip")
    #expect(m.favorited == true)
    #expect(abs((m.latitude ?? 0) - 51.5) < 0.0001)
    #expect(abs((m.longitude ?? 0) - (-0.12)) < 0.0001)
    #expect(m.takenAt == Date(timeIntervalSince1970: 1_600_000_000))
}

@Test func treatsZeroGeoAsAbsentAndMissingFavoriteAsFalse() throws {
    let json = """
    { "photoTakenTime": { "timestamp": "1600000000" },
      "geoData": { "latitude": 0.0, "longitude": 0.0 } }
    """
    let m = try #require(TakeoutMetadata.parse(Data(json.utf8)))
    #expect(m.latitude == nil)        // 0,0 is Google's "no location" sentinel
    #expect(m.longitude == nil)
    #expect(m.favorited == false)
    #expect(m.description == nil)
}
```

- [ ] **Step 2: Run them — expect FAIL**

Run: `swift test --filter TakeoutMetadata`
Expected: FAIL (`TakeoutMetadata` not found).

- [ ] **Step 3: Implement the parser**

Create `Sources/OpenPhotoCore/Import/TakeoutMetadata.swift`:

```swift
import Foundation

/// Parsed subset of a Google Takeout per-photo JSON sidecar (Google Photos export).
public struct TakeoutMetadata: Sendable, Equatable {
    public var takenAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var description: String?
    public var favorited: Bool

    /// Parse a Takeout JSON. Tolerant: unknown fields ignored, 0,0 geo treated as
    /// "no location" (Google's sentinel), missing favorited → false.
    public static func parse(_ data: Data) -> TakeoutMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var takenAt: Date?
        if let pt = obj["photoTakenTime"] as? [String: Any],
           let ts = pt["timestamp"] as? String, let secs = TimeInterval(ts) {
            takenAt = Date(timeIntervalSince1970: secs)
        }

        var lat: Double?, lon: Double?
        if let geo = obj["geoData"] as? [String: Any],
           let la = geo["latitude"] as? Double, let lo = geo["longitude"] as? Double,
           !(la == 0 && lo == 0) {
            lat = la; lon = lo
        }

        let desc = (obj["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fav = (obj["favorited"] as? Bool) ?? false

        return TakeoutMetadata(takenAt: takenAt, latitude: lat, longitude: lon,
                               description: desc, favorited: fav)
    }

    public init(takenAt: Date?, latitude: Double?, longitude: Double?,
                description: String?, favorited: Bool) {
        self.takenAt = takenAt; self.latitude = latitude; self.longitude = longitude
        self.description = description; self.favorited = favorited
    }
}
```

- [ ] **Step 4: Run them — expect PASS**

Run: `swift test --filter TakeoutMetadata`
Expected: PASS.

- [ ] **Step 5: Verify zero warnings**

Run: `swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Import/TakeoutMetadata.swift Tests/OpenPhotoCoreTests/TakeoutMetadataTests.swift
git commit -m "$(cat <<'EOF'
feat(import): TakeoutMetadata — parse Google Takeout per-photo JSON

Extracts photoTakenTime, geoData (0,0 treated as absent), description, and
favorited; tolerant of unknown fields.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `TakeoutJSONMatcher` — find a media file's JSON despite Google's quirks

**Files:**
- Create: `Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift`
- Test: `Tests/OpenPhotoCoreTests/TakeoutJSONMatcherTests.swift`

Google's JSON naming is messy: the modern `…supplemental-metadata.json` suffix, name truncation, and a `(n)` counter that moves after the extension. The matcher generates ordered candidate names; a directory helper returns the first that exists.

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/TakeoutJSONMatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func candidateNamesCoverGoogleQuirks() {
    let plain = TakeoutJSONMatcher.candidateJSONNames(forMediaFilename: "IMG_1234.JPG")
    #expect(plain.contains("IMG_1234.JPG.json"))
    #expect(plain.contains("IMG_1234.JPG.supplemental-metadata.json"))

    // Counter quirk: Google moves "(1)" to after the extension on the JSON.
    let counter = TakeoutJSONMatcher.candidateJSONNames(forMediaFilename: "IMG_1234(1).JPG")
    #expect(counter.contains("IMG_1234.JPG(1).json"))
    #expect(counter.contains("IMG_1234(1).JPG.json"))
}

@Test func resolvesJSONInDirectory() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("album")
    try t.file("album/IMG_1.JPG", Data([0xFF]))
    try t.file("album/IMG_1.JPG.supplemental-metadata.json", Data("{}".utf8))
    let found = TakeoutJSONMatcher.jsonURL(forMediaNamed: "IMG_1.JPG", in: dir)
    #expect(found?.lastPathComponent == "IMG_1.JPG.supplemental-metadata.json")

    #expect(TakeoutJSONMatcher.jsonURL(forMediaNamed: "missing.JPG", in: dir) == nil)
}
```

- [ ] **Step 2: Run them — expect FAIL**

Run: `swift test --filter TakeoutJSONMatcher`
Expected: FAIL (`TakeoutJSONMatcher` not found).

- [ ] **Step 3: Implement the matcher**

Create `Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift`:

```swift
import Foundation

/// Finds the Google Takeout JSON sidecar for a media file. Google's naming is
/// inconsistent across export versions (the 2024+ `.supplemental-metadata.json`
/// suffix, ~46-char truncation, and a `(n)` counter that hops to after the
/// extension), so we try an ordered list of candidates and take the first that exists.
public enum TakeoutJSONMatcher {
    /// Ordered candidate JSON filenames for a given media filename.
    public static func candidateJSONNames(forMediaFilename name: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }

        let suffixes = [".json", ".supplemental-metadata.json", ".supplemental-met.json", ".suppl.json"]
        for s in suffixes { add(name + s) }

        // Counter quirk: "base(n).ext" → JSON "base.ext(n).json".
        if let m = name.range(of: #"\((\d+)\)(\.[^.]+)?$"#, options: .regularExpression) {
            let counter = String(name[m]).replacingOccurrences(of: ".", with: "")  // "(n)" possibly + ext
            // Recover "(n)" and the trailing extension separately.
            if let paren = name.range(of: #"\(\d+\)"#, options: .regularExpression) {
                let n = String(name[paren])                                   // "(1)"
                let base = String(name[name.startIndex..<paren.lowerBound])   // "IMG_1234"
                let ext = String(name[paren.upperBound...])                   // ".JPG" or ""
                add(base + ext + n + ".json")                                 // "IMG_1234.JPG(1).json"
                add(base + ext + n + ".supplemental-metadata.json")
            }
            _ = counter
        }

        // Truncation: Google caps the JSON base name (~46 chars).
        if name.count > 46 {
            add(String(name.prefix(46)) + ".json")
            add(String(name.prefix(46)) + ".supplemental-metadata.json")
        }
        return out
    }

    /// First existing JSON sidecar for `name` in `dir`, or nil.
    public static func jsonURL(forMediaNamed name: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        for candidate in candidateJSONNames(forMediaFilename: name) {
            let url = dir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run them — expect PASS**

Run: `swift test --filter TakeoutJSONMatcher`
Expected: PASS.

- [ ] **Step 5: Verify zero warnings**

Run: `swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift Tests/OpenPhotoCoreTests/TakeoutJSONMatcherTests.swift
git commit -m "$(cat <<'EOF'
feat(import): TakeoutJSONMatcher — resolve a media file's Takeout JSON sidecar

Ordered candidates cover the supplemental-metadata suffix, the (n)-counter
relocation quirk, and ~46-char truncation; returns the first that exists.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `TakeoutSource` — enumerate + fold-and-fetch

**Files:**
- Create: `Sources/OpenPhotoCore/Import/TakeoutSource.swift`
- Test: `Tests/OpenPhotoCoreTests/TakeoutSourceTests.swift`

A read-only `ImportSource` over a Takeout folder. Enumerate walks media (like `VolumeSource`); `takenAt` = EXIF else JSON. `fetch` copies the original, folds the JSON into it (EXIF date/GPS only if missing; description/favorite → embedded XMP), sets mtime = takenAt, and never copies the JSON.

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/TakeoutSourceTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func takeoutFoldsJSONIntoFetchedFile() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("Takeout/Google Photos/Album")
    // EXIF-less photo (so the JSON date must be applied), plus its JSON sidecar.
    let media = dir.appendingPathComponent("IMG_9.JPG")
    try makeJPEG(at: media, dateTimeOriginal: nil, lat: nil, lon: nil)
    let json = """
    { "description": "Picnic",
      "photoTakenTime": { "timestamp": "1600000000" },
      "geoData": { "latitude": 40.0, "longitude": -73.0 },
      "favorited": true }
    """
    try t.file("Takeout/Google Photos/Album/IMG_9.JPG.supplemental-metadata.json", Data(json.utf8))

    let source = TakeoutSource(rootURL: try t.sub("Takeout"), displayName: "Takeout")
    let items = try await source.enumerateItems()
    let item = try #require(items.first { $0.name == "IMG_9.JPG" })

    // Fetch (fold) into a staging file, then read it back.
    let out = t.root.appendingPathComponent("staged.jpg")
    try await source.fetch(item, to: out)

    let embedded = try #require(EmbeddedMetadata.read(from: out))
    #expect(embedded.caption == "Picnic")
    #expect(embedded.favorite == true)

    let m = await MetadataExtractor.extract(from: out, kind: .photo)
    #expect(abs(m.takenAt.timeIntervalSince1970 - 1_600_000_000) < 2)   // JSON date applied
    #expect(m.latitude != nil && abs((m.latitude ?? 0) - 40.0) < 0.001)

    // The JSON is never copied alongside the fetched file.
    #expect(!FileManager.default.fileExists(atPath: out.path + ".json"))
}

@Test func takeoutImportsFileEvenWhenJSONMissing() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("Takeout/Photos")
    try makeJPEG(at: dir.appendingPathComponent("solo.JPG"),
                 dateTimeOriginal: "2019:01:01 00:00:00", lat: nil, lon: nil)
    let source = TakeoutSource(rootURL: try t.sub("Takeout"), displayName: "Takeout")
    let items = try await source.enumerateItems()
    let item = try #require(items.first { $0.name == "solo.JPG" })
    let out = t.root.appendingPathComponent("solo-out.jpg")
    try await source.fetch(item, to: out)                  // must not throw — graceful fallback
    #expect(FileManager.default.fileExists(atPath: out.path))
}
```

- [ ] **Step 2: Run them — expect FAIL**

Run: `swift test --filter TakeoutSource`
Expected: FAIL (`TakeoutSource` not found).

- [ ] **Step 3: Implement `TakeoutSource`**

Create `Sources/OpenPhotoCore/Import/TakeoutSource.swift`:

```swift
import Foundation
import ImageIO
import CoreGraphics

/// Read-only ImportSource over a Google Takeout export folder. Enumerates media
/// like VolumeSource, finds each file's per-photo JSON, and at fetch time folds
/// that JSON into the copied file (standard EXIF + XMP) — producing a
/// self-describing file — then sets mtime and never copies the JSON in.
public final class TakeoutSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let rootURL: URL

    public init(rootURL: URL, displayName: String) {
        self.rootURL = rootURL.resolvingSymlinksInPath()
        self.displayName = displayName
        self.sourceKey = "takeout-" + self.rootURL.path.precomposedStringWithCanonicalMapping
    }

    /// True if a folder looks like a Takeout export (has ≥1 media file with a JSON sidecar).
    public static func looksLikeTakeout(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return false }
        var checked = 0
        for case let f as URL in e {
            guard MediaKind.of(filename: f.lastPathComponent) != nil else { continue }
            if TakeoutJSONMatcher.jsonURL(forMediaNamed: f.lastPathComponent,
                                          in: f.deletingLastPathComponent()) != nil { return true }
            checked += 1
            if checked > 50 { break }   // sample, don't walk a huge tree
        }
        return false
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles]) else { return [] }
        var items: [ImportItem] = []
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootURL.path + "/") else { continue }
            let rel = String(resolved.path.dropFirst(rootURL.path.count + 1))
            let taken = bestTakenAt(mediaURL: url, kind: kind,
                                    mtime: values?.contentModificationDate)
            items.append(ImportItem(id: rel, name: url.lastPathComponent,
                                    byteSize: Int64(values?.fileSize ?? 0),
                                    takenAt: taken, kind: kind, livePartnerID: nil))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        let src = rootURL.appendingPathComponent(item.id)
        try FileManager.default.copyItem(at: src, to: url)

        let json = TakeoutJSONMatcher.jsonURL(forMediaNamed: src.lastPathComponent,
                                              in: src.deletingLastPathComponent())
        let meta = json.flatMap { try? Data(contentsOf: $0) }.flatMap(TakeoutMetadata.parse)
        let taken = meta?.takenAt ?? item.takenAt

        if item.kind == .photo {
            // Only inject EXIF date/GPS when the file lacks them.
            let existing = await MetadataExtractor.extract(from: url, kind: .photo)
            let hasExifDate = existing.takenAt.timeIntervalSince1970 > 0
                && fileHasExifDate(url)
            let injectDate = (!hasExifDate ? taken : nil)
            let injectLat = (existing.latitude == nil ? meta?.latitude : nil)
            let injectLon = (existing.longitude == nil ? meta?.longitude : nil)
            let sidecar = SidecarData(rating: 0, favorite: meta?.favorited ?? false,
                                      caption: meta?.description, tags: [], faces: [])
            try? EmbeddedMetadata.embed(sidecar, exifDate: injectDate,
                                        latitude: injectLat, longitude: injectLon, intoImageAt: url)
        }
        // Videos: keep the capture date via mtime below; a JSON description/favorite on a
        // *video* (rare) is not carried this slice — embedding into .mov isn't clean and a
        // staging-side sidecar wouldn't travel through the engine. Documented limitation.
        //
        // Date durability for EXIF-less files (scanner falls back to mtime).
        if let taken {
            try? FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: url.path)
        }
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { DeleteResult(itemID: $0.id, error: "Takeout import is read-only") }
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        let url = rootURL.appendingPathComponent(item.id)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: helpers

    private func bestTakenAt(mediaURL: URL, kind: MediaKind, mtime: Date?) -> Date? {
        if kind == .photo, let d = exifDate(of: mediaURL) { return d }
        let json = TakeoutJSONMatcher.jsonURL(forMediaNamed: mediaURL.lastPathComponent,
                                              in: mediaURL.deletingLastPathComponent())
        if let m = json.flatMap({ try? Data(contentsOf: $0) }).flatMap(TakeoutMetadata.parse),
           let t = m.takenAt { return t }
        return mtime
    }

    private func fileHasExifDate(_ url: URL) -> Bool { exifDate(of: url) != nil }

    private func exifDate(of url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}
```

- [ ] **Step 4: Run them — expect PASS**

Run: `swift test --filter TakeoutSource`
Expected: PASS (both tests).

- [ ] **Step 5: Run the full suite + verify zero warnings**

Run: `swift test 2>&1 | tail -3 ; swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning`
Expected: all tests pass; no warning output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Import/TakeoutSource.swift Tests/OpenPhotoCoreTests/TakeoutSourceTests.swift
git commit -m "$(cat <<'EOF'
feat(import): TakeoutSource — enumerate + fold JSON into self-describing files

Read-only ImportSource over a Takeout folder. Enumerate walks media (EXIF-or-
JSON capture date); fetch copies the original, folds its JSON in (EXIF date/GPS
only when missing; description/favorited → embedded XMP via EmbeddedMetadata),
sets mtime = capture date, and never copies the JSON. Missing/unparseable JSON
falls back to a plain import. delete() is unsupported (read-only source).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `PhotosLibrarySource` — Apple Photos / iCloud via PhotoKit (build-verified)

**Files:**
- Create: `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift`

No unit tests: `PHAsset` cannot be constructed off a real library. Build-verified here; Jude tests against his Mac's Photos library.

- [ ] **Step 1: Implement `PhotosLibrarySource`**

Create `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift`:

```swift
import Foundation
import CoreGraphics
import AppKit
@preconcurrency import Photos

/// ImportSource for the Mac's Apple Photos library (which is also the iCloud
/// library — network-allowed requests pull iCloud-only originals down on demand).
/// Read-only: copies originals out, never writes to Photos. Hardware-tested, not
/// unit-tested (PHAsset can't be constructed off a real library) — keep this thin.
public final class PhotosLibrarySource: ImportSource, @unchecked Sendable {
    public let sourceKey = "photoslib"
    public let displayName = "Apple Photos"

    enum Role: String { case original, edited, video }
    private struct Entry { let asset: PHAsset; let resource: PHAssetResource; let favorite: Bool; let kind: MediaKind }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]   // ImportItem.id → fetch instruction

    public init() {}

    /// Request read access. `.authorized`/`.limited` can enumerate.
    public static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
    }

    public static var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: opts)

        var items: [ImportItem] = []
        var map: [String: Entry] = [:]

        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let id = asset.localIdentifier
            let created = asset.creationDate
            let fav = asset.isFavorite

            func size(_ r: PHAssetResource) -> Int64 { (r.value(forKey: "fileSize") as? Int64) ?? 0 }
            func emit(_ role: Role, _ res: PHAssetResource, name: String, kind: MediaKind,
                      partnerID: String?) {
                let itemID = "photoslib:\(id):\(role.rawValue)"
                map[itemID] = Entry(asset: asset, resource: res, favorite: fav, kind: kind)
                items.append(ImportItem(id: itemID, name: name, byteSize: size(res),
                                        takenAt: created, kind: kind, livePartnerID: partnerID))
            }

            if asset.mediaType == .image {
                guard let photo = resources.first(where: { $0.type == .photo })
                        ?? resources.first(where: { $0.type == .fullSizePhoto }) else { return }
                let base = photo.originalFilename
                let stillID = "photoslib:\(id):original"
                // Live Photo? link the still to its paired video.
                let paired = resources.first { $0.type == .pairedVideo }
                let videoID = paired != nil ? "photoslib:\(id):video" : nil
                emit(.original, photo, name: base, kind: .photo, partnerID: videoID)
                if let edited = resources.first(where: { $0.type == .fullSizePhoto }) {
                    emit(.edited, edited, name: editedName(base), kind: .photo, partnerID: nil)
                }
                if let paired {
                    emit(.video, paired, name: (base as NSString).deletingPathExtension + ".mov",
                         kind: .video, partnerID: stillID)
                }
            } else if asset.mediaType == .video {
                guard let video = resources.first(where: { $0.type == .video }) else { return }
                emit(.original, video, name: video.originalFilename, kind: .video, partnerID: nil)
                if let edited = resources.first(where: { $0.type == .fullSizeVideo }) {
                    emit(.edited, edited, name: editedName(video.originalFilename), kind: .video, partnerID: nil)
                }
            }
        }
        lock.withLock { entries = map }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        guard let entry = lock.withLock({ entries[item.id] }) else { throw CocoaError(.fileNoSuchFile) }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: entry.resource, toFile: url, options: opts) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        // Fold Apple's favorite into the image (photos only).
        if entry.favorite, item.kind == .photo {
            try? EmbeddedMetadata.embed(
                SidecarData(rating: 0, favorite: true, caption: nil, tags: [], faces: []),
                exifDate: nil, latitude: nil, longitude: nil, intoImageAt: url)
        }
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { DeleteResult(itemID: $0.id, error: "Apple Photos import is read-only") }
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        guard let entry = lock.withLock({ entries[item.id] }) else { return nil }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        let size = CGSize(width: maxPixel, height: maxPixel)
        return await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            let box = ResumeOnce(c)
            PHImageManager.default().requestImage(for: entry.asset, targetSize: size,
                                                  contentMode: .aspectFill, options: opts) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }   // wait for the full-quality callback
                box.resume(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private func editedName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) (edited)" : "\(base) (edited).\(ext)"
    }

    /// PHImageManager.opportunistic can fire its completion more than once; resume the
    /// continuation exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        private let c: CheckedContinuation<CGImage?, Never>
        init(_ c: CheckedContinuation<CGImage?, Never>) { self.c = c }
        func resume(_ v: CGImage?) {
            let go = lock.withLock { if done { return false }; done = true; return true }
            if go { c.resume(returning: v) }
        }
    }
}
```

- [ ] **Step 2: Build (app + tests) — verify it compiles, zero warnings**

Run: `swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning ; echo "exit ok"`
Expected: no warning lines, `echo` prints. If `Photos` fails to link, confirm `import Photos` alone resolves (it is a system framework, auto-linked like `ImageCaptureCore`; NO `Package.swift` change).

- [ ] **Step 3: Run the full suite (no regressions)**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (PhotosLibrarySource has none of its own; nothing else breaks).

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift
git commit -m "$(cat <<'EOF'
feat(import): PhotosLibrarySource — Apple Photos / iCloud via PhotoKit

Read-only ImportSource over the Mac's signed-in Photos library. Enumerates
PHAssets (expanding edited siblings + Live-Photo still/video pairs into linked
ImportItems), fetches originals via PHAssetResourceManager with network access
allowed (pulls iCloud originals on demand), folds Apple's favorite into the
image, and serves cached thumbnails. Build-verified; needs a hardware test.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: App wiring — sidebar sources, auth, Info.plist (build-verified)

**Files:**
- Modify: `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift` (new `ConnectedDevice` cases + factory + Apple Photos entry + Takeout detection)
- Modify: `Sources/OpenPhotoApp/AppState.swift` (`addImportSourceViaPanel` Takeout detection; `sendDestination` returns nil for the new cases — verify)
- Modify: `Sources/OpenPhotoApp/Devices/ImportView.swift` (Photos-denied state)
- Modify: `scripts/make-app.sh` (Info.plist `NSPhotoLibraryUsageDescription`)

- [ ] **Step 1: Add the two `ConnectedDevice` cases + symbols**

In `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift`, extend the enum:

```swift
enum ConnectedDevice: Identifiable, Equatable {
    case camera(id: String, name: String)
    case volume(id: String, name: String, url: URL)
    case photosLibrary
    case takeout(id: String, name: String, url: URL)
    var id: String {
        switch self {
        case .camera(let id, _): "cam-\(id)"
        case .volume(let id, _, _): "vol-\(id)"
        case .photosLibrary: "photoslib"
        case .takeout(let id, _, _): "takeout-\(id)"
        }
    }
    var name: String {
        switch self {
        case .camera(_, let n): n
        case .volume(_, let n, _): n
        case .photosLibrary: "Apple Photos"
        case .takeout(_, let n, _): n
        }
    }
    var symbol: String {
        switch self {
        case .camera: "iphone"
        case .volume: "sdcard"
        case .photosLibrary: "photo.on.rectangle.angled"
        case .takeout: "arrow.down.circle"
        }
    }
}
```

- [ ] **Step 2: Surface Apple Photos permanently + build the new sources**

In `DeviceWatcher`, ensure the Apple Photos entry is always present and the factory builds the new sources. Add to `start()` (after `volumesChanged()`):

```swift
        if !devices.contains(where: { $0.id == "photoslib" }) {
            devices.insert(.photosLibrary, at: 0)
        }
```

In `volumesChanged()`, the `kept` filter must preserve `.photosLibrary` and `.takeout` (they aren't real removable volumes). Replace the `kept` computation:

```swift
        let kept = devices.filter { dev in
            switch dev {
            case .camera, .photosLibrary, .takeout: return true
            case .volume: return dev.id.hasPrefix("vol-manual-")
            }
        }
```

In `source(for:)`, extend the switch:

```swift
        case .photosLibrary:
            made = PhotosLibrarySource()
        case .takeout(_, _, let url):
            made = TakeoutSource(rootURL: url, displayName: device.name)
```

- [ ] **Step 3: Detect Takeout in the add-folder panel**

In `Sources/OpenPhotoApp/AppState.swift`, `addImportSourceViaPanel()` currently calls `deviceWatcher.addManualVolume(url:)`. Change it to branch on Takeout detection. Add a method to `DeviceWatcher`:

```swift
    func addImportFolder(url: URL) {
        if TakeoutSource.looksLikeTakeout(url) {
            let dev = ConnectedDevice.takeout(id: "manual-" + url.path,
                                              name: url.lastPathComponent, url: url)
            if !devices.contains(where: { $0.id == dev.id }) { devices.append(dev) }
        } else {
            addManualVolume(url: url)
        }
    }
```

And in `AppState.addImportSourceViaPanel()`, replace the `deviceWatcher.addManualVolume(url: url)` call with `deviceWatcher.addImportFolder(url: url)`.

Also extend `DeviceWatcher.removeManualVolume` matching so a `.takeout` manual source can be removed (the sidebar's context menu keys on `vol-manual-`; add `takeout-manual-` too). In `SidebarView.swift`, the removable check `device.id.hasPrefix("vol-manual-")` → `device.id.hasPrefix("vol-manual-") || device.id.hasPrefix("takeout-manual-")`.

- [ ] **Step 4: Make the new cases non-send-targets**

In `AppState.swift`, `sendDestination(for:)` switches on `.volume`/`.camera`. Add the new cases returning nil:

```swift
        case .photosLibrary, .takeout:
            return nil
```

(Confirm this is the only `switch device` that must be exhaustive for send; the compiler will flag any other.)

- [ ] **Step 5: Photos-denied state in ImportView**

In `Sources/OpenPhotoApp/Devices/ImportView.swift`, `connect()` builds the source. For the Photos source, request access first and show a denied state. Add a `Phase` case and handle it. In `connect()`, after `source = src`:

```swift
        if src is PhotosLibrarySource {
            let status = PhotosLibrarySource.currentStatus == .authorized
                || PhotosLibrarySource.currentStatus == .limited
                ? PhotosLibrarySource.currentStatus
                : await PhotosLibrarySource.requestAccess()
            if status != .authorized && status != .limited {
                phase = .failedToConnect("OpenPhoto needs access to Apple Photos. Grant it in System Settings → Privacy & Security → Photos, then reopen this source.")
                return
            }
        }
```

(`.failedToConnect(String)` already exists and renders a message — reuse it rather than adding a new phase.)

- [ ] **Step 6: Info.plist usage string**

In `scripts/make-app.sh`, add inside the `<dict>` of the generated Info.plist (e.g. after the `NSPrincipalClass` line):

```
    <key>NSPhotoLibraryUsageDescription</key><string>OpenPhoto imports photos you choose from your Apple Photos library. It only ever copies them out and never modifies your Photos library.</string>
```

- [ ] **Step 7: Build the app target + tests, verify zero warnings**

Run: `swift build 2>&1 | grep -i warning ; swift build --build-tests 2>&1 | grep -i warning ; echo done`
Expected: no warnings; `done` prints. Fix any non-exhaustive-switch errors the new enum cases surface (search the codebase for other `switch` over `ConnectedDevice`).

- [ ] **Step 8: Run full suite**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 9: Rebuild the app bundle**

Run: `./scripts/make-app.sh 2>&1 | tail -3`
Expected: "Built build/OpenPhoto.app".

- [ ] **Step 10: Commit**

```bash
git add Sources/OpenPhotoApp/Devices/DeviceWatcher.swift Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Devices/ImportView.swift Sources/OpenPhotoApp/Sidebar/SidebarView.swift scripts/make-app.sh
git commit -m "$(cat <<'EOF'
feat(import): wire Apple Photos + Google Takeout into the sidebar import list

ConnectedDevice gains .photosLibrary (permanent "Apple Photos" entry) and
.takeout (folder added via the panel, auto-detected). DeviceWatcher builds the
new sources; the add-folder panel routes a Takeout export to TakeoutSource. Both
are import-only (sendDestination → nil). ImportView requests Photos access and
shows a grant-access state when denied. make-app.sh adds
NSPhotoLibraryUsageDescription.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Documentation — master spec §10.5 DONE + changelog

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md` (§10.5 mark import sources DONE; add a changelog entry)

No on-disk/snapshot format change in this slice (no `catalog-schema.md` update needed — the catalog schema/`schemaVersion` is untouched; embedded-XMP reading writes into existing columns).

- [ ] **Step 1: Update §10.5 and add a changelog entry**

In `docs/superpowers/specs/2026-06-07-openphoto-design.md`, in the §10.5 Phase 5 list mark **library import** as done, and add a changelog entry dated 2026-06-12 of the form:

```markdown
- **2026-06-12** — **Phase 5 — new import sources (DONE).** Two read-only `ImportSource`s feeding the existing import grid + pipeline: **`PhotosLibrarySource`** (PhotoKit — Apple gallery + iCloud; network-downloads originals; expands edited siblings + Live-Photo pairs; folds Apple favorite into the file) and **`TakeoutSource`** (Google Takeout folder + per-photo JSON via a quirk-tolerant `TakeoutJSONMatcher`; **folds the JSON's date/GPS/description/favorite into self-describing files** through `EmbeddedMetadata` — lossless EXIF+XMP, no pixel recompress — and discards the JSON). The scanner now reads **embedded XMP** as a base layer (`EmbeddedMetadata.read` → `XMP.parse`), with the `.openphoto/` sidecar still authoritative (sidecar > embedded > defaults). Flat import; the **Folders-screen "Move photos between folders"** organizer is the agreed next slice. **No on-disk/catalog format change.** Spec/plan: `docs/superpowers/specs/2026-06-12-new-import-sources-design.md`, `docs/superpowers/plans/2026-06-12-new-import-sources.md`. Build-verified for `PhotosLibrarySource` (needs Jude's hardware test).
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "$(cat <<'EOF'
docs: Phase 5 new import sources DONE — §10.5 + changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final review (controller, after all tasks)

Dispatch a whole-slice code reviewer over the branch diff (`git diff main...phase5-import-sources`), focusing on: the lossless-fold round-trip correctness, sidecar-vs-embedded precedence, the `ConnectedDevice` exhaustiveness across all switches, and that no test touches real user data. Then merge `phase5-import-sources` → `main` and push (user pre-approved).
