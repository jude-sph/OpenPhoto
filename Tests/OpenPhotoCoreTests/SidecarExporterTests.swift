import Testing
import Foundation
@testable import OpenPhotoCore

@Test func sidecarExporterWritesMirrorTreeSkippingEmpties() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try makeJPEG(at: pics.appendingPathComponent("paris/PLAIN.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    try await lib.scanAll()
    let rome = try lib.catalog.timelineItems().first { $0.relPath == "rome/IMG.jpg" }!
    try lib.updateMetadata(for: rome, rating: 4, favorite: false, caption: "hi", tags: ["a", "b"])

    let dest = try t.sub("export")
    let n = try SidecarExporter.export(library: lib, to: dest)
    #expect(n == 1)                                                   // only the tagged one
    let out = dest.appendingPathComponent("rome/IMG.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: out.path))
    let parsed = try XMP.parse(try Data(contentsOf: out))
    #expect(Set(parsed.tags) == ["a", "b"] && parsed.rating == 4)
    #expect(!FileManager.default.fileExists(                          // empty sidecar → skipped
        atPath: dest.appendingPathComponent("paris/PLAIN.jpg.xmp").path))
    #expect(!FileManager.default.fileExists(                          // library NOT polluted
        atPath: pics.appendingPathComponent("rome/IMG.jpg.xmp").path))
}
