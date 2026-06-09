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
    public var copied: Int = 0
    public var sidecarsWritten: Int = 0
    public var skipped: Int = 0
    public var conflicts: Int = 0
    public var failed: [PlanItem] = []
    public init() {}
}

public enum SyncError: Error, Equatable { case insufficientSpace(needed: Int64, free: Int64) }
