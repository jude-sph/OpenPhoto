import Foundation

/// Atomic, hash-verified file copy: temp → fsync → re-hash → rename. Never overwrites an
/// existing destination, and leaves no partial/temp file behind on failure.
public enum VerifiedCopy {
    /// Copy `source` to `dest` and confirm the written bytes hash to `expectedHash`.
    /// Returns true only when the verified file is in place. Returns false (writing nothing
    /// at `dest`) on any failure, hash mismatch, or if `dest` already exists.
    @discardableResult
    public static func copy(from source: URL, to dest: URL, expectedHash: String) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return false } // never overwrite
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
            defer { try? fm.removeItem(at: tmp) }                      // no-op once renamed
            try fm.copyItem(at: source, to: tmp)
            if let fh = try? FileHandle(forUpdating: tmp) { _ = try? fh.synchronize(); try? fh.close() }
            guard (try? ContentHash.ofFile(at: tmp).stringValue) == expectedHash else { return false }
            try fm.moveItem(at: tmp, to: dest)                         // atomic; dest is absent
            return true
        } catch { return false }
    }
}
