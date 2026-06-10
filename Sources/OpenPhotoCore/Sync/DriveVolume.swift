import Foundation

public enum DriveVolumeError: Error, Equatable {
    /// The filesystem could not report available capacity for `rootURL`.
    case capacityUnavailable
}

/// A mounted location that may host an OpenPhoto vault. Abstracted so a plain
/// folder (CI), an attached exFAT disk image (realism), and a real removable
/// volume are interchangeable to the sync engine.
public protocol DriveVolume: Sendable {
    var rootURL: URL { get }
    /// True when `rootURL` is reachable as a directory (the volume/folder is present).
    var isMounted: Bool { get }
    /// Bytes available for new files. Throws rather than returning a misleading 0
    /// when capacity can't be determined, so callers don't mistake it for "full".
    func freeSpaceBytes() throws -> Int64
}

/// Path-backed volume — used for real volumes, attached `.dmg`s, and plain folders.
/// (This app uses plain paths, not security-scoped bookmarks, so one type covers all.)
public struct FileSystemVolume: DriveVolume {
    public let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL }

    public var isMounted: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func freeSpaceBytes() throws -> Int64 {
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        // `volumeAvailableCapacityForImportantUsage` returns 0 on some filesystems (e.g. exFAT)
        // to signal "metric unsupported" rather than "disk full". Treat 0 as unsupported and fall
        // through to the plain capacity, which those volumes do report correctly.
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int64(important)
        }
        if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        throw DriveVolumeError.capacityUnavailable
    }
}
