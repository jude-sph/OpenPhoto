import Foundation

/// Why a single file didn't sync. Drives the user-facing failure report + retry.
public enum SyncFailureReason: String, Sendable, Equatable {
    case sourceMissing   // source file gone / unreadable
    case copyFailed      // I/O writing to the drive (disk full, permissions, drive disconnected)
    case hashMismatch    // copied bytes didn't verify — temp discarded
    case conflict        // a DIFFERENT file already occupies that path (never overwritten)

    public var userText: String {
        switch self {
        case .sourceMissing: return "source file missing"
        case .copyFailed:    return "copy failed (drive full or disconnected)"
        case .hashMismatch:  return "checksum mismatch"
        case .conflict:      return "a different file is already there"
        }
    }
    /// Conflicts need a real decision; everything else is worth retrying.
    public var isRetryable: Bool { self != .conflict }
}

public struct FailedItem: Sendable, Equatable {
    public let item: PlanItem
    public let reason: SyncFailureReason
    public init(item: PlanItem, reason: SyncFailureReason) { self.item = item; self.reason = reason }
}
