import Foundation

/// Kind of target a library asset can be sent to.
public enum DeviceKind: String, Sendable, Codable { case phone, volume }

/// A cheap identity for "is this asset on the target?" — the round-trip-proven
/// fingerprint (size + capture date). `hash` is filled only when computing it is
/// cheap (volumes); phones leave it nil.
public struct PresenceFingerprint: Sendable, Equatable {
    public let size: Int64
    public let captureDateMs: Int64    // epoch ms; 0 if unknown
    public let hash: String?
    public init(size: Int64, captureDateMs: Int64, hash: String? = nil) {
        self.size = size; self.captureDateMs = captureDateMs; self.hash = hash
    }
    /// Same byte size and same capture second (EXIF dates are second-precision, so
    /// compare at second granularity to avoid sub-second drift).
    public func looselyMatches(_ other: PresenceFingerprint) -> Bool {
        captureDateMs != 0 && other.captureDateMs != 0 &&
        size == other.size && captureDateMs / 1000 == other.captureDateMs / 1000
    }
}

/// One library asset queued to send: its content hash (authoritative identity),
/// the read-only original file, its fingerprint, and a display name for progress.
public struct SendItem: Sendable, Equatable {
    public let hash: String
    public let originalURL: URL
    public let fingerprint: PresenceFingerprint
    public let displayName: String
    public init(hash: String, originalURL: URL, fingerprint: PresenceFingerprint, displayName: String) {
        self.hash = hash; self.originalURL = originalURL
        self.fingerprint = fingerprint; self.displayName = displayName
    }
}

/// Per-item result of a send attempt.
public struct SendOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case confirmed, alreadyPresent, unconfirmed, failed }
    public let item: SendItem
    public let status: Status
    public let error: String?
    public init(item: SendItem, status: Status, error: String? = nil) {
        self.item = item; self.status = status; self.error = error
    }
}

/// Progress tick for the UI.
public struct SendProgress: Sendable {
    public enum Stage: String, Sendable { case sending, verifying }
    public let stage: Stage
    public let done: Int
    public let total: Int
    public let currentName: String
    public init(stage: Stage, done: Int, total: Int, currentName: String) {
        self.stage = stage; self.done = done; self.total = total; self.currentName = currentName
    }
}

/// A place library assets can be sent to (write-side mirror of `ImportSource`).
/// Implementations: `VolumeCopyDestination` (filesystem), `AirDropDestination` (Stage B2).
public protocol SendDestination: Sendable {
    var destinationKey: String { get }   // serial / volume UUID — same keyspace as ImportSource.sourceKey
    var displayName: String { get }
    var deviceKind: DeviceKind { get }
    /// What's currently on the target — for dedup and (AirDrop) verification.
    func enumeratePresent() async throws -> [PresenceFingerprint]
    /// Push items; verify before confirming. Reports progress; returns one outcome per item.
    func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome]
}
