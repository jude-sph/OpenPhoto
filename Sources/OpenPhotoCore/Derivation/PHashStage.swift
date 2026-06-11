import Foundation

/// Background derivation: a perceptual hash (dHash) per photo for near-duplicate detection.
/// Needs the image bytes (`needsFile == true`); always available (no model). Mirrors the file-backed stages (OCRDerivationStage / EmbedStage): returns false only on decode failure.
public final class PHashStage: @unchecked Sendable {
    public let id = "phash"
    public let eligibleKind = "photo"
    public init() {}
}

extension PHashStage: DerivationStage {
    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        guard let value = PerceptualHash.compute(imageAt: url) else { return false }
        try? catalog.upsertPHash(hash: hash, value: value)
        return true
    }
}
