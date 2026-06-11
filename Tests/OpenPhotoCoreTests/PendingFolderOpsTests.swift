import Testing
import Foundation
@testable import OpenPhotoCore

@Test func folderOpQueueRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let a1 = try cat.enqueueFolderOp(vaultID: "A", op: "move", src: "rome", dst: "trips/rome")
    _ = try cat.enqueueFolderOp(vaultID: "A", op: "create", src: nil, dst: "new")
    _ = try cat.enqueueFolderOp(vaultID: "B", op: "delete", src: "old", dst: nil)

    let aOps = try cat.pendingFolderOps(forVault: "A")
    #expect(aOps.count == 2)
    #expect(aOps[0].op == "move" && aOps[0].src == "rome" && aOps[0].dst == "trips/rome")
    #expect(aOps[1].op == "create" && aOps[1].dst == "new")
    #expect(try cat.pendingFolderOps(forVault: "B").count == 1)

    try cat.clearFolderOp(id: a1)
    #expect(try cat.pendingFolderOps(forVault: "A").count == 1)   // only the create remains
    try cat.clearFolderOps(forVault: "B")
    #expect(try cat.pendingFolderOps(forVault: "B").isEmpty)
}
