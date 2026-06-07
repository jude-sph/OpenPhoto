import Foundation

/// All vault-state writes go through this: temp file in the same directory,
/// fsync, then rename over the destination (vault-format-v1 §4, §10).
public enum AtomicFile {
    public static func write(_ data: Data, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-" + UUID().uuidString)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        do {
            try fh.write(contentsOf: data)
            try fh.synchronize()           // fsync
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }
}
