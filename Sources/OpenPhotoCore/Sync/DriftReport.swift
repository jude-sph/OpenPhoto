import Foundation

public enum Recoverability: Sendable, Equatable {
    case recoverable(source: String)   // a verified-good copy exists elsewhere
    case lostNoCopy                    // no good copy known anywhere
    case unknown                       // not yet evaluated
}

public struct DriftFinding: Sendable, Equatable {
    public enum Kind: String, Sendable { case unknown, missing, changed, corrupt }
    public let kind: Kind
    public let relPath: String
    public let recordedHash: String?   // manifest hash (missing/changed/corrupt)
    public let onDiskHash: String?     // re-hashed value (verify only)
    public let recordedSize: Int64?
    public let onDiskSize: Int64?
    public var recoverability: Recoverability
    public init(kind: Kind, relPath: String, recordedHash: String? = nil, onDiskHash: String? = nil,
                recordedSize: Int64? = nil, onDiskSize: Int64? = nil,
                recoverability: Recoverability = .unknown) {
        self.kind = kind; self.relPath = relPath; self.recordedHash = recordedHash
        self.onDiskHash = onDiskHash; self.recordedSize = recordedSize
        self.onDiskSize = onDiskSize; self.recoverability = recoverability
    }
}

public struct DriftReport: Sendable, Equatable {
    public var unknown: [DriftFinding] = []
    public var missing: [DriftFinding] = []
    public var changed: [DriftFinding] = []
    public var corrupt: [DriftFinding] = []
    public var presentHashes: Set<String> = []   // manifest hashes confirmed present (drives vault_presence)
    public var verified: Bool = false            // true when produced by a full re-hash
    public init() {}
    public var isClean: Bool { unknown.isEmpty && missing.isEmpty && changed.isEmpty && corrupt.isEmpty }
}

public struct DriftProgress: Sendable {
    public let done: Int
    public let total: Int
    public let currentName: String
    public init(done: Int, total: Int, currentName: String) {
        self.done = done; self.total = total; self.currentName = currentName
    }
}

public enum DriftError: Error, Equatable { case restoreFailed, notOnDisk }
