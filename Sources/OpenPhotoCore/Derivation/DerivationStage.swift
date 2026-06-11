import Foundation

/// One background-derivable signal for an asset. Each stage owns a `derivation_jobs.stage` string
/// and resumes independently. `run` computes AND stores its output, returning success.
public protocol DerivationStage: Sendable {
    var id: String { get }            // "ocr", "embed"
    var eligibleKind: String { get }  // "photo" for both v1 stages
    /// Whether the stage's backing resources (e.g. model files) are present on this machine.
    /// A stage that returns `false` is skipped entirely — its jobs stay pending and resume once
    /// the resources become available. Defaults to `true` so existing stages need not implement it.
    var isAvailable: Bool { get }
    /// Whether the stage needs a reachable image file to run. Defaults to `true`.
    /// Stages that key off catalog data (e.g. GeocodeStage reads stored lat/lon) set this to
    /// `false` so a drive-only asset with its drive unplugged is still processed.
    var needsFile: Bool { get }
    func run(hash: String, url: URL, catalog: Catalog) async -> Bool
}

public extension DerivationStage {
    var isAvailable: Bool { true }
    var needsFile: Bool { true }
}
