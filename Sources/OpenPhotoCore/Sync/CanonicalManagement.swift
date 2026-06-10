import Foundation

/// A backup is promotable to canonical only when its content is an EXACT copy of the canonical —
/// the same hashes, nothing missing and nothing extra. (Extra = an un-applied deletion the backup
/// still holds; promoting it would resurrect a deleted photo. Missing = behind on additions.)
public func canonicalAgreement(canonicalHashes: Set<String>, backupHashes: Set<String>) -> Bool {
    canonicalHashes == backupHashes
}

/// How a recovery (promoting a backup when the canonical is lost) splits the photos that were on the
/// lost canonical but not on the backup: those the Mac still holds locally (recoverable via the
/// one-way Mac→canonical sync) vs those reachable nowhere (genuinely lost).
public struct RecoveryLoss: Sendable, Equatable {
    public var recoverableFromMac: Int
    public var lost: Int
    public init(recoverableFromMac: Int, lost: Int) {
        self.recoverableFromMac = recoverableFromMac; self.lost = lost
    }
}

public func recoveryLoss(lostCanonicalHashes: Set<String>, backupHashes: Set<String>,
                         macLocalHashes: Set<String>) -> RecoveryLoss {
    let atRisk = lostCanonicalHashes.subtracting(backupHashes)
    return RecoveryLoss(recoverableFromMac: atRisk.intersection(macLocalHashes).count,
                        lost: atRisk.subtracting(macLocalHashes).count)
}
