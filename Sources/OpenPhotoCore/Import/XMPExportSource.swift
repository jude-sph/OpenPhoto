import Foundation
import ImageIO
import CoreGraphics

/// Read-only ImportSource over a folder exported as "originals + XMP sidecars" — Apple Photos
/// ("Export Unmodified Original + IPTC as XMP"), Lightroom, digiKam. Enumerates media like
/// VolumeSource; at fetch it FOLDS each file's adjacent `.xmp` (date / GPS / keywords / caption /
/// rating) back into the COPIED file, so the imported library file is self-describing. The original
/// export folder is never touched.
public final class XMPExportSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let rootURL: URL

    public init(rootURL: URL, displayName: String) {
        self.rootURL = rootURL.resolvingSymlinksInPath()
        self.displayName = displayName
        self.sourceKey = "xmpexport-" + self.rootURL.path.precomposedStringWithCanonicalMapping
    }

    /// True if the folder looks like an originals+XMP export: a clear majority of its media files have
    /// an adjacent `.xmp` sidecar. (The caller checks Takeout first — Takeout uses per-photo `.json`.)
    public static func looksLikeXMPExport(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return false }
        var media = 0, withSidecar = 0
        for case let f as URL in e {
            guard MediaKind.of(filename: f.lastPathComponent) != nil else { continue }
            media += 1
            if ForeignXMPSidecar.sidecarURL(forMediaAt: f) != nil { withSidecar += 1 }
            if media >= 60 { break }   // sample, don't walk a huge tree
        }
        return media > 0 && withSidecar * 2 >= media && withSidecar >= 3
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
            items.append(ImportItem(id: rel, name: url.lastPathComponent,
                                    byteSize: Int64(values?.fileSize ?? 0),
                                    takenAt: bestTakenAt(mediaURL: url, kind: kind,
                                                         mtime: values?.contentModificationDate),
                                    kind: kind, livePartnerID: nil))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        let src = rootURL.appendingPathComponent(item.id)
        let meta = ForeignXMPSidecar.sidecarURL(forMediaAt: src)
            .flatMap { try? Data(contentsOf: $0) }.flatMap(ForeignXMPSidecar.parse)
        let taken = meta?.takenAt ?? item.takenAt

        if item.kind == .video, let lat = meta?.latitude, let lon = meta?.longitude,
           await VideoMetadataEmbedder.embed(from: src, to: url,
                                             latitude: lat, longitude: lon, date: taken) {
            // Geolocation embedded straight into the copied .mov/.mp4/.m4v (passthrough — no
            // re-encode), so the video is self-describing. Unsupported containers fall through.
        } else {
            try FileManager.default.copyItem(at: src, to: url)
            if item.kind == .photo {
                // Fold the sidecar into the photo copy where it's missing → self-describing file.
                let gps = existingGPS(url)
                let injectDate = !fileHasExifDate(url) ? taken : nil
                let injectLat = gps.latitude == nil ? meta?.latitude : nil
                let injectLon = gps.longitude == nil ? meta?.longitude : nil
                let sidecar = SidecarData(rating: meta?.rating ?? 0, favorite: false,
                                          caption: meta?.caption, tags: meta?.tags ?? [], faces: [])
                try? EmbeddedMetadata.embed(sidecar, exifDate: injectDate,
                                            latitude: injectLat, longitude: injectLon, intoImageAt: url)
            }
            // (A non-MP4-family video keeps its date via mtime; its sidecar GPS isn't embeddable —
            // those legacy formats essentially never carry GPS.)
        }
        if let taken {
            try? FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: url.path)
        }
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { DeleteResult(itemID: $0.id, error: "XMP export import is read-only") }
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        let url = rootURL.appendingPathComponent(item.id)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    // MARK: helpers

    private func bestTakenAt(mediaURL: URL, kind: MediaKind, mtime: Date?) -> Date? {
        if kind == .photo, let d = exifDate(of: mediaURL) { return d }
        if let s = ForeignXMPSidecar.sidecarURL(forMediaAt: mediaURL),
           let d = (try? Data(contentsOf: s)).flatMap(ForeignXMPSidecar.parse)?.takenAt { return d }
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

    private func existingGPS(_ url: URL) -> (latitude: Double?, longitude: Double?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return (nil, nil) }
        return (gps[kCGImagePropertyGPSLatitude] as? Double, gps[kCGImagePropertyGPSLongitude] as? Double)
    }
}
