import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// Render `text` as black on white into a JPEG at `url` (headless — Core Graphics + Core Text,
/// no AppKit / window server).
private func writeTextJPEG(_ text: String, to url: URL) throws {
    let width = 700, height = 220
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
    let attrs = [kCTFontAttributeName: font,
                 kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFDictionary
    let attr = CFAttributedStringCreate(nil, text as CFString, attrs)!
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: 30, y: 80)
    CTLineDraw(line, ctx)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL,
                        UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

@Test func ocrRecognizesRenderedText() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("sign.jpg")
    try writeTextJPEG("OPENPHOTO", to: url)
    let text = OCRStage.recognizeText(in: url)
    #expect(text?.uppercased().contains("OPENPHOTO") == true)
}

@Test func ocrOnNonImageReturnsNil() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("notimage.jpg")
    try Data("not an image".utf8).write(to: url)
    #expect(OCRStage.recognizeText(in: url) == nil)
}
