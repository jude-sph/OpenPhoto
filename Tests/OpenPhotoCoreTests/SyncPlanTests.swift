import Testing
import Foundation
@testable import OpenPhotoCore

private func scannedLibrary(_ t: TestDirs, _ name: String = "Pictures") throws -> LibraryService {
    let pics = try t.sub(name)
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as-" + name))
    return lib
}

@Test func planOnFreshDriveCopiesEverything() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.copies.count == 2)
    #expect(plan.conflicts.isEmpty)
    #expect(plan.totalCopyBytes > 0)
    #expect(Set(plan.copies.map(\.destRelPath)) == ["Pictures/rome2022/IMG_1.jpg",
                                                     "Pictures/lisbon25/IMG_2.jpg"])
}

@Test func planAfterApplySkipsAll() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    _ = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                           destinationVault: drive, volume: vol)
    let plan2 = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan2.copies.isEmpty)
    #expect(plan2.conflicts.isEmpty)
}

@Test func planFlagsConflictOnDifferentBytesAtSamePath() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let clash = drive.rootURL.appendingPathComponent("Pictures/rome2022/IMG_1.jpg")
    try FileManager.default.createDirectory(at: clash.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("not the same bytes".utf8).write(to: clash)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.conflicts.count == 1)
    #expect(plan.copies.count == 1)
}

@Test func planIncludesSidecarUpdate() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let v = lib.vaults.first!
    let store = SidecarStore(vault: v)
    try store.write(SidecarData(rating: 5, favorite: true, caption: "hi", tags: ["x"]),
                    forMediaRelPath: "rome2022/IMG_1.jpg")
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.sidecarUpdates.count == 1)
    #expect(plan.sidecarUpdates[0].destRelPath == "Pictures/rome2022/.openphoto/IMG_1.jpg.xmp")
}
