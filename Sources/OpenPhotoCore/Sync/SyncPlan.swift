import Foundation

public struct PlanItem: Sendable, Equatable {
    public let hash: String          // "" for sidecar items
    public let sourceURL: URL
    public let destRelPath: String   // drive-root-relative, "/" separators, NFC
    public let size: Int64
    public init(hash: String, sourceURL: URL, destRelPath: String, size: Int64) {
        self.hash = hash; self.sourceURL = sourceURL; self.destRelPath = destRelPath; self.size = size
    }
}

public struct SyncPlan: Sendable, Equatable {
    public var copies: [PlanItem] = []
    public var sidecarUpdates: [PlanItem] = []
    public var conflicts: [PlanItem] = []
    public var totalCopyBytes: Int64 = 0
    public init() {}
}

public struct SyncResult: Sendable, Equatable {
    public var copied = 0
    public var sidecarsWritten = 0
    public var skipped = 0
    public var failed: [FailedItem] = []
    public var cancelled = false
    public init() {}
    /// Files skipped because a DIFFERENT file already occupies the path.
    public var conflicts: Int { failed.filter { $0.reason == .conflict }.count }
    /// Genuine transient failures (everything retryable).
    public var retryableFailures: [FailedItem] { failed.filter { $0.reason.isRetryable } }
}

public enum SyncError: Error, Equatable { case insufficientSpace(needed: Int64, free: Int64) }

public struct SyncProgress: Sendable {
    public enum Stage: String, Sendable { case copying, verifying, finishing }
    public let stage: Stage
    public let done: Int
    public let total: Int
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentName: String
    public init(stage: Stage, done: Int, total: Int, bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
                currentName: String) {
        self.stage = stage; self.done = done; self.total = total
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.currentName = currentName
    }
}
