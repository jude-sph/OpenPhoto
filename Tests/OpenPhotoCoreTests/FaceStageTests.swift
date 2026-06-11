import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OpenPhotoCore

private func writeSolidJPEG(_ rgb: (CGFloat, CGFloat, CGFloat), to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    ctx.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

@Test func faceStageRunsAndReturnsFiniteArray() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("solid.jpg")
    try writeSolidJPEG((0.5, 0.4, 0.3), to: url)
    let faces = FaceStage.detect(in: url)   // non-nil (image decodes); 0+ faces
    let list = try #require(faces)
    for f in list {                          // if Vision returns anything, it's well-formed
        #expect(!f.embedding.isEmpty)
        #expect(f.confidence >= 0 && f.confidence <= 1)
    }
}

@Test func faceStageNilOnUnreadableImage() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("not-an-image.jpg")
    try Data([0x00, 0x01, 0x02]).write(to: url)
    #expect(FaceStage.detect(in: url) == nil)   // unreadable → nil → runner marks a failure
}
