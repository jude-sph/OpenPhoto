import Testing
import Foundation
@testable import OpenPhotoCore

private func sendEntry(hash: String, dest: String) -> SendRegistry.Entry {
    SendRegistry.Entry(hash: hash, destinationKey: dest, deviceName: "Backup SSD",
                       deviceKind: "volume", sentAt: "2026-06-08T13:30:00.000Z",
                       confirmedAt: "2026-06-08T13:31:00.000Z", fpSize: 100, fpCaptureDateMs: 1_700_000_000_000)
}

@Test func sendRegistryAppendsLooksUpAndPersists() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = SendRegistry(vault: vault)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try reg.append(sendEntry(hash: h, dest: "vol-ABC"))
    #expect(reg.contains(destinationKey: "vol-ABC", hash: h))
    #expect(!reg.contains(destinationKey: "vol-XYZ", hash: h))   // different device
    #expect(reg.entries(forDestinationKey: "vol-ABC").count == 1)
    // Idempotent per (destination, hash).
    try reg.append(sendEntry(hash: h, dest: "vol-ABC"))
    let reg2 = SendRegistry(vault: vault); try reg2.load()
    #expect(reg2.entries(forDestinationKey: "vol-ABC").count == 1)
    #expect(reg2.contains(destinationKey: "vol-ABC", hash: h))
}
