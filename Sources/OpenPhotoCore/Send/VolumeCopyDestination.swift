import Foundation
import ImageIO
import CoreGraphics

/// Sends library assets to a mounted volume (SD card / USB) by direct copy into a
/// destination subfolder, verified byte-for-byte by content hash. Fully testable.
public final class VolumeCopyDestination: SendDestination, @unchecked Sendable {
    public let destinationKey: String
    public let displayName: String
    public let deviceKind: DeviceKind = .volume
    private let folderURL: URL

    public init(volumeRoot: URL, subfolder: String = "OpenPhoto", displayName: String) {
        let resolved = volumeRoot.resolvingSymlinksInPath()
        self.folderURL = resolved.appendingPathComponent(subfolder)
        self.displayName = displayName
        let uuid = (try? volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        self.destinationKey = "vol-" + (uuid ?? resolved.path.precomposedStringWithCanonicalMapping)
    }

    public func enumeratePresent() async throws -> [PresenceFingerprint] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [PresenceFingerprint] = []
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true, MediaKind.of(filename: url.lastPathComponent) != nil else { continue }
            let size = Int64(v?.fileSize ?? 0)
            let captureMs = Self.captureDateMs(of: url, mtime: v?.contentModificationDate)
            let hash = try? ContentHash.ofFile(at: url).stringValue
            out.append(PresenceFingerprint(size: size, captureDateMs: captureMs, hash: hash))
        }
        return out
    }

    public func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome] {
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var outcomes: [SendOutcome] = []
        for (i, item) in items.enumerated() {
            progress(SendProgress(stage: .sending, done: i, total: items.count, currentName: item.displayName))
            let target = FileNaming.collisionFreeURL(for: item.displayName, in: folderURL)
            do {
                try fm.copyItem(at: item.originalURL, to: target)
                // Flush to the physical device before verifying: copyItem writes through
                // the page cache, so on removable media an unmount between copy and hash
                // could otherwise verify against unflushed data (invariant #4).
                if let fh = try? FileHandle(forUpdating: target) {
                    let flushed = (try? fh.synchronize()) != nil
                    try? fh.close()
                    if !flushed {
                        try? fm.removeItem(at: target)
                        outcomes.append(SendOutcome(item: item, status: .failed, error: "flush failed"))
                        continue
                    }
                }
                let writtenHash = try ContentHash.ofFile(at: target).stringValue
                if writtenHash == item.hash {
                    outcomes.append(SendOutcome(item: item, status: .confirmed))
                } else {
                    try? fm.removeItem(at: target)
                    outcomes.append(SendOutcome(item: item, status: .failed, error: "verify mismatch"))
                }
            } catch {
                try? fm.removeItem(at: target)   // clean up any partial copy on copy/hash failure
                outcomes.append(SendOutcome(item: item, status: .failed, error: String(describing: error)))
            }
        }
        return outcomes
    }

    // EXIF DateTimeOriginal for photos (cheap header read), else file mtime.
    private static func captureDateMs(of url: URL, mtime: Date?) -> Int64 {
        if MediaKind.of(filename: url.lastPathComponent) == .photo,
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        if let m = mtime { return Int64(m.timeIntervalSince1970 * 1000) }
        return 0
    }

}
