import Testing
import Foundation
@testable import OpenPhotoCore

@Test func atomicWriteCreatesFileWithContents() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dest = t.root.appendingPathComponent("a/b/manifest.jsonl")
    try AtomicFile.write(Data("hello".utf8), to: dest)
    #expect(try Data(contentsOf: dest) == Data("hello".utf8))
}

@Test func atomicWriteReplacesExistingFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dest = try t.file("x.txt", Data("old".utf8))
    try AtomicFile.write(Data("new".utf8), to: dest)
    #expect(try String(contentsOf: dest, encoding: .utf8) == "new")
}

@Test func leavesNoTempFilesBehind() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dest = t.root.appendingPathComponent("y.txt")
    try AtomicFile.write(Data("z".utf8), to: dest)
    let names = try FileManager.default.contentsOfDirectory(atPath: t.root.path)
    #expect(names == ["y.txt"])
}
