import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

@Test func similarityRecoversAKnownScaleRotateTranslate() {
    // Ground-truth: scale 1.7, rotate 25°, translate (12, -8).
    let s: CGFloat = 1.7, theta = 25.0 * .pi / 180
    let a = s * cos(theta), b = s * sin(theta)
    let tx: CGFloat = 12, ty: CGFloat = -8
    let truth = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)

    let src = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
               CGPoint(x: 0, y: 7), CGPoint(x: -4, y: 3)]   // non-collinear
    let dst = src.map { $0.applying(truth) }

    let solved = SimilarityTransform.solve(src: src, dst: dst)
    #expect(abs(solved.a - a) < 1e-6)
    #expect(abs(solved.b - b) < 1e-6)
    #expect(abs(solved.tx - tx) < 1e-6)
    #expect(abs(solved.ty - ty) < 1e-6)
    // And it maps src→dst within tight tolerance.
    for i in src.indices {
        let p = src[i].applying(solved)
        #expect(hypot(p.x - dst[i].x, p.y - dst[i].y) < 1e-5)
    }
}

@Test func similarityIsLeastSquaresWithNoiseAndStaysAShapePreservingMap() {
    // Overdetermined with a perturbed point — solution should be a clean similarity (|col1|==|col2|,
    // columns orthogonal), not a shear that overfits the noise.
    let truth = CGAffineTransform(a: 1.0, b: 0.5, c: -0.5, d: 1.0, tx: 3, ty: 4)
    var dst = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 5)]
        .map { $0.applying(truth) }
    let src = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 5)]
    dst[0].x += 0.3; dst[2].y -= 0.2                      // inject noise

    let t = SimilarityTransform.solve(src: src, dst: dst)
    #expect(abs(t.a - t.d) < 1e-9)                        // equal diagonal → uniform scale + rotation
    #expect(abs(t.b - (-t.c)) < 1e-9)                     // anti-symmetric off-diagonal → no shear
}

@Test func similarityWithCoincidentSourceIsPureTranslation() {
    let src = [CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 2)]
    let dst = [CGPoint(x: 9, y: 5), CGPoint(x: 9, y: 5)]
    let t = SimilarityTransform.solve(src: src, dst: dst)
    let p = CGPoint(x: 2, y: 2).applying(t)
    #expect(hypot(p.x - 9, p.y - 5) < 1e-9)
}
