import Foundation

/// Durable record of every asset OpenPhoto has CONFIRMED sending to a device —
/// sends.jsonl in the primary vault's .openphoto/ (vault-format-v1 §13).
public final class SendRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let hash: String
        public let destinationKey: String
        public let deviceName: String
        public let deviceKind: String
        public let sentAt: String
        public let confirmedAt: String
        public let fpSize: Int64
        public let fpCaptureDateMs: Int64
        enum CodingKeys: String, CodingKey {
            case hash, destinationKey = "destination_key", deviceName = "device_name"
            case deviceKind = "device_kind", sentAt = "sent_at", confirmedAt = "confirmed_at"
            case fpSize = "fp_size", fpCaptureDateMs = "fp_capture_date_ms"
        }
        public init(hash: String, destinationKey: String, deviceName: String, deviceKind: String,
                    sentAt: String, confirmedAt: String, fpSize: Int64, fpCaptureDateMs: Int64) {
            self.hash = hash; self.destinationKey = destinationKey; self.deviceName = deviceName
            self.deviceKind = deviceKind; self.sentAt = sentAt; self.confirmedAt = confirmedAt
            self.fpSize = fpSize; self.fpCaptureDateMs = fpCaptureDateMs
        }
        var key: String { "\(destinationKey)|\(hash)" }
    }

    private let url: URL
    private var byKey: [String: Entry] = [:]
    private let lock = NSLock()

    public init(vault: Vault) {
        url = vault.stateDirURL.appendingPathComponent("sends.jsonl")
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

    public func contains(destinationKey: String, hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byKey["\(destinationKey)|\(hash)"] != nil
    }

    public func entries(forDestinationKey key: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.destinationKey == key }
    }

    /// Has anything with this fingerprint been confirmed-sent to this device?
    /// Matches size + capture second (filenames aren't recorded — Photos rewrites
    /// them). An unknown (0) capture date never matches.
    public func wasSentToDevice(destinationKey: String, size: Int64, captureDateMs: Int64) -> Bool {
        guard captureDateMs != 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return byKey.values.contains { e in
            e.destinationKey == destinationKey && e.fpSize == size &&
            e.fpCaptureDateMs / 1000 == captureDateMs / 1000
        }
    }

    /// Append (idempotent by destination+hash) and rewrite atomically.
    public func append(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        guard byKey[entry.key] == nil else { return }
        byKey[entry.key] = entry
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in byKey.values.sorted(by: { $0.confirmedAt < $1.confirmedAt }) {
            out.append(try enc.encode(e)); out.append(0x0A)
        }
        try AtomicFile.write(out, to: url)
    }
}
