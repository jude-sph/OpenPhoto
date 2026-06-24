import Foundation

extension LibraryService {
    /// Every local original whose hash is verified-present on a durable drive — the evict-all set.
    public func allEvictableLocal(canonicalPresence: Set<String>) throws -> [TimelineItem] {
        try catalog.allLocalInstances().filter { $0.driveRelPath == nil && canonicalPresence.contains($0.hash) }
    }

    /// Every asset present on a drive but absent from the Mac — the rehydrate-all set.
    public func allDriveOnly() throws -> [TimelineItem] {
        try catalog.allDriveOnlyItems()
    }
}
