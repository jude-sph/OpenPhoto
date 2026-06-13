import Testing
import Foundation
import CoreVideo
@testable import OpenPhotoCore

/// Make a 112×112 32BGRA pixel buffer filled with a deterministic gradient (no real face data —
/// this only checks the model loads, runs on this toolchain, and emits a well-formed 512-d vector).
private func makeBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA, attrs, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buf)
    for y in 0..<112 {
        for x in 0..<112 {
            let p = y * stride + x * 4
            base[p + 0] = UInt8(x * 255 / 111)   // B
            base[p + 1] = UInt8(y * 255 / 111)   // G
            base[p + 2] = UInt8((x + y) * 255 / 222) // R
            base[p + 3] = 255                     // A
        }
    }
    return buf
}

@Test func faceEmbedderLoadsAndProducesA512dVector() throws {
    try #require(FaceEmbedder.shared.isAvailable)   // model compiles + loads on this machine
    let vec = try #require(FaceEmbedder.shared.embed(makeBuffer()))
    #expect(vec.count == FaceEmbedder.dimension)    // 512
    #expect(vec.allSatisfy { $0.isFinite })
    #expect(vec.contains { $0 != 0 })               // not all-zero
    // AdaFace output is L2-normalized → magnitude ≈ 1.
    let norm = (vec.reduce(0) { $0 + $1 * $1 }).squareRoot()
    #expect(abs(norm - 1.0) < 0.05)
}

@Test func faceEmbedderIsDeterministic() throws {
    try #require(FaceEmbedder.shared.isAvailable)
    let a = try #require(FaceEmbedder.shared.embed(makeBuffer()))
    let b = try #require(FaceEmbedder.shared.embed(makeBuffer()))
    let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    #expect(dot > 0.999)   // same input → same embedding
}
