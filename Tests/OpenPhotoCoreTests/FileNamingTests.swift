import Testing
import Foundation
@testable import OpenPhotoCore

@Test func collisionFreeNamesSuffixUntilFree() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("d")
    // Free name passes through untouched.
    #expect(FileNaming.collisionFreeURL(for: "x.jpg", in: dir).lastPathComponent == "x.jpg")
    try Data("a".utf8).write(to: dir.appendingPathComponent("x.jpg"))
    #expect(FileNaming.collisionFreeURL(for: "x.jpg", in: dir).lastPathComponent == "x (2).jpg")
    try Data("b".utf8).write(to: dir.appendingPathComponent("x (2).jpg"))
    #expect(FileNaming.collisionFreeURL(for: "x.jpg", in: dir).lastPathComponent == "x (3).jpg")
    // Extension-less names suffix the bare base.
    try Data("c".utf8).write(to: dir.appendingPathComponent("README"))
    #expect(FileNaming.collisionFreeURL(for: "README", in: dir).lastPathComponent == "README (2)")
}
