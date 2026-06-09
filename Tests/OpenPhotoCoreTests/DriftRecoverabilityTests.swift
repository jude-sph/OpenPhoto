import Testing
import Foundation
@testable import OpenPhotoCore

@Test func recoverableWhenHashIsOnAnotherVault() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    let v = try Vault.openOrCreate(at: try t.sub("pics"), role: .local)
    let imports = ImportRegistry(vault: v); let sends = SendRegistry(vault: v); let devices = DeviceRegistry(vault: v)
    let h = "sha256:" + String(repeating: "a", count: 64)
    // The hash also lives on another canonical drive (verified present there).
    try c.registerVault(id: "v-other", role: "canonical", rootPath: "/Volumes/Other")
    try c.replaceVaultPresence(vaultID: "v-other", hashes: [h])
    let presence = PresenceService(catalog: c, imports: imports, sends: sends, devices: devices)

    let r = DriftReconciler()
    #expect(r.recoverability(forHash: h, excludingVault: "v-this", presence: presence)
            == .recoverable(source: "Other"))
    #expect(r.recoverability(forHash: "sha256:" + String(repeating: "0", count: 64),
                             excludingVault: "v-this", presence: presence) == .lostNoCopy)
}

@Test func recoverabilityExcludesTheDriveBeingRepaired() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    let v = try Vault.openOrCreate(at: try t.sub("pics"), role: .local)
    let imports = ImportRegistry(vault: v); let sends = SendRegistry(vault: v); let devices = DeviceRegistry(vault: v)
    let h = "sha256:" + String(repeating: "a", count: 64)
    // The hash is present ONLY on the drive we're repairing — it must NOT count as its own
    // recovery source (a corrupt-only-copy is lost, not "restorable from itself").
    try c.registerVault(id: "v-this", role: "canonical", rootPath: "/Volumes/This")
    try c.replaceVaultPresence(vaultID: "v-this", hashes: [h])
    let presence = PresenceService(catalog: c, imports: imports, sends: sends, devices: devices)
    #expect(DriftReconciler().recoverability(forHash: h, excludingVault: "v-this",
                                             presence: presence) == .lostNoCopy)
}
