import Foundation
import ImageIO
import CoreGraphics

/// ImportSource for a mounted volume or plain folder (SD card DCIM, etc).
public final class VolumeSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let rootURL: URL

    /// Set BEFORE enumerateItems(); called as capture dates resolve (done, total).
    /// 10k files over USB would take minutes serially — the UI shows this as
    /// "Reading N of M…". Single-enumeration-at-a-time discipline (UI-driven).
    public var enumerationProgress: (@Sendable (Int, Int) -> Void)?
    /// True after enumerateItems() when any adjacent `.xmp` sidecar was seen — the
    /// import screen offers the "Include their metadata" fold only when relevant.
    public private(set) var sawXMPSidecars = false

    public init(rootURL: URL, displayName: String) {
        // Resolve symlinks so that URL paths from FileManager enumeration
        // (which returns resolved paths) match our rootURL.path prefix.
        self.rootURL = rootURL.resolvingSymlinksInPath()
        self.displayName = displayName
        // Volume UUID when available; else stable hash of the path.
        let uuid = (try? rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString
        self.sourceKey = "vol-" + (uuid ?? self.rootURL.path.precomposedStringWithCanonicalMapping)
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { return [] }
        // Pass 1 (fast): collect candidates — no per-file image reads.
        struct Candidate: Sendable {
            let url: URL; let rel: String; let kind: MediaKind
            let size: Int64; let mtime: Date?
        }
        var candidates: [Candidate] = []
        var sawXMP = false
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == ".openphoto-trash" { enumerator.skipDescendants() }
                continue
            }
            if url.pathExtension.lowercased() == "xmp" { sawXMP = true; continue }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            let resolvedURL = url.resolvingSymlinksInPath()
            let rootPath = rootURL.path  // rootURL is already resolved in init
            guard resolvedURL.path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(resolvedURL.path.dropFirst(rootPath.count + 1))
            candidates.append(Candidate(url: url, rel: rel, kind: kind,
                                        size: Int64(values?.fileSize ?? 0),
                                        mtime: values?.contentModificationDate))
        }
        sawXMPSidecars = sawXMP

        // Pass 2: EXIF capture dates with bounded concurrency (8 wide), order-stable.
        let urls = candidates.map(\.url)
        let kinds = candidates.map(\.kind)
        let total = candidates.count
        let progressCB = enumerationProgress
        let exifDates: [Date?] = await withTaskGroup(of: (Int, Date?).self,
                                                     returning: [Date?].self) { group in
            var result = [Date?](repeating: nil, count: urls.count)
            var done = 0
            var next = 0
            func addTask(_ i: Int) {
                group.addTask {
                    guard kinds[i] == .photo else { return (i, nil) }
                    return (i, Self.exifDate(of: urls[i]))
                }
            }
            while next < min(8, urls.count) { addTask(next); next += 1 }
            for await (i, d) in group {
                result[i] = d
                done += 1
                progressCB?(done, total)
                if next < urls.count { addTask(next); next += 1 }
            }
            return result
        }

        var items: [ImportItem] = []
        for (i, c) in candidates.enumerated() {
            items.append(ImportItem(id: c.rel, name: c.url.lastPathComponent,
                                    byteSize: c.size, takenAt: exifDates[i] ?? c.mtime,
                                    kind: c.kind, livePartnerID: nil))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    /// EXIF DateTimeOriginal via a cheap header read (no full decode).
    static func exifDate(of url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    /// UI toggle ("Include their metadata"): fold an adjacent Apple-export `.xmp`
    /// sidecar (Export Unmodified Originals + "IPTC as XMP") into each fetched photo —
    /// Takeout-style, before hashing — so their captions/keywords survive the crossing.
    /// Default off; the sidecar itself is never copied in.
    public var foldXMPSidecars = false

    /// IMG_1.HEIC → IMG_1.xmp (Apple's ext-replaced form) or IMG_1.HEIC.xmp (appended).
    static func xmpSidecarURL(forMedia url: URL) -> URL? {
        let replaced = url.deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: replaced.path) { return replaced }
        let appended = url.appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: appended.path) { return appended }
        return nil
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        let src = rootURL.appendingPathComponent(item.id)
        try FileManager.default.copyItem(at: src, to: url)
        guard foldXMPSidecars, item.kind == .photo,
              let sidecarURL = Self.xmpSidecarURL(forMedia: src),
              let data = try? Data(contentsOf: sidecarURL) else { return }
        var sd = (try? XMP.parse(data)) ?? .empty
        if sd.caption == nil, let title = XMP.parseTitle(data) { sd.caption = title }
        sd.faces = []   // face regions are not carried by the fold
        guard sd != .empty else { return }
        try? EmbeddedMetadata.embed(sd, exifDate: nil, latitude: nil, longitude: nil,
                                    intoImageAt: url)
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        let fm = FileManager.default
        return items.map { item in
            do {
                let src = rootURL.appendingPathComponent(item.id)
                let dst = rootURL.appendingPathComponent(".openphoto-trash")
                    .appendingPathComponent(item.id)
                // Idempotent: source already gone means it was already trashed — success.
                guard fm.fileExists(atPath: src.path) else {
                    return DeleteResult(itemID: item.id, error: nil)
                }
                try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                // If a previous trash copy exists, remove it first so moveItem never throws
                // "already exists" (the source is the authoritative new copy being trashed).
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.moveItem(at: src, to: dst)
                return DeleteResult(itemID: item.id, error: nil)
            } catch {
                return DeleteResult(itemID: item.id, error: String(describing: error))
            }
        }
    }

    public func reclaimableTrashCount() async -> Int {
        let trashURL = rootURL.appendingPathComponent(".openphoto-trash")
        guard let enumerator = FileManager.default.enumerator(
            at: trashURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
               MediaKind.of(filename: url.lastPathComponent) != nil {
                count += 1
            }
        }
        return count
    }

    public func emptyTrash() async throws {
        // The one sanctioned hard delete in the system — user-initiated, on removable media only.
        let trashURL = rootURL.appendingPathComponent(".openphoto-trash")
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return }
        try FileManager.default.removeItem(at: trashURL)
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
}
