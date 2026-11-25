import Testing
import Foundation
import CoreGraphics
import ImageIO
import CoreVideo
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// Write a generated `width`×`height` (raw pixel grid) image carrying the given EXIF orientation.
/// The left half is red and the right half blue so orientation is observable, not just dimensions.
private func writeOrientedImage(to url: URL, type: UTType, width: Int, height: Int,
                                orientation: Int) throws {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image,
                               [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

/// RGB of pixel (x, y), top-left origin, after rendering `image` into a known RGBA8 layout.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    var buf = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Shift so the wanted pixel lands on the 1×1 canvas (CG's origin is bottom-left).
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (buf[0], buf[1], buf[2])
}

private func storedOrientation(_ url: URL) -> Int? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    return props[kCGImagePropertyOrientation] as? Int
}

private func rawDecode(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

private func uprightThumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ] as CFDictionary)
}

// MARK: - CLIP decode (EmbedStage)

/// A JPEG stored rotated (EXIF orientation 6 = "rotate 90° CW to display") must reach the encoder
/// upright: dimensions swapped relative to the raw pixel grid.
@Test func embedDecodeAppliesEXIFOrientation() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("rot6.jpg")
    try writeOrientedImage(to: url, type: .jpeg, width: 400, height: 200, orientation: 6)
    #expect(storedOrientation(url) == 6)

    let raw = try #require(rawDecode(url))
    #expect(raw.width == 400 && raw.height == 200)             // raw grid ignores the tag

    let decoded = try #require(EmbedStage.decodeForEmbedding(url))
    #expect(decoded.width == 200 && decoded.height == 400)     // upright, not upscaled
    // Orientation 6 rotates the raw grid 90° CW for display: the raw LEFT (red) half becomes the
    // TOP half, the raw right (blue) half the bottom.
    let top = pixel(decoded, x: 100, y: 50), bottom = pixel(decoded, x: 100, y: 350)
    #expect(top.r > 200 && top.b < 60, "top should be red, got \(top)")
    #expect(bottom.b > 200 && bottom.r < 60, "bottom should be blue, got \(bottom)")
    // The raw decode, for contrast, is red on the left.
    let rawLeft = pixel(raw, x: 50, y: 100)
    #expect(rawLeft.r > 200 && rawLeft.b < 60)

    // And the pixel-buffer path still yields a side×side buffer from it.
    let pb = try #require(EmbedStage.makePixelBuffer(from: url, side: 224))
    #expect(CVPixelBufferGetWidth(pb) == 224 && CVPixelBufferGetHeight(pb) == 224)
}

@Test func embedDecodeDownsamplesLargeImagesAtTheSource() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("big.jpg")
    try writeOrientedImage(to: url, type: .jpeg, width: 3000, height: 2000, orientation: 1)
    let decoded = try #require(EmbedStage.decodeForEmbedding(url))
    #expect(max(decoded.width, decoded.height) == EmbedStage.decodeMaxPixel)
    #expect(min(decoded.width, decoded.height) >= 224)
    // Aspect preserved (3:2) so the centre crop frames the same region as a full decode.
    #expect(abs(Double(decoded.width) / Double(decoded.height) - 1.5) < 0.01)
}
