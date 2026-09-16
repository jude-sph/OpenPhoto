import Foundation

/// Sovereign trip state in `<libraryRoot>/.openphoto/travels/`: `settings.json` plus one JSON per
/// trip record. Same pattern as `AlbumStore`: atomic + crash-durable writes, a corrupt file loses one
/// record never all, and a one-way mirror to drives. See vault-format-v1 §16.
public enum TravelStore {
    static let settingsFileName = "settings.json"

    public static func directoryURL(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(Vault.stateDirName).appendingPathComponent("travels")
    }
    private static func fileURL(id: String, libraryRoot: URL) -> URL {
        directoryURL(libraryRoot: libraryRoot).appendingPathComponent(id + ".json")
    }
    private static func settingsURL(libraryRoot: URL) -> URL {
        directoryURL(libraryRoot: libraryRoot).appendingPathComponent(settingsFileName)
    }
    private static var encoder: JSONEncoder {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; return enc
    }

    // MARK: settings

    /// Missing or corrupt settings → `TravelSettings.defaults`.
    public static func loadSettings(libraryRoot: URL) -> TravelSettings {
        guard let data = try? Data(contentsOf: settingsURL(libraryRoot: libraryRoot)),
              let s = try? JSONDecoder().decode(TravelSettings.self, from: data) else { return .defaults }
        return s
    }
    public static func saveSettings(_ s: TravelSettings, libraryRoot: URL) throws {
        try AtomicFile.write(encoder.encode(s), to: settingsURL(libraryRoot: libraryRoot))
    }

    // MARK: records

    /// Every record, skipping `settings.json` and any unreadable/corrupt file. Sorted by id for a
    /// stable order (presentation order is decided by the resolver, by date).
    public static func loadAll(libraryRoot: URL) -> [TravelRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL(libraryRoot: libraryRoot), includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        var out: [TravelRecord] = []
        for u in urls where u.pathExtension == "json" && u.lastPathComponent != settingsFileName {
            if let data = try? Data(contentsOf: u), let r = try? dec.decode(TravelRecord.self, from: data) {
                out.append(r)
            }
        }
        return out.sorted { $0.id < $1.id }
    }
    public static func load(id: String, libraryRoot: URL) -> TravelRecord? {
        guard let data = try? Data(contentsOf: fileURL(id: id, libraryRoot: libraryRoot)) else { return nil }
        return try? JSONDecoder().decode(TravelRecord.self, from: data)
    }
    public static func save(_ r: TravelRecord, libraryRoot: URL) throws {
        try AtomicFile.write(encoder.encode(r), to: fileURL(id: r.id, libraryRoot: libraryRoot))
    }
    public static func delete(id: String, libraryRoot: URL) {
        try? FileManager.default.removeItem(at: fileURL(id: id, libraryRoot: libraryRoot))
    }

    // MARK: drive mirror

    /// One-way mirror of `travels/` (records AND settings.json) to `<driveStateDir>/travels/`: copy
    /// every source file, delete drive files absent on the source. Paths inside are vault-relative
    /// and drives keep the vault's folder layout, so files copy verbatim.
    public static func syncToDrive(libraryRoot: URL, driveStateDir: URL) throws {
        let fm = FileManager.default
        let srcDir = directoryURL(libraryRoot: libraryRoot)
        let dstDir = driveStateDir.appendingPathComponent("travels")
        let srcFiles = ((try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let srcNames = Set(srcFiles.map(\.lastPathComponent))
        for f in srcFiles {
            try AtomicFile.write(try Data(contentsOf: f), to: dstDir.appendingPathComponent(f.lastPathComponent))
        }
        let dstFiles = ((try? fm.contentsOfDirectory(at: dstDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        for f in dstFiles where !srcNames.contains(f.lastPathComponent) { try? fm.removeItem(at: f) }
    }
}
