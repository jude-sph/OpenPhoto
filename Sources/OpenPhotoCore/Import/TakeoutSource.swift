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
            let gps = existingGPS(url)
            let injectDate = (!fileHasExifDate(url) ? taken : nil)
            let injectLat = (gps.latitude == nil ? meta?.latitude : nil)
            let injectLon = (gps.longitude == nil ? meta?.longitude : nil)
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

    /// Existing GPS coordinates already encoded in the image, if any.
    private func existingGPS(_ url: URL) -> (latitude: Double?, longitude: Double?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else {
            return (nil, nil)
        }
        let lat = gps[kCGImagePropertyGPSLatitude] as? Double
        let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        return (lat, lon)
    }
}
