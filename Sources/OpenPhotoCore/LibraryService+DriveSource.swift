import Foundation

extension LibraryService {
    /// The first connected drive (in the given canonical-first order) that holds `hash`, paired with
    /// its presence row (which carries the drive-relative path). Lets a drive-only read source from
    /// ANY durable drive — a backup serves when the canonical is unplugged — rather than only the
    /// item's pinned vault. Callers pass drives canonical-first so the canonical is preferred.
    func driveSource(forHash hash: String, among drives: [Vault]) -> (vault: Vault, row: VaultPresenceEntry)? {
        for d in drives {
            if let row = (try? catalog.vaultPresenceRows(forVault: d.descriptor.vaultID))?
                .first(where: { $0.hash == hash }) {
                return (d, row)
            }
        }
        return nil
    }
}
