import Foundation

/// Durable memory of every item ever imported from each device —
/// imports.jsonl in the vault's .openphoto/ (vault-format-v1 §12).
public final class ImportRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let sourceKey: String
        public let name: String
        public let size: Int64
        public let takenAt: String      // ISO-8601 millis; "" when source had none
        public let hash: String
        public let importedAt: String
        public let importedTo: String
        enum CodingKeys: String, CodingKey {
            case sourceKey = "source_key", name, size
            case takenAt = "taken_at", hash
            case importedAt = "imported_at", importedTo = "imported_to"
        }
        public init(sourceKey: String, name: String, size: Int64, takenAt: String,
                    hash: String, importedAt: String, importedTo: String) {
            self.sourceKey = sourceKey; self.name = name; self.size = size
            self.takenAt = takenAt; self.hash = hash
            self.importedAt = importedAt; self.importedTo = importedTo
        }
        var key: String { "\(sourceKey)|\(name)|\(size)|\(takenAt)" }
    }

    private let url: URL
    private var byKey: [String: Entry] = [:]
    private var byHash: [String: Set<String>] = [:]   // hash → source_keys that recorded it
    private let lock = NSLock()

    public init(vault: Vault) {
        url = vault.stateDirURL.appendingPathComponent("imports.jsonl")
        try? load()
    }

    /// (Re)load from disk. Missing file = empty registry.
    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        byKey.removeAll()
        byHash.removeAll()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain
            && e.code == NSFileReadNoSuchFileError { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let e = try dec.decode(Entry.self, from: line)
            byKey[e.key] = e
            byHash[e.hash, default: []].insert(e.sourceKey)
        }
    }

    public func contains(sourceKey: String, name: String, size: Int64, takenAt: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byKey["\(sourceKey)|\(name)|\(size)|\(takenAt)"] != nil
    }

    public func entries(forSourceKey key: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.sourceKey == key }
    }

    /// All import entries that recorded these exact bytes (any device).
    public func entries(forHash hash: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.hash == hash }
    }

    /// Device source-keys that have imported these exact bytes (any folder).
    public func deviceKeys(forHash hash: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return byHash[hash] ?? []
    }

    /// Append (idempotent by key) and rewrite atomically.
    public func append(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        guard byKey[entry.key] == nil else { return }
        byKey[entry.key] = entry
        byHash[entry.hash, default: []].insert(entry.sourceKey)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in byKey.values.sorted(by: { $0.importedAt < $1.importedAt }) {
            out.append(try enc.encode(e)); out.append(0x0A)
        }
        try AtomicFile.write(out, to: url)
    }
}
