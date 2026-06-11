import Foundation

/// One background-derivable signal for an asset. Each stage owns a `derivation_jobs.stage` string
/// and resumes independently. `run` computes AND stores its output, returning success.
public protocol DerivationStage: Sendable {
    var id: String { get }            // "ocr", "embed"
    var eligibleKind: String { get }  // "photo" for both v1 stages
    func run(hash: String, url: URL, catalog: Catalog) async -> Bool
}
