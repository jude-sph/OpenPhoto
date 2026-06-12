import Testing
import Foundation
@testable import OpenPhotoCore

private func makeEnv(_ t: TestDirs) throws -> (LibraryService, Vault, ImportRegistry) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("existing/OLD.jpg").creatingParent(),
                 dateTimeOriginal: "2024:01:01 00:00:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    let vault = lib.vaults[0]
    return (lib, vault, ImportRegistry(vault: vault))
}

private func fakeItems() -> [(ImportItem, Data)] {
    [
        (ImportItem(id: "1", name: "IMG_1.JPG", byteSize: 3, takenAt: Date(timeIntervalSince1970: 100), kind: .photo, livePartnerID: nil), Data("one".utf8)),
        (ImportItem(id: "2", name: "IMG_2.JPG", byteSize: 3, takenAt: Date(timeIntervalSince1970: 200), kind: .photo, livePartnerID: nil), Data("two".utf8)),
    ]
}

@Test func importsPlacesVerifiesAndRecords() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    let result = await engine.run(source: fake, items: items, vault: vault, dirPath: "trip2026")
    #expect(result.imported.count == 2 && result.failed.isEmpty && result.skipped.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent("trip2026/IMG_1.JPG").path))
    // In catalog + manifest after the engine's rescan:
    #expect(try lib.items(inDir: "trip2026").count == 2)
    // Registry remembers:
    #expect(reg.entries(forSourceKey: "fk").count == 2)
    // Staging cleaned:
    let staging = vault.stateDirURL.appendingPathComponent("staging")
    let leftover = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    #expect(leftover.isEmpty)
}

@Test func sameFolderReimportSkips() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    _ = await engine.run(source: fake, items: items, vault: vault, dirPath: "a")
    let again = await engine.run(source: fake, items: items, vault: vault, dirPath: "a")
    #expect(again.imported.isEmpty && again.skipped.count == 2)   // same folder → no-op
}

@Test func differentFolderReimportPlacesSecondInstance() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    _ = await engine.run(source: fake, items: items, vault: vault, dirPath: "a")
    let b = await engine.run(source: fake, items: items, vault: vault, dirPath: "b")
    #expect(b.imported.count == 2 && b.skipped.isEmpty)            // different folder → copies
    #expect(try lib.items(inDir: "b").count == 2)
    #expect(try lib.items(inDir: "a").count == 2)                  // original still there
}

@Test func collisionGetsSuffixedName() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try t.file("Pictures/trip/IMG_1.JPG", Data("different-bytes".utf8))
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    let result = await engine.run(source: fake, items: [items[0]], vault: vault, dirPath: "trip")
    #expect(result.imported.count == 1)
    #expect(FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent("trip/IMG_1 (2).JPG").path))
}

@Test func fetchFailureFailsItemAndBatchContinues() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    fake.failFetchIDs = ["1"]
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    let result = await engine.run(source: fake, items: items, vault: vault, dirPath: "x")
    #expect(result.failed.count == 1 && result.failed[0].item.id == "1")
    #expect(result.imported.count == 1)
    #expect(reg.entries(forSourceKey: "fk").count == 1)   // failed item never recorded
}

@Test func livePairImportsAtomically() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let photo = ImportItem(id: "p", name: "IMG_9.HEIC", byteSize: 3,
                           takenAt: Date(timeIntervalSince1970: 50), kind: .photo, livePartnerID: "v")
    let video = ImportItem(id: "v", name: "IMG_9.MOV", byteSize: 3,
                           takenAt: Date(timeIntervalSince1970: 50), kind: .video, livePartnerID: "p")
    let fake = FakeSource(sourceKey: "fk", items: [(photo, Data("ph".utf8)), (video, Data("vd".utf8))])
    let engine = ImportEngine(library: lib, registry: reg)
    // Caller passes ONLY the photo — the engine must pull the partner in.
    let result = await engine.run(source: fake, items: [photo], vault: vault, dirPath: "lp")
    #expect(result.imported.count == 2)
    #expect(FileManager.default.fileExists(
        atPath: vault.rootURL.appendingPathComponent("lp/IMG_9.MOV").path))
    _ = (photo, video)
}

@Test func subdirForItemPlacesIntoPerItemFolders() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()

    let result = await engine.run(source: fake, items: items, vault: vault,
                                  dirPath: "From Sam",
                                  subdirForItem: { $0.id == "1" ? "rome2022" : "" })

    #expect(result.imported.count == 2 && result.failed.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: vault.absoluteURL(forRelativePath: "From Sam/rome2022/IMG_1.JPG").path))
    #expect(FileManager.default.fileExists(
        atPath: vault.absoluteURL(forRelativePath: "From Sam/IMG_2.JPG").path))
    // Registry + manifest recorded the real placed relPaths.
    let placed = Set(result.imported.map(\.placedRelPath))
    #expect(placed == ["From Sam/rome2022/IMG_1.JPG", "From Sam/IMG_2.JPG"])
}

@Test func subdirAwareDedupSkipsOnlyWithinTheSameTargetDir() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()
    // First import into From Sam/rome2022.
    _ = await engine.run(source: fake, items: [items[0]], vault: vault,
                         dirPath: "From Sam", subdirForItem: { _ in "rome2022" })
    // Same item again into the SAME subdir → skipped as duplicate.
    let again = await engine.run(source: fake, items: [items[0]], vault: vault,
                                 dirPath: "From Sam", subdirForItem: { _ in "rome2022" })
    #expect(again.skipped.count == 1 && again.imported.isEmpty)
}

@Test func postPlaceRunsBeforeRescanWithPlacedRelPath() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault, reg) = try makeEnv(t)
    try await lib.scanAll()
    let fake = FakeSource(sourceKey: "fk", items: fakeItems())
    let engine = ImportEngine(library: lib, registry: reg)
    let items = try await fake.enumerateItems()

    // postPlace writes a sidecar next to the placed file; because the hook runs BEFORE the
    // engine's rescan, the rescan must ingest it in the same run (favorite lands in catalog).
    let result = await engine.run(source: fake, items: [items[0]], vault: vault,
                                  dirPath: "inbox",
                                  postPlace: { placed in
        let mediaURL = vault.absoluteURL(forRelativePath: placed.placedRelPath)
        let xmp = XMP.serialize(SidecarData(rating: 0, favorite: true, caption: "from them",
                                            tags: [], faces: []))
        try? AtomicFile.write(Data(xmp.utf8), to: vault.sidecarURL(forMediaAt: mediaURL))
    })

    #expect(result.imported.count == 1)
    let item = try lib.items(inDir: "inbox").first
    #expect(item?.favorite == true && item?.caption == "from them")
}

