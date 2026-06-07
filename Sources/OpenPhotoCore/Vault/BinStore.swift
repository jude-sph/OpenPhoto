import Foundation

/// Vault bin — vault-format-v1 §8. Nothing in the system hard-deletes.
public struct BinStore: Sendable {
    public enum Origin: String, Codable, Sendable { case user, propagated }

    public struct BinItem: Codable, Equatable, Sendable {
        public let hash: String
        public let path: String
        public let deletedAt: String
        public let origin: Origin
        enum CodingKeys: String, CodingKey {
            case hash, path, origin
            case deletedAt = "deleted_at"
        }
    }

    let vault: Vault
    public init(vault: Vault) { self.vault = vault }

    public func moveToBin(relPath: String, hash: ContentHash, origin: Origin) throws {
        let fm = FileManager.default
        let src = vault.absoluteURL(forRelativePath: relPath)
        let dst = vault.binDirURL.appendingPathComponent(relPath)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        // Sidecar travels with the file, same folder-level convention inside bin/.
        let sidecar = vault.sidecarURL(forMediaAt: src)
        if fm.fileExists(atPath: sidecar.path) {
            let sidecarDst = vault.sidecarURL(forMediaAt: dst)
            try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: sidecar, to: sidecarDst)
        }
        var items = try list()
        items.append(BinItem(hash: hash.stringValue, path: relPath,
                             deletedAt: ISO8601Millis.string(from: Date()), origin: origin))
        try writeLog(items)
    }

    public func restore(relPath: String) throws {
        let fm = FileManager.default
        let src = vault.binDirURL.appendingPathComponent(relPath)
        let dst = vault.absoluteURL(forRelativePath: relPath)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        let sidecarSrc = vault.sidecarURL(forMediaAt: src)
        if fm.fileExists(atPath: sidecarSrc.path) {
            let sidecarDst = vault.sidecarURL(forMediaAt: dst)
            try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: sidecarSrc, to: sidecarDst)
        }
        try writeLog(try list().filter { $0.path != relPath })
    }

    public func list() throws -> [BinItem] {
        guard FileManager.default.fileExists(atPath: vault.binLogURL.path) else { return [] }
        let data = try Data(contentsOf: vault.binLogURL)
        let dec = JSONDecoder()
        return try data.split(separator: 0x0A).filter { !$0.isEmpty }
            .map { try dec.decode(BinItem.self, from: $0) }
    }

    public func binnedFileURL(relPath: String) -> URL {
        vault.binDirURL.appendingPathComponent(relPath)
    }

    private func writeLog(_ items: [BinItem]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for i in items { out.append(try enc.encode(i)); out.append(0x0A) }
        try AtomicFile.write(out, to: vault.binLogURL)
    }
}
