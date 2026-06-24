import Testing
import Foundation
@testable import OpenPhotoCore

private func tmpDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("vc-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
}
private func writeFile(_ url: URL, bytes: Int) throws -> String {
    var d = Data(count: 0); d.reserveCapacity(bytes)
    var x: UInt8 = 7
    for _ in 0..<bytes { x = x &* 31 &+ 11; d.append(x) }
    try d.write(to: url)
    return try ContentHash.ofFile(at: url).stringValue
}

/// Box for accumulating synchronous-callback state from `@Sendable` closures (Swift 6 language mode
/// forbids capturing a mutating local `var`). `VerifiedCopy.copy` invokes the callbacks synchronously
/// on the calling thread before returning, so there is no real concurrency here.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Test func streamingCopySucceedsAndVerifies() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("out/dst.bin")
    let hash = try writeFile(src, bytes: 9 << 20)            // 9 MB → multiple 4MB chunks
    let bytesSeenBox = Box<[Int64]>([])
    let outcome = VerifiedCopy.copy(from: src, to: dst, expectedHash: hash,
                                    onBytes: { bytesSeenBox.value.append($0) }, shouldCancel: { false })
    let bytesSeen = bytesSeenBox.value
    #expect(outcome == .copied)
    #expect(FileManager.default.fileExists(atPath: dst.path))
    #expect(try ContentHash.ofFile(at: dst).stringValue == hash)          // bytes identical
    #expect(bytesSeen.last == Int64(9 << 20))                              // ends at file size
    #expect(bytesSeen == bytesSeen.sorted())                              // monotonic
    // no temp left behind
    #expect(try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
              .filter { $0.hasPrefix(".tmp-") }.isEmpty)
}

@Test func streamedHashEqualsContentHash() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("a.bin"); let dst = dir.appendingPathComponent("b.bin")
    let hash = try writeFile(src, bytes: (4 << 20) + 123)   // not a chunk multiple
    #expect(VerifiedCopy.copy(from: src, to: dst, expectedHash: hash) == .copied)
}

@Test func cancelMidStreamLeavesNoTemp() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("dst.bin")
    let hash = try writeFile(src, bytes: 20 << 20)
    let callsBox = Box<Int>(0)
    let outcome = VerifiedCopy.copy(from: src, to: dst, expectedHash: hash,
                                    onBytes: { _ in },
                                    shouldCancel: { callsBox.value += 1; return callsBox.value > 1 })
    #expect(outcome == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: dst.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
              .filter { $0.hasPrefix(".tmp-") }.isEmpty)
}

@Test func hashMismatchIsFailureNoDest() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("dst.bin")
    _ = try writeFile(src, bytes: 1 << 20)
    let outcome = VerifiedCopy.copy(from: src, to: dst, expectedHash: "sha256:deadbeef")
    #expect(outcome == .failed(.hashMismatch))
    #expect(!FileManager.default.fileExists(atPath: dst.path))
}

@Test func neverOverwritesExistingDest() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("dst.bin")
    let hash = try writeFile(src, bytes: 1024)
    try "occupied".data(using: .utf8)!.write(to: dst)
    #expect(VerifiedCopy.copy(from: src, to: dst, expectedHash: hash) == .failed(.conflict))
    #expect(try Data(contentsOf: dst) == "occupied".data(using: .utf8)!)
}

@Test func missingSourceIsFailure() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = VerifiedCopy.copy(from: dir.appendingPathComponent("nope.bin"),
                                    to: dir.appendingPathComponent("dst.bin"), expectedHash: "sha256:x")
    #expect(outcome == .failed(.sourceMissing))
}
