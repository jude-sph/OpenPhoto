import Testing
import Foundation
@testable import OpenPhotoCore

private func makeLibrary(_ t: TestDirs) throws -> LibraryService {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    return try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("appsupport"))
}

@Test func scanThenBrowse() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let sections = try lib.timelineSections()
    #expect(sections.count == 2)                       // two distinct days
    #expect(sections[0].items[0].relPath == "lisbon25/IMG_2.jpg")   // newest first
    let tree = try lib.folderTree()
    #expect(tree.map(\.name).sorted() == ["lisbon25", "rome2022"])
}

@Test func editWritesSidecarAndCatalog() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let item = try lib.timelineSections()[0].items[0]
    try lib.updateMetadata(for: item, rating: 4, favorite: true, caption: "hi", tags: ["x"])
    let reloaded = try lib.item(hash: item.hash)
    #expect(reloaded?.rating == 4 && reloaded?.favorite == true)
    let sidecar = t.root.appendingPathComponent("Pictures/lisbon25/.openphoto/IMG_2.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
}

@Test func deleteToBinAndRestore() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let item = try lib.timelineSections()[0].items[0]
    try await lib.delete(item)
    #expect(try lib.timelineSections().flatMap(\.items).count == 1)
    let binned = try lib.binItems()
    #expect(binned.count == 1)
    try await lib.restore(binned[0])
    #expect(try lib.timelineSections().flatMap(\.items).count == 2)
}

@Test func scanPicksUpSidecarsFromDisk() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try t.file("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp",
               Data(XMP.serialize(SidecarData(rating: 3, favorite: false,
                                              caption: nil, tags: ["pre"])).utf8))
    try await lib.scanAll()
    let rome = try lib.items(inDir: "rome2022")
    #expect(rome[0].rating == 3 && rome[0].tagsJSON.contains("pre"))
}

@Test func folderTreeNestsChildrenCorrectly() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("mac-screenshots/2024/s1.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try makeJPEG(at: pics.appendingPathComponent("2025/lisbon25/IMG.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let tree = lib2Dict(try lib.folderTree())
    #expect(tree["mac-screenshots"]?.children.map(\.name) == ["2024"])     // THE BUG: was []
    #expect(tree["2025"]?.children.map(\.name) == ["lisbon25"])
    #expect(tree["rome2022"]?.children.isEmpty == true)
    #expect(tree["mac-screenshots"]?.count == 0)                            // no direct items
    #expect(tree["mac-screenshots"]?.children.first?.count == 1)
}

private func lib2Dict(_ nodes: [FolderNode]) -> [String: FolderNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })
}
