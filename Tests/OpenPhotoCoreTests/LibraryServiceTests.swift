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

@Test func renameMovesFileAndSidecarKeepingIdentity() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let item = try lib.timelineSections()[0].items[0]   // lisbon25/IMG_2.jpg (newest first)
    // Write a sidecar so we can verify it follows the rename
    try lib.updateMetadata(for: item, rating: 2, favorite: false, caption: nil, tags: [])
    // Rename
    try await lib.rename(item, to: "renamed.jpg")
    // Verify new path exists in catalog via hash identity
    let renamed = try #require(try lib.item(hash: item.hash))
    #expect(renamed.relPath.hasSuffix("/renamed.jpg") || renamed.relPath == "renamed.jpg")
    // Rating preserved (sidecar followed)
    #expect(renamed.rating == 2)
    // Old file is gone
    let pics = t.root.appendingPathComponent("Pictures")
    #expect(!FileManager.default.fileExists(atPath: pics.appendingPathComponent("lisbon25/IMG_2.jpg").path))
    // Sidecar is in new location
    let newSidecar = pics.appendingPathComponent("lisbon25/.openphoto/renamed.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: newSidecar.path))
}

@Test func timelineGroupingNoneReturnsSingleSection() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let sections = try lib.timelineSections(grouping: .none)
    #expect(sections.count == 1)
    #expect(sections[0].title == "All photos")
    #expect(sections[0].items.count == 2)
}

@Test func daySectionsHaveUniqueIdsAndDescendingOrder() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    for (i, date) in ["2025:11:20 10:00:00", "2025:11:14 09:00:00",
                      "2025:11:14 08:00:00", "2025:11:08 07:00:00"].enumerated() {
        try makeJPEG(at: pics.appendingPathComponent("a/IMG_\(i).jpg").creatingParent(),
                     dateTimeOriginal: date, lat: nil, lon: nil)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let sections = try lib.timelineSections(grouping: .day)
    #expect(sections.count == 3)                              // two photos share Nov 14
    #expect(Set(sections.map(\.dayStartMs)).count == 3)       // unique ids
    #expect(sections.map(\.dayStartMs) == sections.map(\.dayStartMs).sorted(by: >))  // newest first
    #expect(sections[1].items.count == 2)
}

@Test func timelineGroupingMonthMergesSameDayDifferentItems() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    // Both in October 2022 but different days → should merge into one month section
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:08 10:00:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let sections = try lib.timelineSections(grouping: .month)
    #expect(sections.count == 1)
    #expect(sections[0].title == "October 2022")
    #expect(sections[0].items.count == 2)
}
