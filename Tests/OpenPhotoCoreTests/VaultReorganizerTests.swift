import Testing
import Foundation
@testable import OpenPhotoCore

private func seed(_ vault: Vault, relPath: String, bytes: String = "x") throws -> ContentHash {
    let url = vault.absoluteURL(forRelativePath: relPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url)
    return try ContentHash.ofFile(at: url)
}

@Test func moveFolderRelocatesFilesAndRewritesManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    let h = try seed(vault, relPath: "a/x.jpg")
    try Manifest.write([ManifestEntry(hash: h, path: "a/x.jpg", size: 1,
                        mtime: ISO8601Millis.string(from: Date()))], to: vault.manifestURL)
    let newPath = try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "b")
    #expect(newPath == "b/a")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/a/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    let entries = try Manifest.read(from: vault.manifestURL)
    #expect(entries.count == 1 && entries[0].path == "b/a/x.jpg" && entries[0].hash == h)
}

@Test func moveIntoSelfOrDescendantThrows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    _ = try seed(vault, relPath: "a/b/x.jpg")
    #expect(throws: (any Error).self) { try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "a/b") }
    #expect(throws: (any Error).self) { try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "a") }
}

@Test func moveOntoExistingNameThrows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    _ = try seed(vault, relPath: "a/x.jpg")
    _ = try seed(vault, relPath: "b/a/y.jpg")
    #expect(throws: (any Error).self) { try VaultReorganizer.moveFolder(in: vault, relPath: "a", intoParentRelPath: "b") }
}

@Test func createAndDeleteEmptyFolder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    try VaultReorganizer.createFolder(in: vault, relPath: "new/sub")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "new/sub").path))
    try VaultReorganizer.deleteEmptyFolder(in: vault, relPath: "new/sub")
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "new/sub").path))
    _ = try seed(vault, relPath: "full/x.jpg")
    #expect(throws: (any Error).self) { try VaultReorganizer.deleteEmptyFolder(in: vault, relPath: "full") }
}
