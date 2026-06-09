import Testing
import Foundation
@testable import OpenPhotoCore

private func scannedLibrary(_ t: TestDirs, _ name: String = "Pictures") throws -> LibraryService {
    let pics = try t.sub(name)
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    return try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as-" + name))
}

@Test func applyCopiesVerifiesAndUpdatesManifest() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let result = await engine.apply(plan, destinationVault: drive, volume: vol)

    #expect(result.copied == 2)
    #expect(result.failed.isEmpty)
    let a = drive.rootURL.appendingPathComponent("Pictures/rome2022/IMG_1.jpg")
    let src = lib.vaults[0].rootURL.appendingPathComponent("rome2022/IMG_1.jpg")
    #expect(try Data(contentsOf: a) == (try Data(contentsOf: src)))
    let entries = try Manifest.read(from: drive.manifestURL)
    #expect(Set(entries.map(\.path)) == ["Pictures/rome2022/IMG_1.jpg", "Pictures/lisbon25/IMG_2.jpg"])
    #expect(FileManager.default.fileExists(atPath: drive.syncLogURL.path))
    #expect(FileManager.default.fileExists(atPath: lib.vaults[0].syncLogURL.path))
}

@Test func applyWritesSidecar() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    try SidecarStore(vault: lib.vaults[0]).write(
        SidecarData(rating: 4, favorite: false, caption: nil, tags: []),
        forMediaRelPath: "rome2022/IMG_1.jpg")
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let result = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                    destinationVault: drive, volume: vol)
    #expect(result.sidecarsWritten == 1)
    let destSidecar = drive.rootURL.appendingPathComponent("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: destSidecar.path))
}
