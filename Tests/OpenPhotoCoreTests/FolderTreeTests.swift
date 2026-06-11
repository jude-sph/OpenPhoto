import Testing
import Foundation
@testable import OpenPhotoCore

@Test func folderTreeIncludesEmptyDirectories() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    // Catalog a real photo under a/
    try makeJPEG(at: pics.appendingPathComponent("a/photo.jpg").creatingParent(),
                 dateTimeOriginal: "2024:01:01 12:00:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("appsupport"))
    try await lib.scanAll()

    // Create an empty real directory b/ that has no photos — should still appear
    try FileManager.default.createDirectory(
        at: pics.appendingPathComponent("b"),
        withIntermediateDirectories: true)

    let tree = try lib.folderTree()
    func flatten(_ ns: [FolderNode]) -> [String] {
        ns.flatMap { [$0.path] + flatten($0.children) }
    }
    let paths = flatten(tree)
    #expect(paths.contains("a"))
    #expect(paths.contains("b"))
}
