import Testing
import Foundation
@testable import OpenPhotoCore

@Test func presenceLocationsAndOnlyCopyJudgment() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let vault = lib.vaults.first!
    let hash = try #require(try lib.catalog.timelineItems().first).hash
    let imports = ImportRegistry(vault: vault), sends = SendRegistry(vault: vault)
    let devices = DeviceRegistry(vault: vault)
    let presence = PresenceService(catalog: lib.catalog, imports: imports, sends: sends, devices: devices)

    // Only on this Mac initially.
    #expect(presence.isOnlyOnThisMac(hash: hash))
    let locs0 = presence.locations(forHash: hash)
    #expect(locs0.contains { if case .thisMac = $0.place { $0.confidence == .confirmed } else { false } })

    // After a confirmed send → backed up (believed), no longer only-copy.
    try sends.append(SendRegistry.Entry(hash: hash, destinationKey: "cam-Z", deviceName: "iPhone",
        deviceKind: "phone", sentAt: "2026-06-08T01:00:00.000Z", confirmedAt: "2026-06-08T01:01:00.000Z",
        fpSize: 1, fpCaptureDateMs: 0))
    #expect(!presence.isOnlyOnThisMac(hash: hash))
    #expect(presence.locations(forHash: hash).contains {
        if case .device(_, let n, let k) = $0.place { n == "iPhone" && k == .phone && $0.confidence == .believed }
        else { false } })

    // Imported-from only (historical) is still only-copy (card may be wiped).
    let h2 = "sha256:" + String(repeating: "e", count: 64)
    try imports.append(ImportRegistry.Entry(sourceKey: "vol-Y", name: "x.jpg", size: 1, takenAt: "",
        hash: h2, importedAt: "2026-06-08T00:00:00.000Z", importedTo: "a/x.jpg"))
    #expect(presence.isOnlyOnThisMac(hash: h2))
    #expect(presence.locations(forHash: h2).contains {
        if case .device = $0.place { $0.confidence == .historical } else { false } })
}

@Test func presenceIncludesDriveVaultAsConfirmed() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    let v = try Vault.openOrCreate(at: try t.sub("pics"), role: .local)
    let sends = SendRegistry(vault: v); let devices = DeviceRegistry(vault: v)
    let imports = ImportRegistry(vault: v)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try c.registerVault(id: "v-canon", role: "canonical", rootPath: "/Volumes/Canonical")
    try c.replaceVaultPresence(vaultID: "v-canon", hashes: [h])

    let svc = PresenceService(catalog: c, imports: imports, sends: sends, devices: devices)
    let locs = svc.locations(forHash: h)
    #expect(locs.contains { loc in
        if case .device(let key, _, _) = loc.place { return key == "v-canon" && loc.confidence == .confirmed }
        return false
    })
    #expect(svc.isOnlyOnThisMac(hash: h) == false)
}

@Test func presenceDedupsDeviceSeenInBothSendAndImport() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let imports = ImportRegistry(vault: vault), sends = SendRegistry(vault: vault)
    let devices = DeviceRegistry(vault: vault)
    let catalog = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let presence = PresenceService(catalog: catalog, imports: imports, sends: sends, devices: devices)
    let h = "sha256:" + String(repeating: "f", count: 64)
    // Same hash both sent to AND imported from the same device key.
    try sends.append(SendRegistry.Entry(hash: h, destinationKey: "cam-Z", deviceName: "iPhone",
        deviceKind: "phone", sentAt: "2026-06-08T01:00:00.000Z", confirmedAt: "2026-06-08T01:01:00.000Z",
        fpSize: 1, fpCaptureDateMs: 0))
    try imports.append(ImportRegistry.Entry(sourceKey: "cam-Z", name: "x", size: 1, takenAt: "",
        hash: h, importedAt: "2026-06-07T00:00:00.000Z", importedTo: "a/x"))
    let deviceLocs = presence.locations(forHash: h).filter {
        if case .device = $0.place { return true } else { return false }
    }
    #expect(deviceLocs.count == 1)                       // the device appears exactly once...
    #expect(deviceLocs.first?.confidence == .believed)   // ...as believed (sent-to wins over historical)
}
