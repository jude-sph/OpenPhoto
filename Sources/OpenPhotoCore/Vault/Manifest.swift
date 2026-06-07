import Foundation

/// One line of manifest.jsonl — vault-format-v1 §4. Keys are the format.
public struct ManifestEntry: Codable, Equatable, Sendable {
    public let hash: ContentHash
    public let path: String   // vault-root-relative, "/", NFC
    public let size: Int64
    public let mtime: String  // ISO-8601 UTC, milliseconds

    public init(hash: ContentHash, path: String, size: Int64, mtime: String) {
        self.hash = hash
        self.path = path
        self.size = size
        self.mtime = mtime
    }

    enum CodingKeys: String, CodingKey { case hash, path, size, mtime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = ContentHash(stringValue: try c.decode(String.self, forKey: .hash))
        path = try c.decode(String.self, forKey: .path)
        size = try c.decode(Int64.self, forKey: .size)
        mtime = try c.decode(String.self, forKey: .mtime)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hash.stringValue, forKey: .hash)
        try c.encode(path, forKey: .path)
        try c.encode(size, forKey: .size)
        try c.encode(mtime, forKey: .mtime)
    }
}

public enum Manifest {
    /// Atomic full rewrite (format §4).
    public static func write(_ entries: [ManifestEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        // Sorted by path for stable diffs.
        for e in entries.sorted(by: { $0.path < $1.path }) {
            out.append(try encoder.encode(e))
            out.append(0x0A)
        }
        try AtomicFile.write(out, to: url)
    }

    public static func read(from url: URL) throws -> [ManifestEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A)
            .filter { !$0.isEmpty }
            .map { try decoder.decode(ManifestEntry.self, from: $0) }
    }
}
