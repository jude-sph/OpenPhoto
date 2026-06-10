import Testing
import Foundation
@testable import OpenPhotoCore

private func h(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }

@Test func agreementIsExactSetEquality() {
    #expect(canonicalAgreement(canonicalHashes: [h("a"), h("b")], backupHashes: [h("a"), h("b")]))
    #expect(!canonicalAgreement(canonicalHashes: [h("a"), h("b")], backupHashes: [h("a")]))         // missing
    #expect(!canonicalAgreement(canonicalHashes: [h("a")], backupHashes: [h("a"), h("b")]))         // extra
    #expect(canonicalAgreement(canonicalHashes: [], backupHashes: []))
}

@Test func recoveryLossSplitsAtRiskByMacAvailability() {
    let r = recoveryLoss(lostCanonicalHashes: [h("a"), h("b"), h("c")],
                         backupHashes: [h("a")], macLocalHashes: [h("b")])
    #expect(r == RecoveryLoss(recoverableFromMac: 1, lost: 1))   // atRisk={b,c}; b on Mac, c lost
}

@Test func recoveryLossZeroWhenBackupHasEverything() {
    let r = recoveryLoss(lostCanonicalHashes: [h("a"), h("b")],
                         backupHashes: [h("a"), h("b")], macLocalHashes: [])
    #expect(r == RecoveryLoss(recoverableFromMac: 0, lost: 0))
}

@Test func setCanonicalFlipsBothRolesAtomically() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "A", role: "canonical", rootPath: "/A")
    try cat.registerVault(id: "B", role: "backup", rootPath: "/B")

    try cat.setCanonical("B", demoting: "A")

    let roles = Dictionary(try cat.registeredVaults().map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
    #expect(roles["B"] == "canonical")
    #expect(roles["A"] == "backup")
    #expect(try cat.registeredVaults().filter { $0.role == "canonical" }.count == 1)   // exactly one
}

@Test func setCanonicalNilDemotionOnlyPromotes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "B", role: "backup", rootPath: "/B")
    try cat.setCanonical("B", demoting: nil)
    #expect(try cat.registeredVaults().first { $0.id == "B" }?.role == "canonical")
}
