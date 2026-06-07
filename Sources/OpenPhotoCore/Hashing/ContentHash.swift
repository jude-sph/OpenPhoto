import Foundation
import CryptoKit

/// Content-addressed identity: "sha256:" + 64 lowercase hex chars.
/// The algorithm prefix is part of the on-disk format (vault-format-v1 §2).
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let stringValue: String
    public var description: String { stringValue }

    public init(stringValue: String) { self.stringValue = stringValue }

    /// Streaming hash — constant memory regardless of file size.
    public static func ofFile(at url: URL) throws -> ContentHash {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            guard let data = try fh.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ContentHash(stringValue: "sha256:" + hex)
    }
}
