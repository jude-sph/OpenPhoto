import Foundation
import Vision
import CoreImage
import CoreVideo
import CoreGraphics

/// Warps a detected face onto the canonical 5-point template AdaFace/ArcFace expect, producing an
/// aligned 112×112 BGRA buffer ready for `FaceEmbedder`. Without this step the model receives an
/// unaligned, tilted crop and its discrimination collapses — alignment is what makes the model deliver.
///
/// Coordinate spaces: Vision's `pointsInImage` and `CIImage(cgImage:)` both use a lower-left origin
/// with the image upright, so source landmarks need no flip. Only the template (defined top-left) is
/// flipped into CI space; `CIContext.render` flips back, so the output buffer is a normal top-left image.
public enum FaceAligner {
    public static let outputSize = 112

    /// Canonical ArcFace/AdaFace template (top-left origin, 112×112), ordered by IMAGE position:
    /// left-eye, right-eye, nose, left-mouth, right-mouth.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    // CIContext is documented thread-safe for rendering; the compiler can't see that.
    private nonisolated(unsafe) static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Aligned 112×112 BGRA buffer for `observation` in `cgImage`, or nil if the landmarks required
    /// for alignment are absent (caller keeps the detection for display but won't cluster it).
    public static func alignedBuffer(cgImage: CGImage,
                                     observation: VNFaceObservation) -> CVPixelBuffer? {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        guard let lm = observation.landmarks,
              let src = sourcePoints(lm, imageSize: size) else { return nil }

        let H = CGFloat(outputSize)
        let dstCI = template.map { CGPoint(x: $0.x, y: H - $0.y) }   // top-left template → CI space
        let t = SimilarityTransform.solve(src: src, dst: dstCI)

        let ci = CIImage(cgImage: cgImage).transformed(by: t)
        guard let buffer = makeBuffer(outputSize, outputSize) else { return nil }
        ciContext.render(ci, to: buffer,
                         bounds: CGRect(x: 0, y: 0, width: H, height: H),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    /// 5 source landmarks in image pixels, assigned by image position (not anatomical label) so the
    /// subject-left/right naming convention can never horizontally flip the warp.
    private static func sourcePoints(_ lm: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let le = lm.leftEye, let re = lm.rightEye, let nose = lm.nose, let lips = lm.outerLips
        else { return nil }
        let e1 = centroid(le, imageSize), e2 = centroid(re, imageSize)
        let leftEye  = e1.x <= e2.x ? e1 : e2
        let rightEye = e1.x <= e2.x ? e2 : e1
        let lipPts = lips.pointsInImage(imageSize: imageSize)
        guard let mouthLeft = lipPts.min(by: { $0.x < $1.x }),
              let mouthRight = lipPts.max(by: { $0.x < $1.x }) else { return nil }
        return [leftEye, rightEye, centroid(nose, imageSize), mouthLeft, mouthRight]
    }

    private static func centroid(_ region: VNFaceLandmarkRegion2D, _ size: CGSize) -> CGPoint {
        let pts = region.pointsInImage(imageSize: size)
        guard !pts.isEmpty else { return .zero }
        var s = CGPoint.zero
        for p in pts { s.x += p.x; s.y += p.y }
        return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
    }

    private static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb)
        return pb
    }
}
