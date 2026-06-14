import Foundation

/// Persistent store for the list of Touch-ID-locked folder paths.
///
/// File: `<libraryRoot>/.openphoto/locked-folders.json` — a JSON array of
/// vault-root-relative dirPath strings (vault-format-v1 §1).
/// Survives catalog rebuild; travels with the library.
public enum LockedFolderStore {
    private static let fileName = "locked-folders.json"

    private static func storeURL(libraryRoot: URL) -> URL {
        libraryRoot
            .appendingPathComponent(Vault.stateDirName)
            .appendingPathComponent(fileName)
    }

    /// Loads the locked folder dirPaths for a library.
    /// Returns `[]` if the file is absent or unreadable.
    public static func load(libraryRoot: URL) -> [String] {
        let url = storeURL(libraryRoot: libraryRoot)
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths
    }

    /// Atomically writes the locked folder dirPaths.
    /// Creates `.openphoto/` if needed.
    public static func save(_ dirPaths: [String], libraryRoot: URL) throws {
        let url = storeURL(libraryRoot: libraryRoot)
        let data = try JSONEncoder().encode(dirPaths)
        try AtomicFile.write(data, to: url)
    }
}
