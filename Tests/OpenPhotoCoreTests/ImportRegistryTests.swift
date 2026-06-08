import Testing
import Foundation
@testable import OpenPhotoCore

private func entry(_ name: String, taken: String) -> ImportRegistry.Entry {
    ImportRegistry.Entry(sourceKey: "iphone-1", name: name, size: 123,
                         takenAt: taken, hash: "sha256:" + String(repeating: "a", count: 64),
                         importedAt: "2026-06-08T02:00:00.000Z",
                         importedTo: "rome2026/\(name)")
}

@Test func appendsAndLooksUp() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let reg = ImportRegistry(vault: vault)
    let e = entry("IMG_1.HEIC", taken: "2026-06-01T10:00:00.000Z")
    try reg.append(e)
    #expect(reg.contains(sourceKey: "iphone-1", name: "IMG_1.HEIC", size: 123,
                         takenAt: "2026-06-01T10:00:00.000Z"))
    #expect(!reg.contains(sourceKey: "iphone-1", name: "IMG_2.HEIC", size: 123,
                          takenAt: "2026-06-01T10:00:00.000Z"))
    // Reload from disk — durable.
    let reg2 = ImportRegistry(vault: vault)
    try reg2.load()
    #expect(reg2.contains(sourceKey: "iphone-1", name: "IMG_1.HEIC", size: 123,
                          takenAt: "2026-06-01T10:00:00.000Z"))
    #expect(reg2.entries(forSourceKey: "iphone-1").count == 1)
}

@Test func appendIsIdempotentPerKey() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = ImportRegistry(vault: vault)
    try reg.append(entry("IMG_1.HEIC", taken: "2026-06-01T10:00:00.000Z"))
    try reg.append(entry("IMG_1.HEIC", taken: "2026-06-01T10:00:00.000Z"))   // dup key
    let reg2 = ImportRegistry(vault: vault); try reg2.load()
    #expect(reg2.entries(forSourceKey: "iphone-1").count == 1)
}

private func entryHashed(_ name: String, sourceKey: String, hash: String) -> ImportRegistry.Entry {
    ImportRegistry.Entry(sourceKey: sourceKey, name: name, size: 123,
                         takenAt: "2026-06-01T10:00:00.000Z", hash: hash,
                         importedAt: "2026-06-08T02:00:00.000Z",
                         importedTo: "rome2026/\(name)")
}

@Test func deviceKeysForHashAggregatesAcrossSourcesAndPersists() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = ImportRegistry(vault: vault)
    let h = "sha256:" + String(repeating: "c", count: 64)
    try reg.append(entryHashed("IMG_1.HEIC", sourceKey: "iphone-A", hash: h))
    try reg.append(entryHashed("IMG_1.HEIC", sourceKey: "sdcard-B", hash: h))   // same bytes, 2 devices
    #expect(reg.deviceKeys(forHash: h) == ["iphone-A", "sdcard-B"])
    #expect(reg.deviceKeys(forHash: "sha256:" + String(repeating: "d", count: 64)).isEmpty)
    // Rebuilt on reload from disk.
    let reg2 = ImportRegistry(vault: vault); try reg2.load()
    #expect(reg2.deviceKeys(forHash: h) == ["iphone-A", "sdcard-B"])
}
