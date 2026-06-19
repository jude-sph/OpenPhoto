import Foundation

/// Sovereign album files in `<libraryRoot>/.openphoto/albums/`, one JSON per album. Mirrors the
/// `LockedFolderStore` pattern: human-authored canonical state, atomic + crash-durable writes, and
/// a rebuildable catalog mirror. One file per album means editing/reordering one album rewrites one
/// small file (not a whole-library file), and a corrupt file loses one album, never all of them.
public enum AlbumStore {
    public static func directoryURL(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(Vault.stateDirName).appendingPathComponent("albums")
    }

    private static func fileURL(id: String, libraryRoot: URL) -> URL {
        directoryURL(libraryRoot: libraryRoot).appendingPathComponent(id + ".json")
    }

    /// Load every album, skipping any unreadable/corrupt file (one bad file never hides the rest).
    /// Sorted by name (case-insensitive) for stable presentation.
    public static func loadAll(libraryRoot: URL) -> [AlbumRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL(libraryRoot: libraryRoot), includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        var out: [AlbumRecord] = []
        for u in urls where u.pathExtension == "json" {
            if let data = try? Data(contentsOf: u),
               let rec = try? dec.decode(AlbumRecord.self, from: data) {
                out.append(rec)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Load a single album by id (for read-modify-write); nil if absent or corrupt.
    public static func load(id: String, libraryRoot: URL) -> AlbumRecord? {
        guard let data = try? Data(contentsOf: fileURL(id: id, libraryRoot: libraryRoot)) else { return nil }
        return try? JSONDecoder().decode(AlbumRecord.self, from: data)
    }

    public static func save(_ album: AlbumRecord, libraryRoot: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]   // stable, human-readable on disk
        try AtomicFile.write(enc.encode(album), to: fileURL(id: album.id, libraryRoot: libraryRoot))
    }

    public static func delete(id: String, libraryRoot: URL) {
        try? FileManager.default.removeItem(at: fileURL(id: id, libraryRoot: libraryRoot))
    }
}
