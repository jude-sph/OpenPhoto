import Foundation
import Accelerate

/// In-memory brute-force cosine index over the current model's embeddings.
/// Vectors are L2-normalized at write time, so cosine == dot product.
public final class SemanticIndex: @unchecked Sendable {
    private let hashes: [String]
    private let matrix: [Float]      // count × dim, row-major, fp32
    public let dim: Int

    public init(catalog: Catalog, model: String) throws {
        let rows = try catalog.allEmbeddings(model: model)
        let dim = rows.first?.dim ?? 0
        // Filter once so both `hashes` and `matrix` are built from the same usable rows.
        // Rows whose stored dim differs from the leading dim are silently dropped — they came
        // from a model version mismatch and would cause vDSP_mmul to read out-of-bounds.
        let usable = rows.filter { $0.dim == dim }
        self.dim = dim
        self.hashes = usable.map(\.hash)
        var m = [Float](); m.reserveCapacity(usable.count * dim)
        for r in usable { m.append(contentsOf: r.vector) }
        self.matrix = m
    }

    public var count: Int { hashes.count }

    /// Top-N by descending cosine. No hard threshold (CLIP cosine magnitudes are unreliable).
    public func query(_ q: [Float], topN: Int) -> [(hash: String, score: Float)] {
        guard dim > 0, q.count == dim, !hashes.isEmpty else { return [] }
        let count = hashes.count
        var scores = [Float](repeating: 0, count: count)
        // scores = matrix (count×dim) · q (dim×1) → (count×1).
        // vDSP_mmul: A(M×N) · B(N×P) → C(M×P). Here M=count, N=dim, P=1.
        vDSP_mmul(matrix, 1, q, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(dim))
        let n = min(topN, count)
        let top = scores.enumerated().sorted { $0.element > $1.element }.prefix(n)
        return top.map { (hashes[$0.offset], $0.element) }
    }
}
