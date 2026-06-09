import Foundation

/// One queued local deletion awaiting review for propagation to a drive.
/// Rebuildable-cache semantics (lives in the catalog); a wiped catalog forgets
/// pending intents — a safe failure (the drive simply keeps its copy).
public struct PendingDeletionRecord: Sendable, Equatable {
    public let hash: String        // content identity; join key vs instances + vault_presence
    public let relPath: String     // Mac-aligned path, display only
    public let deletedAtMs: Int64
    public init(hash: String, relPath: String, deletedAtMs: Int64) {
        self.hash = hash; self.relPath = relPath; self.deletedAtMs = deletedAtMs
    }
}
