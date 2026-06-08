import Foundation
import CoreGraphics

/// One item visible on an import source (device photo, SD-card file).
public struct ImportItem: Identifiable, Sendable, Equatable {
    public let id: String          // source-stable id (ICC object handle / volume relpath)
    public var name: String
    public var byteSize: Int64
    public var takenAt: Date?
    public var kind: MediaKind
    /// Set by pairLiveItems(): the other half of a Live Photo, if detected.
    public var livePartnerID: String?

    public init(id: String, name: String, byteSize: Int64, takenAt: Date?,
                kind: MediaKind, livePartnerID: String?) {
        self.id = id; self.name = name; self.byteSize = byteSize
        self.takenAt = takenAt; self.kind = kind; self.livePartnerID = livePartnerID
    }
}

public enum SourceState: Sendable, Equatable {
    case connected          // found, session not open yet
    case waitingForUnlock   // ICC error -9943 — UI shows "Unlock your iPhone"
    case ready              // enumerable
    case gone               // unplugged / unmounted
}

public struct DeleteResult: Sendable, Equatable {
    public let itemID: String
    public let error: String?      // nil = deleted
    public init(itemID: String, error: String?) {
        self.itemID = itemID; self.error = error
    }
}

/// A place photos can be imported from — spec §3. Implementations:
/// CameraSource (ICC), VolumeSource (SD/folder), FakeSource (tests).
public protocol ImportSource: Sendable {
    var sourceKey: String { get }              // stable per device — registry key part
    var displayName: String { get }
    func enumerateItems() async throws -> [ImportItem]   // sorted newest-first
    func fetch(_ item: ImportItem, to url: URL) async throws
    func delete(_ items: [ImportItem]) async throws -> [DeleteResult]
    func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage?
    /// Number of items sitting in the source's reclaimable trash (volumes only). Default 0.
    func reclaimableTrashCount() async -> Int
    /// Permanently remove the source's reclaimable trash. Default no-op.
    func emptyTrash() async throws
    /// Release any held session/resources (e.g. an ICC camera session). Default no-op.
    func close()
}

public extension ImportSource {
    /// Number of items sitting in the source's reclaimable trash (volumes only). Default 0.
    func reclaimableTrashCount() async -> Int { 0 }
    /// Permanently remove the source's reclaimable trash. Default no-op.
    func emptyTrash() async throws {}
    func close() {}
}

/// Pair Live Photo halves among device items: same lowercased basename,
/// photo+video, capture times within 2s (mirrors LivePhotoPairer's fallback).
public func pairLiveItems(_ items: [ImportItem]) -> [ImportItem] {
    func base(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }
    var videosByBase: [String: ImportItem] = [:]
    for i in items where i.kind == .video { videosByBase[base(i.name)] = i }
    var out = items
    for (idx, i) in out.enumerated() where i.kind == .photo {
        guard let v = videosByBase[base(i.name)],
              let pt = i.takenAt, let vt = v.takenAt,
              abs(pt.timeIntervalSince(vt)) <= 2 else { continue }
        out[idx].livePartnerID = v.id
        if let vIdx = out.firstIndex(where: { $0.id == v.id }) {
            out[vIdx].livePartnerID = i.id
        }
    }
    return out
}
