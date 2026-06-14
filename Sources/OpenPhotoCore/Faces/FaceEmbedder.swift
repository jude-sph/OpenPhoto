import Foundation
import CoreML
import CoreVideo

/// Loads the bundled AdaFace IR-101 Core ML model and turns an aligned 112×112 face crop into a
/// 512-d, L2-normalized identity embedding (cosine-comparable). This is the v2 replacement for the
/// generic `VNGenerateImageFeaturePrint` vectors, which encoded image appearance rather than identity.
///
/// The model package ships as a target resource and is compiled to `.mlmodelc` on first use, then
/// cached in the user Caches dir keyed by `modelVersion` so subsequent launches skip compilation.
/// `prediction` is thread-safe once the model is loaded; only the lazy load is locked.
/// The compiled model is loaded via `MLLoader`, which falls back `.all` → `.cpuAndGPU` → `.cpuOnly` so Intel Macs without a Neural Engine still load it.
public final class FaceEmbedder: @unchecked Sendable {
    public static let shared = FaceEmbedder()

    /// Identifier of the current embedding model. Bump when the model (or its preprocessing) changes
    /// so the compiled cache and the catalog's `faceModelVersion` both invalidate. See the rescan flow.
    public static let modelVersion = "adaface-ir101-v1"
    public static let dimension = 512

    public enum Error: Swift.Error { case resourceMissing, badOutput }

    private let lock = NSLock()
    private var model: MLModel?
    private var triedLoad = false

    private init() {}

    /// Embed one aligned 112×112 face. Returns a 512-d vector, or nil if the model is unavailable
    /// or inference fails (callers treat nil as "couldn't embed this face").
    public func embed(_ pixelBuffer: CVPixelBuffer) -> [Float]? {
        guard let model = loadedModel() else { return nil }
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
            let out = try model.prediction(from: input)
            guard let arr = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            // Read dtype-agnostically (the mlprogram output is Float16); 512 elements, negligible cost.
            var vec = [Float](repeating: 0, count: arr.count)
            for i in 0..<arr.count { vec[i] = arr[i].floatValue }
            return vec
        } catch {
            return nil
        }
    }

    /// True when the model loads on this machine (Core ML available + resource present). Lets the
    /// derivation stage skip cleanly rather than mark every photo failed if something is wrong.
    public var isAvailable: Bool { loadedModel() != nil }

    // MARK: - Lazy load + compile cache

    private func loadedModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if triedLoad { return model }
        triedLoad = true
        do {
            let url = try compiledModelURL()
            let m = try MLLoader.load(compiledModelAt: url)
            model = m
            MLAvailability.shared.report(model: MLModelKey.adaface, .available)
            return m
        } catch Error.resourceMissing {
            MLAvailability.shared.report(model: MLModelKey.adaface, .absent)
            return nil
        } catch {
            MLAvailability.shared.report(model: MLModelKey.adaface, .unavailable(error.localizedDescription))
            return nil
        }
    }

    private func compiledModelURL() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("OpenPhoto/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("AdaFaceIR101-\(Self.modelVersion).mlmodelc",
                                              isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        guard let src = Bundle.module.url(forResource: "AdaFaceIR101", withExtension: "mlpackage") else {
            throw Error.resourceMissing
        }
        let compiled = try MLModel.compileModel(at: src)     // → a temporary .mlmodelc
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: compiled, to: dest)
        return dest
    }
}
