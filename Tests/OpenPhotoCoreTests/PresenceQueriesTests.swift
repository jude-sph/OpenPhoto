import Testing
import Foundation
@testable import OpenPhotoCore

@Test func catalogInstancesForHashReturnsLocalInstances() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let hash = try #require(try lib.catalog.timelineItems().first).hash
    let instances = try lib.catalog.instances(forHash: hash)
    #expect(instances.count == 1)
    #expect(instances[0].relPath == "rome/IMG_1.jpg" && instances[0].dirPath == "rome")
    #expect(try lib.catalog.instances(forHash: "sha256:" + String(repeating: "0", count: 64)).isEmpty)
}

@Test func registryEntriesForHash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let h = "sha256:" + String(repeating: "a", count: 64)
    let imports = ImportRegistry(vault: vault)
    try imports.append(ImportRegistry.Entry(sourceKey: "vol-Y", name: "x.jpg", size: 1, takenAt: "",
        hash: h, importedAt: "2026-06-08T00:00:00.000Z", importedTo: "a/x.jpg"))
    #expect(imports.entries(forHash: h).count == 1)
    #expect(imports.entries(forHash: "sha256:" + String(repeating: "b", count: 64)).isEmpty)

    let sends = SendRegistry(vault: vault)
    try sends.append(SendRegistry.Entry(hash: h, destinationKey: "cam-Z", deviceName: "iPhone",
        deviceKind: "phone", sentAt: "2026-06-08T01:00:00.000Z", confirmedAt: "2026-06-08T01:01:00.000Z",
        fpSize: 1, fpCaptureDateMs: 0))
    #expect(sends.entries(forHash: h).count == 1)
    #expect(sends.entries(forHash: "sha256:" + String(repeating: "b", count: 64)).isEmpty)
}
