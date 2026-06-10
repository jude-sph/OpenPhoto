import Testing
import Foundation
@testable import OpenPhotoCore

@Test func writingRoleRewritesVaultJsonPreservingID() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let v = try Vault.openOrCreate(at: root, role: .canonical)
    let id = v.descriptor.vaultID

    let updated = try v.writingRole(.backup)
    #expect(updated.descriptor.role == .backup)
    #expect(updated.descriptor.vaultID == id)

    // Re-opening reads the on-disk role (openOrCreate ignores the passed role for an existing vault).
    let reopened = try Vault.openOrCreate(at: root, role: .canonical)
    #expect(reopened.descriptor.role == .backup)
    #expect(reopened.descriptor.vaultID == id)
}
