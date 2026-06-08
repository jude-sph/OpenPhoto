import Testing
import Foundation
@testable import OpenPhotoCore

private func libAndVault(_ t: TestDirs) throws -> (LibraryService, Vault) {
    let pics = try t.sub("Pictures")
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    return (lib, lib.vaults.first!)
}

private func item(_ name: String, hash: String, size: Int64 = 100,
                  captureMs: Int64 = 1_700_000_000_000) -> SendItem {
    SendItem(hash: hash, originalURL: URL(fileURLWithPath: "/tmp/\(name)"),
             fingerprint: PresenceFingerprint(size: size, captureDateMs: captureMs, hash: hash),
             displayName: name)
}

@Test func sendEngineRecordsConfirmedAndLogsDevice() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try libAndVault(t)
    let sends = SendRegistry(vault: vault)
    let devices = DeviceRegistry(vault: vault)
    let dest = FakeSendDestination(key: "vol-A", name: "Card")
    let engine = SendEngine(library: lib, sends: sends, devices: devices)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let result = await engine.run(destination: dest, items: [item("a.jpg", hash: h1)], vault: vault)
    #expect(result.confirmed.count == 1)
    #expect(sends.contains(destinationKey: "vol-A", hash: h1))      // recorded
    #expect(devices.name(forKey: "vol-A") == "Card")               // device remembered
}

@Test func sendEngineSkipsItemsAlreadyOnTarget() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try libAndVault(t)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let dest = FakeSendDestination(key: "vol-A",
        present: [PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_000, hash: h1)])
    let engine = SendEngine(library: lib, sends: SendRegistry(vault: vault),
                            devices: DeviceRegistry(vault: vault))
    let h2 = "sha256:" + String(repeating: "2", count: 64)
    let result = await engine.run(destination: dest,
        items: [item("a.jpg", hash: h1), item("b.jpg", hash: h2)], vault: vault)
    #expect(result.alreadyPresent.count == 1)
    #expect(result.confirmed.count == 1)
    #expect(dest.sentItems.map(\.hash) == [h2])                    // only the new one was sent
}

@Test func sendEngineDedupsByFingerprintWhenNoHashOnTarget() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try libAndVault(t)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let dest = FakeSendDestination(key: "cam-A", kind: .phone,
        present: [PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_400, hash: nil)])
    let engine = SendEngine(library: lib, sends: SendRegistry(vault: vault),
                            devices: DeviceRegistry(vault: vault))
    let result = await engine.run(destination: dest, items: [item("a.jpg", hash: h1)], vault: vault)
    #expect(result.alreadyPresent.count == 1)   // matched by size+date despite no hash
    #expect(dest.sentItems.isEmpty)
}
