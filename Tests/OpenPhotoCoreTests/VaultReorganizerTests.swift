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

// MARK: - moveFile (file-grain)

private func sidecarSeed(_ vault: Vault, mediaRelPath: String) throws -> URL {
    let sc = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: mediaRelPath))
    try FileManager.default.createDirectory(at: sc.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("xmp".utf8).write(to: sc)
    return sc
}

@Test func moveFileMovesMediaSidecarAndManifestEntry() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    let h = try seed(vault, relPath: "a/x.jpg")
    let other = try seed(vault, relPath: "a/y.jpg", bytes: "other")
    let oldSidecar = try sidecarSeed(vault, mediaRelPath: "a/x.jpg")
    try Manifest.write([
        ManifestEntry(hash: h, path: "a/x.jpg", size: 1, mtime: ISO8601Millis.string(from: Date())),
        ManifestEntry(hash: other, path: "a/y.jpg", size: 5, mtime: ISO8601Millis.string(from: Date())),
    ], to: vault.manifestURL)

    let newRel = try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", intoDirRelPath: "b/sub")

    #expect(newRel == "b/sub/x.jpg")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/sub/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    // Sidecar traveled into the destination's .openphoto dir.
    let newSidecar = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: "b/sub/x.jpg"))
    #expect(FileManager.default.fileExists(atPath: newSidecar.path))
    #expect(!FileManager.default.fileExists(atPath: oldSidecar.path))
    // Exactly the one manifest entry rewritten; the sibling untouched.
    let byPath = Dictionary(uniqueKeysWithValues: try Manifest.read(from: vault.manifestURL).map { ($0.path, $0) })
    #expect(byPath["b/sub/x.jpg"]?.hash == h && byPath["b/sub/x.jpg"]?.size == 1)
    #expect(byPath["a/y.jpg"]?.hash == other)
    #expect(byPath.count == 2)
}

@Test func moveFileCollisionRenamesMediaAndSidecarTogether() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    let h = try seed(vault, relPath: "a/x.jpg")
    _ = try seed(vault, relPath: "b/x.jpg", bytes: "occupied")
    _ = try sidecarSeed(vault, mediaRelPath: "a/x.jpg")
    try Manifest.write([ManifestEntry(hash: h, path: "a/x.jpg", size: 1,
                        mtime: ISO8601Millis.string(from: Date()))], to: vault.manifestURL)

    let newRel = try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", intoDirRelPath: "b")

    #expect(newRel == "b/x (2).jpg")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/x (2).jpg").path))
    // Sidecar name matches the collision-adjusted media name.
    let newSidecar = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: "b/x (2).jpg"))
    #expect(FileManager.default.fileExists(atPath: newSidecar.path))
    let entries = try Manifest.read(from: vault.manifestURL)
    #expect(entries.count == 1 && entries[0].path == "b/x (2).jpg")
}

@Test func moveFileSameDirIsNoOpAndMissingThrows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    _ = try seed(vault, relPath: "a/x.jpg")
    #expect(try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", intoDirRelPath: "a") == "a/x.jpg")
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    #expect(throws: (any Error).self) {
        try VaultReorganizer.moveFile(in: vault, relPath: "a/gone.jpg", intoDirRelPath: "b")
    }
}

@Test func moveFileExactTargetKeepsAlignedNameAndRootMovesWork() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vaultRoot = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = try Vault.openOrCreate(at: vaultRoot, role: .canonical)
    _ = try seed(vault, relPath: "a/x.jpg")
    // Exact target: the basename is taken verbatim (drive mirrors the Mac's "(2)" rename).
    let newRel = try VaultReorganizer.moveFile(in: vault, relPath: "a/x.jpg", toRelPath: "b/x (2).jpg")
    #expect(newRel == "b/x (2).jpg")
    // Into the vault root ("" dir).
    _ = try seed(vault, relPath: "c/y.jpg")
    #expect(try VaultReorganizer.moveFile(in: vault, relPath: "c/y.jpg", intoDirRelPath: "") == "y.jpg")
}
