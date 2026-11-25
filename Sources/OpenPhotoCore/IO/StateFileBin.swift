import Foundation

/// The bin for sovereign non-media state files (album and trip JSON). Nothing hard-deletes: removing
/// such a file moves it into a `.bin/` subdirectory of its own directory (e.g. `.openphoto/albums/.bin/`),
/// named `<stem>.deleted-<epochMs>.json` so repeated deletions of the same id all survive. Readers list
/// only the top level of `albums/` / `travels/`, so binned files are invisible to them; restoring is
/// moving the file back under its `<id>.json` name. See vault-format-v1 §15 / §16.
public enum StateFileBin {
    public static let dirName = ".bin"

    /// Move `file` into `<its directory>/.bin/` (a same-volume rename — atomic). No-op if absent.
    public static func move(_ file: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let bin = file.deletingLastPathComponent().appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        var n = 0
        var dst: URL
        repeat {
            let suffix = n == 0 ? "" : "-\(n)"
            dst = bin.appendingPathComponent("\(stem).deleted-\(ms)\(suffix)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        } while fm.fileExists(atPath: dst.path)
        try fm.moveItem(at: file, to: dst)
    }
}
