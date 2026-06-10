import Testing
import Foundation
@testable import OpenPhotoCore

@Test func replaceVaultPresenceRoundTripsEntries() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    let h = "sha256:" + String(repeating: "a", count: 64)
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome/a.jpg", dirPath: "rome", size: 123,
                           driveRelPath: "Pictures/rome/a.jpg")])
    #expect(try c.vaultPresenceHashes(forVault: "v-canon") == [h])      // badge path still works
    let rows = try c.vaultPresenceRows(forVault: "v-canon")
    #expect(rows.count == 1)
    #expect(rows[0].driveRelPath == "Pictures/rome/a.jpg" && rows[0].dirPath == "rome")
}
