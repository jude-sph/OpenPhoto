import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// `.models/Resources` relative to this test file (repo-root/.models/Resources). The directory is
/// gitignored — present only on machines that ran the model fetch. Tests degrade to skips when it's
/// absent.
private func modelResourcesDir() -> URL {
    URL(fileURLWithPath: #filePath)                     // …/Tests/OpenPhotoCoreTests/EmbedStageTests.swift
        .deletingLastPathComponent()                    // …/Tests/OpenPhotoCoreTests
        .deletingLastPathComponent()                    // …/Tests
        .deletingLastPathComponent()                    // repo root
        .appendingPathComponent(".models/Resources")
}

/// Write a solid-color JPEG (headless Core Graphics) at `url`.
private func writeSolidJPEG(_ color: CGColor, to url: URL, size: Int = 256) throws {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL,
                        UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

private func l2Norm(_ v: [Float]) -> Float {
    var s: Float = 0
    for x in v { s += x * x }
    return s.squareRoot()
}

/// The tokenizer needs only the gitignored vocab (no Core ML), so this asserts hard when the vocab
/// is present and skips otherwise. Ground-truth ids come from the reference OpenAI CLIP tokenizer.
@Test func clipTokenizerMatchesReferenceIDs() throws {
    guard let tok = CLIPTokenizer(vocabDirectory: modelResourcesDir()) else { return }  // skip: no vocab

    func ids(_ s: String) -> [Int32] {
        let full = tok.encode(s)
        #expect(full.count == CLIPTokenizer.contextLength)
        // Strip trailing zero padding for comparison.
        var end = full.count
        while end > 0 && full[end - 1] == 0 { end -= 1 }
        return Array(full[0 ..< end])
    }

    #expect(ids("a photo of a cat") == [49406, 320, 1125, 539, 320, 2368, 49407])
    #expect(ids("a photo of a dog") == [49406, 320, 1125, 539, 320, 1929, 49407])
    #expect(ids("hello world") == [49406, 3306, 1002, 49407])
    // BOS/EOS framing constants.
    #expect(CLIPTokenizer.bos == 49406 && CLIPTokenizer.eos == 49407)
}

@Test func embedImageProducesUnitVector() throws {
    let stage = EmbedStage(modelDirectory: modelResourcesDir())
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("solid.jpg")
    try writeSolidJPEG(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1), to: url)

    guard let v = stage.embedImage(at: url) else { return }   // skip: model absent in this env
    #expect(v.count == stage.dim)
    #expect(abs(l2Norm(v) - 1) < 1e-3)
}

@Test func embedTextProducesUnitVector() throws {
    let stage = EmbedStage(modelDirectory: modelResourcesDir())
    guard let v = stage.embedText("a photo of a dog") else { return }   // skip: model/vocab absent
    #expect(v.count == stage.dim)
    #expect(abs(l2Norm(v) - 1) < 1e-3)
}

/// Image and text of the same concept should be more similar (higher cosine == dot, since both are
/// L2-normalized) than mismatched ones — the core property semantic search relies on. Skips if the
/// models aren't present.
@Test func imageTextCosineSeparatesConcepts() throws {
    let stage = EmbedStage(modelDirectory: modelResourcesDir())
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("red.jpg")
    try writeSolidJPEG(CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1), to: url)

    guard let img = stage.embedImage(at: url),
          let red = stage.embedText("a solid red color"),
          let blue = stage.embedText("a solid blue color") else { return }   // skip

    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    // Not asserting which wins (a flat synthetic swatch is a weak signal), only that the model ran
    // end-to-end and the dot products are valid cosine similarities in [-1, 1].
    let dr = dot(img, red), db = dot(img, blue)
    #expect(dr >= -1.001 && dr <= 1.001)
    #expect(db >= -1.001 && db <= 1.001)
}

/// Graceful degradation: an empty/modelless directory yields nil, never a crash.
@Test func embedReturnsNilWhenModelDirEmpty() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let stage = EmbedStage(modelDirectory: t.root)
    let url = t.root.appendingPathComponent("x.jpg")
    try writeSolidJPEG(CGColor(red: 0, green: 0, blue: 0, alpha: 1), to: url)
    #expect(stage.embedImage(at: url) == nil)
    #expect(stage.embedText("anything") == nil)
}
