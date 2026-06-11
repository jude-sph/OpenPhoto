import Foundation
import Vision
import CoreGraphics
import ImageIO

public struct DetectedFace: Sendable {
    public let rect: CGRect      // Vision normalized boundingBox (bottom-left origin, 0…1)
    public let embedding: [Float]
    public let confidence: Float
}

/// On-device human-face detection + per-face embedding (Apple Vision). Headless + synchronous;
/// callers run it off the main actor. Human faces only (no pets).
public enum FaceStage {
    public static let id = "faces"

    /// Detect faces; per face crop the bounding box and run VNGenerateImageFeaturePrint on the crop.
    /// Returns one DetectedFace per face ([] for a photo with no faces); nil only if the SOURCE image
    /// can't be decoded (so the runner records a failure, retry-capped).
    public static func detect(in url: URL) -> [DetectedFace]? {
        // Decode the source image once; we need a CGImage for pixel-space cropping.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        // Run face detection on the full image.
        let detReq = VNDetectFaceRectanglesRequest()
        let detHandler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try detHandler.perform([detReq]) } catch { return nil }

        let observations = detReq.results ?? []
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        var out: [DetectedFace] = []

        for obs in observations {
            // Vision boundingBox is normalized, bottom-left origin.
            // Convert to pixel-space crop region (top-left origin for CGImage).
            let bb = obs.boundingBox
            let padX = bb.width  * w * 0.1
            let padY = bb.height * h * 0.1
            let cropPixel = CGRect(
                x: bb.minX * w - padX,
                y: (1.0 - bb.maxY) * h - padY,
                width: bb.width  * w + padX * 2,
                height: bb.height * h + padY * 2
            ).intersection(CGRect(x: 0, y: 0, width: w, height: h))

            guard let crop = cg.cropping(to: cropPixel) else { continue }
            guard let vec = featurePrint(of: crop) else { continue }
            out.append(DetectedFace(rect: bb, embedding: vec, confidence: obs.confidence))
        }
        return out
    }

    /// Run VNGenerateImageFeaturePrint on a CGImage crop and return the Float32 vector.
    private static func featurePrint(of cg: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first as? VNFeaturePrintObservation else { return nil }

        // VNFeaturePrintObservation.elementType is .float (Float32); elementCount gives the dim.
        let count = obs.elementCount
        guard count > 0 else { return nil }
        var vec = [Float](repeating: 0, count: count)
        obs.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<min(count, floats.count) { vec[i] = floats[i] }
        }
        return vec
    }
}

/// DerivationStage conformance — the runner calls this off-main inside Task.detached(.utility).
public struct FaceDerivationStage: DerivationStage {
    public let id = "faces"
    public let eligibleKind = "photo"
    public init() {}
    // isAvailable defaults to true — Vision is built-in (no model file to check).
    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        guard let faces = FaceStage.detect(in: url) else { return false }  // unreadable → failure
        try? catalog.replaceFaces(forHash: hash, with: faces.map {
            FaceRow(id: nil, hash: hash, rect: $0.rect, embedding: $0.embedding,
                    confidence: $0.confidence, source: "auto", personID: nil)
        })
        return true  // [] is still success — "analyzed, no faces"
    }
}
