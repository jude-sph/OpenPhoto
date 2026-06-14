import Foundation
import CoreML

/// Stable keys for the on-device CoreML models, used by the availability registry.
public enum MLModelKey {
    public static let adaface = "adaface_ir101"
    public static let mobileclipImage = "mobileclip_s2_image"
    public static let mobileclipText = "mobileclip_s2_text"
}

/// Per-model load outcome on *this* machine.
/// - `.absent` is a legitimate degraded mode (model package not installed) — NOT surfaced loudly.
/// - `.unavailable` means the model is present but failed to compile/load/run here — surfaced loudly.
public enum MLStatus: Sendable, Equatable {
    case unknown
    case available
    case absent
    case unavailable(String)
}

/// User-facing ML capabilities (a capability may require more than one model).
public enum MLCapability: String, CaseIterable, Sendable {
    case faceRecognition
    case semanticSearch
}

/// Thread-safe registry of per-model `MLStatus`. CoreML loads happen off the main actor, so this is
/// lock-guarded. Posts `MLAvailability.didChange` on any status transition (deduped) so the App can
/// react. A process-wide `.shared` instance is what the loaders report into; tests use fresh instances.
public final class MLAvailability: @unchecked Sendable {
    public static let shared = MLAvailability()
    public static let didChange = Notification.Name("OpenPhotoMLAvailabilityDidChange")

    private let lock = NSLock()
    private var byModel: [String: MLStatus] = [:]

    public init() {}

    /// Record `status` for `model`. Returns true (and posts `didChange`) only if it changed.
    @discardableResult
    public func report(model: String, _ status: MLStatus) -> Bool {
        let changed = lock.withLock {
            let c = byModel[model] != status
            byModel[model] = status
            return c
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return changed
    }

    public func status(model: String) -> MLStatus {
        lock.withLock { byModel[model] ?? .unknown }
    }

    public func snapshot() -> [String: MLStatus] {
        lock.withLock { byModel }
    }
}

/// Pure mapping from raw per-model statuses to a capability status.
/// Precedence: any required model `.unavailable` → `.unavailable` (loudest); else any `.absent` →
/// `.absent`; else any `.unknown` → `.unknown`; else `.available`.
public func mlCapabilityStatus(_ capability: MLCapability,
                               from byModel: [String: MLStatus]) -> MLStatus {
    let keys: [String]
    switch capability {
    case .faceRecognition: keys = [MLModelKey.adaface]
    case .semanticSearch:  keys = [MLModelKey.mobileclipImage, MLModelKey.mobileclipText]
    }
    let statuses = keys.map { byModel[$0] ?? .unknown }
    for s in statuses { if case .unavailable = s { return s } }
    if statuses.contains(.absent) { return .absent }
    if statuses.contains(.unknown) { return .unknown }
    return .available
}

/// Loads a *compiled* CoreML model, walking down the compute-units ladder so an Intel Mac (which has
/// no Neural Engine) still loads via GPU or, failing that, CPU. Throws the last error if all fail.
enum MLLoader {
    static func load(compiledModelAt url: URL) throws -> MLModel {
        let ladder: [MLComputeUnits] = [.all, .cpuAndGPU, .cpuOnly]
        var lastError: Error?
        for units in ladder {
            let config = MLModelConfiguration()
            config.computeUnits = units
            do { return try MLModel(contentsOf: url, configuration: config) }
            catch { lastError = error }
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }
}
