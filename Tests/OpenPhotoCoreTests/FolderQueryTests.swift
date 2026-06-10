import Testing
import Foundation
@testable import OpenPhotoCore

@Test func itemsRecursiveIncludesSubfoldersNotSiblings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    func asset(_ h: String) -> AssetRecord {
        AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
            livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
            caption: nil, tagsJSON: "[]")
    }
    let inFolder = "sha256:" + String(repeating: "a", count: 64)
    let inSub = "sha256:" + String(repeating: "b", count: 64)
    let inSibling = "sha256:" + String(repeating: "c", count: 64)   // "2025x" must NOT match "2025"
    try cat.upsert(assets: [asset(inFolder), asset(inSub), asset(inSibling)])
    try cat.replaceVaultPresence(vaultID: "d", entries: [
        VaultPresenceEntry(hash: inFolder, relPath: "2025/x.jpg", dirPath: "2025",
                           size: 1, driveRelPath: "2025/x.jpg"),
        VaultPresenceEntry(hash: inSub, relPath: "2025/lisbon25/y.jpg", dirPath: "2025/lisbon25",
                           size: 1, driveRelPath: "2025/lisbon25/y.jpg"),
        VaultPresenceEntry(hash: inSibling, relPath: "2025x/z.jpg", dirPath: "2025x",
                           size: 1, driveRelPath: "2025x/z.jpg")])

    // Non-recursive: only the exact folder.
    #expect(Set(try cat.items(inDir: "2025").map(\.hash)) == [inFolder])
    // Recursive: the folder + descendants, but NOT the "2025x" sibling.
    #expect(Set(try cat.items(inDir: "2025", recursive: true).map(\.hash)) == [inFolder, inSub])
}
