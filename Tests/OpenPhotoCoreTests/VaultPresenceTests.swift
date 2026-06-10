import Testing
import Foundation
@testable import OpenPhotoCore

private func makeCatalog(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}

@Test func registerAndListVaults() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    try c.registerVault(id: "v-local", role: "local", rootPath: "/tmp/pics")
    try c.registerVault(id: "v-canon", role: "canonical", rootPath: "/Volumes/Canonical")
    let all = try c.registeredVaults()
    #expect(Set(all.map(\.id)) == ["v-local", "v-canon"])
    #expect(all.first { $0.id == "v-canon" }?.role == "canonical")
}

@Test func replaceAndReadVaultPresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let h2 = "sha256:" + String(repeating: "2", count: 64)
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h1, relPath: "a.jpg", dirPath: "", size: 1, driveRelPath: "Pictures/a.jpg"),
        VaultPresenceEntry(hash: h2, relPath: "b.jpg", dirPath: "", size: 2, driveRelPath: "Pictures/b.jpg"),
    ])
    #expect(try c.vaultPresenceHashes(forVault: "v-canon") == [h1, h2])
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h1, relPath: "a.jpg", dirPath: "", size: 1, driveRelPath: "Pictures/a.jpg"),
    ])   // full swap, not append
    #expect(try c.vaultPresenceHashes(forVault: "v-canon") == [h1])
    #expect(try c.vaultPresenceHashes(forVault: "absent").isEmpty)
}

@Test func unregisterVaultRemovesItAndItsPresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try c.registerVault(id: "v-canon", role: "canonical", rootPath: "/Volumes/Canonical")
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h, relPath: "a.jpg", dirPath: "", size: 1, driveRelPath: "Pictures/a.jpg")])
    try c.unregisterVault(id: "v-canon")
    #expect(try c.registeredVaults().contains { $0.id == "v-canon" } == false)
    #expect(try c.vaultPresenceHashes(forVault: "v-canon").isEmpty)
}
