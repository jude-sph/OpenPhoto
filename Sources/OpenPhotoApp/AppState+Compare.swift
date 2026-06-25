import SwiftUI
import OpenPhotoCore

extension AppState {
    /// One text term compared against the whole image corpus: its cosine score vs every image
    /// embedding, plus a palette slot for the chart overlay.
    struct CompareTerm: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let colorIndex: Int          // 0..4 → palette slot
        let scores: [Float]          // cosine of this term vs every image embedding
        var mean: Float { scores.isEmpty ? 0 : scores.reduce(0, +) / Float(scores.count) }
        var std: Float {
            guard scores.count > 1 else { return 0 }
            let m = mean
            return (scores.reduce(Float(0)) { $0 + ($1 - m) * ($1 - m) } / Float(scores.count)).squareRoot()
        }
        /// Photos more than 3σ above this term's own average — its standout matches (a baseline-free
        /// "how represented is this concept" count, shown in the legend).
        var strongCount: Int {
            let t = mean + 3 * std
            return scores.lazy.filter { $0 > t }.count
        }
    }

    func toggleCompareMode() { compareMode.toggle() }

    /// Embed `raw` and score it against every catalogued image, then append a `CompareTerm`.
    /// The `SemanticIndex` is built once (off-main) and reused for subsequent terms. No-ops on a
    /// blank/duplicate term, when already at 5 terms, or with no library.
    func addCompareTerm(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, compareTerms.count < 5,
              !compareTerms.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }),
              let lib = library else { return }
        let used = Set(compareTerms.map(\.colorIndex))
        let colorIndex = (0..<5).first { !used.contains($0) } ?? (compareTerms.count % 5)
        let model = EmbedStage().modelID
        compareComputing = true
        Task {
            // Build the index once (off-main), then score this term off-main.
            if compareIndex == nil {
                compareIndex = await Task.detached(priority: .userInitiated) {
                    try? SemanticIndex(catalog: lib.catalog, model: model)
                }.value
            }
            let idx = compareIndex
            let scores: [Float] = await Task.detached(priority: .userInitiated) {
                guard let idx, let q = EmbedStage().embedText(text) else { return [] }
                return idx.allScores(q)
            }.value
            compareComputing = false
            guard !scores.isEmpty else { return }
            compareTerms.append(CompareTerm(text: text, colorIndex: colorIndex, scores: scores))
        }
    }

    func removeCompareTerm(_ id: UUID) { compareTerms.removeAll { $0.id == id } }
}
