import Testing
import Foundation
@testable import OpenPhotoCore

@Test func deviceRegistryUpsertsNameAndPersists() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = DeviceRegistry(vault: vault)
    reg.upsert(key: "vol-ABC", name: "Backup SSD", kind: "volume", at: "2026-06-08T10:00:00.000Z")
    reg.upsert(key: "vol-ABC", name: "Backup SSD (renamed)", kind: "volume", at: "2026-06-09T10:00:00.000Z")
    #expect(reg.name(forKey: "vol-ABC") == "Backup SSD (renamed)")   // latest name wins
    #expect(reg.name(forKey: "vol-NONE") == nil)
    let reloaded = DeviceRegistry(vault: vault)
    #expect(reloaded.name(forKey: "vol-ABC") == "Backup SSD (renamed)")
    // first_seen is preserved across upserts.
    #expect(reloaded.entry(forKey: "vol-ABC")?.firstSeen == "2026-06-08T10:00:00.000Z")
}
