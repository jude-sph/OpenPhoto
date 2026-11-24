import Foundation

/// Vault bin — vault-format-v1 §8. Nothing in the system hard-deletes.
public struct BinStore: Sendable {
    public enum Origin: String, Codable, Sendable { case user, propagated, repaired }

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

    /// One file to bin in a batch (`moveToBin(_:)`).
    public struct BinMove: Sendable {
        public let relPath: String
        public let hash: ContentHash
        public let origin: Origin
        public let includeSidecar: Bool
        public init(relPath: String, hash: ContentHash, origin: Origin, includeSidecar: Bool = true) {
            self.relPath = relPath; self.hash = hash; self.origin = origin
            self.includeSidecar = includeSidecar
        }
    }

    let vault: Vault
    public init(vault: Vault) { self.vault = vault }

    public func moveToBin(relPath: String, hash: ContentHash, origin: Origin,
                          includeSidecar: Bool = true) throws {
        let failures = moveToBin([BinMove(relPath: relPath, hash: hash, origin: origin,
                                          includeSidecar: includeSidecar)])
        if let error = failures[0] { throw error }
    }

    /// Batch form: move every file (and its sidecar) into the bin FIRST, then append all of them to
    /// `bin.jsonl` in ONE atomic rewrite — k files cost one log write, not k. Per-file error
    /// attribution is kept: the result maps the index of each request that FAILED to its error
    /// (absent = binned and logged); a failed item never stops the rest. "Files first, log after":
    /// a crash between the two leaves the files recoverable in `bin/` (merely unlisted), exactly as
    /// the per-file form did. If the single log write itself fails, every item that moved is
    /// reported failed with that error (the same thing the per-file form threw).
    @discardableResult
    public func moveToBin(_ moves: [BinMove]) -> [Int: any Error] {
        guard !moves.isEmpty else { return [:] }
        var failures: [Int: any Error] = [:]
        var moved: [(index: Int, item: BinItem)] = []
        for (i, m) in moves.enumerated() {
            do {
                try moveFileToBin(relPath: m.relPath, includeSidecar: m.includeSidecar)
                moved.append((i, BinItem(hash: m.hash.stringValue, path: m.relPath,
                                         deletedAt: ISO8601Millis.string(from: Date()),
                                         origin: m.origin)))
            } catch { failures[i] = error }
        }
        guard !moved.isEmpty else { return failures }
        do {
            try writeLog(try list() + moved.map(\.item))
        } catch {
            for m in moved { failures[m.index] = error }
        }
        return failures
    }

    private func moveFileToBin(relPath: String, includeSidecar: Bool) throws {
        let fm = FileManager.default
        let src = vault.absoluteURL(forRelativePath: relPath)
        let dst = vault.binDirURL.appendingPathComponent(relPath)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        // Sidecar travels with the file, same folder-level convention inside bin/.
        let sidecar = vault.sidecarURL(forMediaAt: src)
        if includeSidecar, fm.fileExists(atPath: sidecar.path) {
            let sidecarDst = vault.sidecarURL(forMediaAt: dst)
            try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: sidecar, to: sidecarDst)
        }
    }

    public func restore(relPath: String) throws {
        if let error = restore(relPaths: [relPath])[0] { throw error }
    }

    /// Batch form of `restore`: move every file (and sidecar) back out of the bin, then drop all of
    /// them from `bin.jsonl` in ONE atomic rewrite. Returns index → error for each request that
    /// failed (absent = restored); a failed item never stops the rest. If the single log write
    /// fails, every restored item is reported failed with that error (the files are back in place;
    /// the stale log lines are harmless leftovers, as with the per-file form).
    @discardableResult
    public func restore(relPaths: [String]) -> [Int: any Error] {
        guard !relPaths.isEmpty else { return [:] }
        let fm = FileManager.default
        var failures: [Int: any Error] = [:]
        var restored: [Int] = []
        for (i, relPath) in relPaths.enumerated() {
            do {
                let src = vault.binDirURL.appendingPathComponent(relPath)
                let dst = vault.absoluteURL(forRelativePath: relPath)
                try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst)
                let sidecarSrc = vault.sidecarURL(forMediaAt: src)
                if fm.fileExists(atPath: sidecarSrc.path) {
                    let sidecarDst = vault.sidecarURL(forMediaAt: dst)
                    try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.moveItem(at: sidecarSrc, to: sidecarDst)
                }
                restored.append(i)
            } catch { failures[i] = error }
        }
        guard !restored.isEmpty else { return failures }
        do {
            let gone = Set(restored.map { relPaths[$0] })
            try writeLog(try list().filter { !gone.contains($0.path) })
        } catch {
            for i in restored { failures[i] = error }
        }
        return failures
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
