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
