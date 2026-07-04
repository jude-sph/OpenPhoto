import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// A solid-colour JPEG of an EXACT size (no EXIF orientation) so rotation is observable via dimensions.
private func writeJPEG(_ url: URL, width: Int, height: Int) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

// Decodes at FULL native resolution (no downscale), and folds a display rotation into the pixels.
@Test func fullResDecodeKeepsNativeSizeAndAppliesRotation() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("x.jpg")
    try writeJPEG(url, width: 6, height: 4)

    let cg = try #require(FullResImage.decode(url: url))
    #expect(cg.width == 6 && cg.height == 4)          // full native resolution, not downscaled

    let r90 = try #require(FullResImage.decode(url: url, extraRotationCW: 90))
    #expect(r90.width == 4 && r90.height == 6)          // 90° CW swaps dimensions

    let r180 = try #require(FullResImage.decode(url: url, extraRotationCW: 180))
    #expect(r180.width == 6 && r180.height == 4)        // 180° preserves dimensions
}

@Test func fullResDecodeReturnsNilForUnreadableFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    #expect(FullResImage.decode(url: t.root.appendingPathComponent("does-not-exist.jpg")) == nil)
}
