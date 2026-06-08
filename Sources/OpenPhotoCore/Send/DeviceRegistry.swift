import Foundation

/// Known devices OpenPhoto has seen — devices.jsonl in the primary vault's
/// .openphoto/ (vault-format-v1 §14). Friendly-name source for the UI.
public final class DeviceRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let key: String
        public var name: String
        public let kind: String
        public let firstSeen: String
        public var lastSeen: String
        enum CodingKeys: String, CodingKey {
            case key, name, kind
            case firstSeen = "first_seen", lastSeen = "last_seen"
        }
        public init(key: String, name: String, kind: String, firstSeen: String, lastSeen: String) {
            self.key = key; self.name = name; self.kind = kind
            self.firstSeen = firstSeen; self.lastSeen = lastSeen
        }
    }

    private let url: URL
    private var byKey: [String: Entry] = [:]
    private let lock = NSLock()

    public init(vault: Vault) {
        url = vault.stateDirURL.appendingPathComponent("devices.jsonl")
        try? load()
    }

    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        byKey.removeAll()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain
            && e.code == NSFileReadNoSuchFileError { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let e = try dec.decode(Entry.self, from: line)
            byKey[e.key] = e
        }
    }

    public func name(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]?.name
    }

    public func entry(forKey key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]
    }

    /// Record/refresh a device. Updates name + last_seen; preserves first_seen.
    public func upsert(key: String, name: String, kind: String, at: String) {
        lock.lock(); defer { lock.unlock() }
        if var e = byKey[key] {
            e.name = name; e.lastSeen = at; byKey[key] = e
        } else {
            byKey[key] = Entry(key: key, name: name, kind: kind, firstSeen: at, lastSeen: at)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in byKey.values.sorted(by: { $0.firstSeen < $1.firstSeen }) {
            if let d = try? enc.encode(e) { out.append(d); out.append(0x0A) }
        }
        try? AtomicFile.write(out, to: url)
    }
}
