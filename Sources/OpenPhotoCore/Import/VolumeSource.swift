import Foundation
import ImageIO
import CoreGraphics

/// ImportSource for a mounted volume or plain folder (SD card DCIM, etc).
public final class VolumeSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let rootURL: URL

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
        var items: [ImportItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == ".openphoto-trash" { enumerator.skipDescendants() }
                continue
            }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            // Capture date: EXIF for photos (cheap header read), mtime fallback.
            var taken = values?.contentModificationDate
            if kind == .photo, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                taken = f.date(from: s) ?? taken
            }
            // Derive the relative path robustly — resolved paths must share the prefix.
            let resolvedURL = url.resolvingSymlinksInPath()
            let rootPath = rootURL.path  // rootURL is already resolved in init
            guard resolvedURL.path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(resolvedURL.path.dropFirst(rootPath.count + 1))
            items.append(ImportItem(id: rel, name: url.lastPathComponent,
                                    byteSize: Int64(values?.fileSize ?? 0),
                                    takenAt: taken, kind: kind, livePartnerID: nil))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        try FileManager.default.copyItem(at: rootURL.appendingPathComponent(item.id), to: url)
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
