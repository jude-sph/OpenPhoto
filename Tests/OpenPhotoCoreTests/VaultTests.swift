import Testing
import Foundation
@testable import OpenPhotoCore

@Test func createsVaultStateOnFirstOpen() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let vault = try Vault.openOrCreate(at: root, role: .local)
    #expect(vault.descriptor.formatVersion == 1)
    #expect(vault.descriptor.role == .local)
    let vjson = root.appendingPathComponent(".openphoto/vault.json")
    #expect(FileManager.default.fileExists(atPath: vjson.path))
    // Reopen → same vault_id.
    let again = try Vault.openOrCreate(at: root, role: .local)
    #expect(again.descriptor.vaultID == vault.descriptor.vaultID)
}

@Test func refusesNewerFormatVersion() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/.openphoto/vault.json", Data("""
    {"format_version": 99, "vault_id": "X", "role": "local", "created_at": "2026-01-01T00:00:00.000Z", "app": "Other/9"}
    """.utf8))
    #expect(throws: VaultError.self) { try Vault.openOrCreate(at: root, role: .local) }
}

@Test func pathHelpersFollowFormat() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let media = root.appendingPathComponent("rome2022/IMG_1.heic")
    #expect(vault.sidecarURL(forMediaAt: media).path
        == root.appendingPathComponent("rome2022/.openphoto/IMG_1.heic.xmp").path)
    #expect(vault.manifestURL.path == root.appendingPathComponent(".openphoto/manifest.jsonl").path)
    #expect(vault.binDirURL.path == root.appendingPathComponent(".openphoto/bin").path)
    #expect(vault.relativePath(of: media) == "rome2022/IMG_1.heic")
}

@Test func relativePathResolvesSymlinkedRoot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let real = try t.sub("RealPictures")
    let link = t.root.appendingPathComponent("LinkedPictures")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let vault = try Vault.openOrCreate(at: link, role: .local)
    let media = real.appendingPathComponent("a/b.jpg")   // path via the REAL root
    #expect(vault.relativePath(of: media) == "a/b.jpg")
}
