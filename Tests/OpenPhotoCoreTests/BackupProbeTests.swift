import Testing
import Foundation
@testable import OpenPhotoCore

@Test func backupProbeFlagsHashesWithNoKnownDevice() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = ImportRegistry(vault: vault)
    let onPhone = "sha256:" + String(repeating: "a", count: 64)
    let macOnly = "sha256:" + String(repeating: "b", count: 64)
    try reg.append(ImportRegistry.Entry(
        sourceKey: "iphone-A", name: "IMG_1.HEIC", size: 1, takenAt: "",
        hash: onPhone, importedAt: "2026-06-08T00:00:00.000Z", importedTo: "a/IMG_1.HEIC"))

    let probe = BackupProbe(registry: reg)
    #expect(probe.isOnlyOnThisMac(hash: macOnly) == true)     // never came from a device
    #expect(probe.isOnlyOnThisMac(hash: onPhone) == false)    // known on iphone-A
    #expect(probe.onlyOnThisMac(hashes: [onPhone, macOnly]) == [macOnly])
}
