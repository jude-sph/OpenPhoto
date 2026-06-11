import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// Render a `size`×`size` checkerboard JPEG (rich horizontal+vertical structure → a non-degenerate
/// dHash). `invert` swaps the squares; `quality` controls JPEG compression. Shared with PHashStageTests.
func writeCheckerJPEG(at url: URL, cell: Int = 8, invert: Bool = false,
                      quality: Double = 0.9, size: Int = 64) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cells = size / cell
    for cy in 0..<cells {
        for cx in 0..<cells {
            var on = (cx + cy) % 2 == 0
            if invert { on.toggle() }
            ctx.setFillColor(CGColor(gray: on ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: cx * cell, y: cy * cell, width: cell, height: cell))
        }
    }
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

@Test func dHashNearForReencodeFarForDifferent() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let a = t.root.appendingPathComponent("a.jpg")
    let a2 = t.root.appendingPathComponent("a2.jpg")   // same image, heavier compression
    let b = t.root.appendingPathComponent("b.jpg")     // inverted checkerboard (different image)
    try writeCheckerJPEG(at: a, quality: 0.95)
    try writeCheckerJPEG(at: a2, quality: 0.6)
    try writeCheckerJPEG(at: b, invert: true, quality: 0.95)
    let ha = PerceptualHash.compute(imageAt: a)!
    let ha2 = PerceptualHash.compute(imageAt: a2)!
    let hb = PerceptualHash.compute(imageAt: b)!
    let near = PerceptualHash.hamming(ha, ha2)
    let far = PerceptualHash.hamming(ha, hb)
    #expect(near <= 8)        // a re-encode of the same image stays close
    #expect(near < far)       // a different image is reliably farther
}

@Test func hammingCountsDifferingBits() {
    #expect(PerceptualHash.hamming(0, 0) == 0)
    #expect(PerceptualHash.hamming(0, 0b1011) == 3)
    #expect(PerceptualHash.hamming(Int64(bitPattern: ~0), 0) == 64)
}

@Test func computeReturnsNilForNonImage() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let bad = t.root.appendingPathComponent("bad.jpg")
    try Data("not an image".utf8).write(to: bad)
    #expect(PerceptualHash.compute(imageAt: bad) == nil)
}

@Test func sharpImageScoresHigherThanFlat() {
    func checker(_ flat: Bool) -> CGImage {
        let s = 64
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if flat {
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        } else {
            for cy in 0..<8 { for cx in 0..<8 {
                ctx.setFillColor(CGColor(gray: (cx + cy) % 2 == 0 ? 1 : 0, alpha: 1))
                ctx.fill(CGRect(x: cx * 8, y: cy * 8, width: 8, height: 8))
            } }
        }
        return ctx.makeImage()!
    }
    #expect(FocusMeasure.varianceOfLaplacian(checker(false)) > FocusMeasure.varianceOfLaplacian(checker(true)))
}
