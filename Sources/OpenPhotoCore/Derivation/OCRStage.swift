import Foundation
import Vision

/// On-device text recognition (Vision). Headless + synchronous; callers run it off the main actor.
public enum OCRStage {
    public static let id = "ocr"

    /// Recognize text in the image at `url`. Returns the recognized text (possibly empty for an
    /// image with no text), or `nil` if the image can't be read / Vision throws.
    public static func recognizeText(in url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// `DerivationStage` conformance for OCR — wraps the existing `OCRStage` static func.
public struct OCRDerivationStage: DerivationStage {
    public let id = "ocr"
    public let eligibleKind = "photo"
    public init() {}
    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        guard let text = OCRStage.recognizeText(in: url) else { return false }
        try? catalog.upsertOCR(hash: hash, text: text)
        return true
    }
}
