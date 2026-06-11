import Foundation
import CoreML
import CoreGraphics
import ImageIO

/// On-device MobileCLIP-S2 image + text embeddings (Core ML).
///
/// Produces L2-normalized 512-d vectors in a shared image/text space, so cosine similarity is a
/// plain dot product. Both the image and text encoders are loaded **lazily** the first time they're
/// needed and compiled on demand (`MLModel.compileModel`) with `computeUnits = .all`.
///
/// Graceful degradation is a hard requirement: if a model `.mlpackage` is absent (e.g. a fresh
/// checkout without the gitignored `.models/`), or fails to load, the embed methods return `nil`
/// rather than crashing. Semantic search simply stays unpopulated. This keeps the build free of any
/// SwiftPM resource dependency on the model.
public final class EmbedStage: @unchecked Sendable {
    public let modelID = "mobileclip_s2"
    /// Embedding dimensionality (MobileCLIP-S2 `final_emb_1` is [1, 512]).
    public let dim = 512

    // Exact feature names + geometry discovered from the model descriptions:
    //   image encoder: input "image" (Image, 256x256, 32BGRA) → output "final_emb_1" [1,512] f32
    //   text  encoder: input "text"  (MLMultiArray [1,77] Int32) → output "final_emb_1" [1,512] f32
    private static let imageInputName = "image"
    private static let textInputName = "text"
    private static let outputName = "final_emb_1"
    private static let imageSide = 256

    private let modelDirectory: URL?
    private let lock = NSLock()

    // Lazy, memoized load state. The `loaded*` flags distinguish "not tried yet" from "tried and
    // failed" so we don't repeatedly attempt to compile a missing/broken model.
    private var imageModel: MLModel?
    private var triedImageLoad = false
    private var textModel: MLModel?
    private var triedTextLoad = false
    private var tokenizer: CLIPTokenizer?
    private var triedTokenizerLoad = false

    /// - Parameter modelDirectory: directory containing `mobileclip_s2_image.mlpackage`,
    ///   `mobileclip_s2_text.mlpackage`, and `bpe_simple_vocab_16e6.txt.gz`. When nil, defaults to
    ///   the running app bundle's resource directory (where `make-app.sh` injects them).
    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory ?? Bundle.main.resourceURL
    }

    // MARK: - Public API

    /// Embed the image at `url` → L2-normalized `[Float]` of length `dim`, or nil on any failure
    /// (unreadable image, missing/broken model).
    public func embedImage(at url: URL) -> [Float]? {
        guard let model = loadImageModel() else { return nil }
        guard let pixelBuffer = Self.makePixelBuffer(from: url, side: Self.imageSide) else { return nil }
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: [Self.imageInputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
            let out = try model.prediction(from: input)
            return Self.normalizedVector(from: out)
        } catch {
            return nil
        }
    }

    /// Embed `text` → L2-normalized `[Float]` of length `dim`, or nil on any failure (missing
    /// tokenizer vocab or model).
    public func embedText(_ text: String) -> [Float]? {
        guard let model = loadTextModel(), let tok = loadTokenizer() else { return nil }
        let ids = tok.encode(text)
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)],
                                            dataType: .int32) else { return nil }
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        for (i, id) in ids.enumerated() { ptr[i] = id }
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: [Self.textInputName: MLFeatureValue(multiArray: array)])
            let out = try model.prediction(from: input)
            return Self.normalizedVector(from: out)
        } catch {
            return nil
        }
    }

    // MARK: - Lazy loading

    private func loadImageModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if !triedImageLoad {
            triedImageLoad = true
            imageModel = Self.compileAndLoad(modelDirectory?.appendingPathComponent("mobileclip_s2_image.mlpackage"))
        }
        return imageModel
    }

    private func loadTextModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if !triedTextLoad {
            triedTextLoad = true
            textModel = Self.compileAndLoad(modelDirectory?.appendingPathComponent("mobileclip_s2_text.mlpackage"))
        }
        return textModel
    }

    private func loadTokenizer() -> CLIPTokenizer? {
        lock.lock(); defer { lock.unlock() }
        if !triedTokenizerLoad {
            triedTokenizerLoad = true
            if let dir = modelDirectory {
                tokenizer = CLIPTokenizer(vocabDirectory: dir)
            }
        }
        return tokenizer
    }

    private static func compileAndLoad(_ url: URL?) -> MLModel? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let compiled = try MLModel.compileModel(at: url)
            return try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            return nil
        }
    }

    // MARK: - Output → normalized vector

    private static func normalizedVector(from provider: MLFeatureProvider) -> [Float]? {
        guard let value = provider.featureValue(for: outputName),
              let array = value.multiArrayValue else { return nil }
        let count = array.count
        guard count > 0 else { return nil }
        var vec = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0 ..< count { vec[i] = p[i] }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0 ..< count { vec[i] = Float(p[i]) }
        case .float16:
            // Read via NSNumber to avoid depending on a Float16 ABI.
            for i in 0 ..< count { vec[i] = array[i].floatValue }
        default:
            for i in 0 ..< count { vec[i] = array[i].floatValue }
        }
        var norm: Float = 0
        for v in vec { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        for i in 0 ..< count { vec[i] /= norm }
        return vec
    }

    // MARK: - Image → CVPixelBuffer (32BGRA, side×side)

    /// Decode the image at `url` and render it into a `side×side` 32BGRA pixel buffer (aspect fill /
    /// center crop, matching CLIP's resize+center-crop preprocessing). Returns nil if the image
    /// can't be decoded.
    static func makePixelBuffer(from url: URL, side: Int) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return makePixelBuffer(from: cg, side: side)
    }

    static func makePixelBuffer(from cg: CGImage, side: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // 32BGRA byte order with premultipliedFirst alpha.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }

        // Aspect-fill: scale so the shorter side covers `side`, center the longer side (center crop).
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = max(CGFloat(side) / w, CGFloat(side) / h)
        let dw = w * scale, dh = h * scale
        let rect = CGRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
        return buffer
    }
}

// MARK: - DerivationStage conformance
// Image side feeds the background pipeline; text side (embedText) is query-time only.
// `EmbedStage` is `@unchecked Sendable`; `hash`/`url` are value types; `catalog` is Sendable.
// The runner calls this inside `Task.detached(.utility)`, keeping inference off the main actor.
extension EmbedStage: DerivationStage {
    public var id: String { "embed" }
    public var eligibleKind: String { "photo" }
    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        guard let v = embedImage(at: url) else { return false }
        try? catalog.upsertEmbedding(hash: hash, model: modelID, dim: dim, vector: v)
        return true
    }
}
