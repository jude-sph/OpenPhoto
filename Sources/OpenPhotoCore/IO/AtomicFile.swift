import Foundation

/// All vault-state writes go through this: temp file in the same directory,
/// crash-durable flush, then rename over the destination (vault-format-v1 §4, §10).
///
/// Durability is `F_FULLFSYNC` (asks the drive to flush its write cache, which a plain
/// `fsync`/`F_FSYNC` does not guarantee on macOS) on the temp file, plus an `fsync` of the
/// parent directory after the rename — without the latter the rename itself can be lost on
/// power-loss even though the file's bytes are durable. `F_FULLFSYNC` is unsupported on some
/// filesystems (e.g. network volumes) and returns `ENOTSUP`; we fall back to a plain fsync there.
public enum AtomicFile {
    public static func write(_ data: Data, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-" + UUID().uuidString)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        do {
            try fh.write(contentsOf: data)
            fullSync(fh.fileDescriptor)    // F_FULLFSYNC (fall back to fsync)
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        syncDirectory(dir)                 // make the rename itself durable
    }

    /// Flush a file's data all the way to stable storage. `F_FULLFSYNC` is the only call that
    /// forces the drive to flush its own write cache; if the filesystem doesn't support it
    /// (`ENOTSUP`, e.g. SMB/NFS) we degrade to a plain `fsync`.
    private static func fullSync(_ fd: Int32) {
        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
    }

    /// fsync the directory so a newly-created or renamed entry survives a crash/power-loss.
    private static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
    }
}
