import Foundation
import Vision
import CoreGraphics
import ImageIO

public struct DetectedFace: Sendable {
    public let rect: CGRect      // Vision normalized boundingBox (bottom-left origin, 0…1)
    public let embedding: [Float] // 512-d AdaFace identity vector, or [] when not clusterable
    public let confidence: Float
    public let quality: Float    // capture quality if the face passed the gate, else 0 (not clusterable)
}

/// On-device human-face detection + per-face **identity** embedding (AdaFace IR-101 via Core ML).
/// Pipeline: detect + landmarks → quality gate (size, capture quality, pose) → align to the canonical
/// template → embed. Faces that fail the gate are still returned (for display + manual assignment) but
/// with an empty embedding and quality 0, so they never reach the clusterer. Headless + synchronous;
/// callers run it off the main actor. Human faces only (no pets).
public enum FaceStage {
    public static let id = "faces"

    // Quality gate — keep only faces good enough to embed reliably; junk faces otherwise bridge clusters.
    static let minFaceFraction: CGFloat = 0.025   // shorter side ≥ 2.5% of the image's shorter side …
    static let minFacePixels: CGFloat = 48        // … and ≥ 48 px, whichever is larger
    static let minCaptureQuality: Float = 0.3
    static let maxPoseRadians: Float = 0.7        // ~40° — exclude extreme yaw/roll

    /// Detect faces and embed the clusterable ones. Returns one DetectedFace per face ([] for a photo
    /// with no faces); nil only if the SOURCE image can't be decoded (runner records a retry-capped
    /// failure). Per-image and per-face work is wrapped in autorelease pools — bulk re-derivation over
    /// a whole library otherwise accumulates Vision/CoreImage buffers and has OOM'd before.
    public static func detect(in url: URL) -> [DetectedFace]? {
        autoreleasepool {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            let landmarksReq = VNDetectFaceLandmarksRequest()
            do { try handler.perform([landmarksReq]) } catch { return nil }
            let observations = landmarksReq.results ?? []
            guard !observations.isEmpty else { return [] }

            // Capture-quality pass. Pass the landmark observations in; results come back in the same
            // order, so map quality back by index (keeping the landmark-bearing originals for alignment).
            var captureQuality = [Float](repeating: 0, count: observations.count)
            let qualityReq = VNDetectFaceCaptureQualityRequest()
            qualityReq.inputFaceObservations = observations
            if (try? handler.perform([qualityReq])) != nil {
                for (i, r) in (qualityReq.results ?? []).enumerated() where i < captureQuality.count {
                    captureQuality[i] = r.faceCaptureQuality ?? 0
                }
            }

            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let minSidePx = max(minFacePixels, min(w, h) * minFaceFraction)
            var out: [DetectedFace] = []
            for (i, obs) in observations.enumerated() {
                autoreleasepool {
                    let bb = obs.boundingBox
                    let shorter = min(bb.width * w, bb.height * h)
                    let capQ = captureQuality[i]
                    let yaw = abs(obs.yaw?.floatValue ?? 0)
                    let roll = abs(obs.roll?.floatValue ?? 0)
                    let passes = shorter >= minSidePx && capQ >= minCaptureQuality
                              && yaw <= maxPoseRadians && roll <= maxPoseRadians

                    if passes,
                       let buffer = FaceAligner.alignedBuffer(cgImage: cg, observation: obs),
                       let vec = FaceEmbedder.shared.embed(buffer) {
                        out.append(DetectedFace(rect: bb, embedding: vec,
                                                confidence: obs.confidence, quality: capQ))
                    } else {
                        out.append(DetectedFace(rect: bb, embedding: [],
                                                confidence: obs.confidence, quality: 0))
                    }
                }
            }
            return out
        }
    }
}

/// DerivationStage conformance — the runner calls this off-main inside Task.detached(.utility).
public struct FaceDerivationStage: DerivationStage {
    public let id = "faces"
    public let eligibleKind = "photo"
    public init() {}
    /// Skip the whole stage if the embedding model can't load (leaves jobs pending rather than
    /// marking every photo failed).
    public var isAvailable: Bool { FaceEmbedder.shared.isAvailable }

    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        guard let faces = FaceStage.detect(in: url) else { return false }  // unreadable → failure
        try? catalog.replaceFaces(forHash: hash, with: faces.map {
            FaceRow(id: nil, hash: hash, rect: $0.rect, embedding: $0.embedding,
                    confidence: $0.confidence, source: "auto", personID: nil, quality: $0.quality)
        })
        return true  // [] is still success — "analyzed, no faces"
    }
}
