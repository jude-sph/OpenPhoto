import Foundation

/// Collision-safe placement names — shared by import placement, volume send, and file moves.
enum FileNaming {
    /// IMG_1.JPG → IMG_1 (2).JPG → IMG_1 (3).JPG …
    static func collisionFreeURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(suffixed)
            n += 1
        }
        return candidate
    }
}
