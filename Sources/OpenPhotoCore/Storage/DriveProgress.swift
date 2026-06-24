import Foundation

/// Progress for a long storage operation (evict or rehydrate). Mirrors `SyncProgress` but with the
/// extra stages those operations use. The App buffers the latest one and a 0.5s ticker renders it
/// (windowed speed + whole-job ETA) — same pattern as sync.
public struct DriveProgress: Sendable {
    public enum Stage: String, Sendable { case verifying, copying, trashing, finishing }
    public var stage: Stage
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var currentName: String
    public init(stage: Stage, filesDone: Int = 0, filesTotal: Int = 0,
                bytesDone: Int64 = 0, bytesTotal: Int64 = 0, currentName: String = "") {
        self.stage = stage; self.filesDone = filesDone; self.filesTotal = filesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.currentName = currentName
    }
}
