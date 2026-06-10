import Foundation

/// A drive-only item whose drive is not connected, so its bytes can't be read to send right now.
public struct UnreachableSendItem: Sendable, Equatable {
    public let hash: String
    public let displayName: String   // filename, for the warning list
    public let driveName: String     // which drive to connect (its root-folder basename)
    public init(hash: String, displayName: String, driveName: String) {
        self.hash = hash; self.displayName = displayName; self.driveName = driveName
    }
}

/// A selection split into what can be sent now and what can't.
public struct SendSourcePlan: Sendable {
    public var sendable: [SendItem]                 // ready: local file, or connected-drive file
    public var unreachable: [UnreachableSendItem]   // drive-only, drive not connected
    public init(sendable: [SendItem], unreachable: [UnreachableSendItem]) {
        self.sendable = sendable; self.unreachable = unreachable
    }
}

extension LibraryService {
    /// Resolve a selection into sendable `SendItem`s and the unreachable remainder.
    ///
    /// - Local item (`driveRelPath == nil`): sourced from its local vault file. Dropped if the
    ///   vault is unknown (matches the prior `compactMap` behavior); a present-but-vanished file is
    ///   NOT dropped here — the destination reports it failed, exactly as before.
    /// - Drive-only item whose `vaultID` is among `connectedDrives` (keyed by `descriptor.vaultID`):
    ///   sourced directly from the drive file — no staging.
    /// - Drive-only item whose drive is absent: `unreachable`, named via `driveNames[vaultID]`.
    ///
    /// Pure: builds URLs and value structs only; does not read the filesystem.
    public func resolveSendSources(_ items: [TimelineItem],
                                   connectedDrives: [Vault],
                                   driveNames: [String: String]) -> SendSourcePlan {
        let drivesByID = Dictionary(connectedDrives.map { ($0.descriptor.vaultID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var sendable: [SendItem] = []
        var unreachable: [UnreachableSendItem] = []
        for item in items {
            let name = (item.relPath as NSString).lastPathComponent
            let fingerprint = PresenceFingerprint(size: item.size, captureDateMs: item.takenAtMs,
                                                  hash: item.hash)
            if item.driveRelPath == nil {
                guard let url = absoluteURL(for: item) else { continue }
                sendable.append(SendItem(hash: item.hash, originalURL: url,
                                         fingerprint: fingerprint, displayName: name))
            } else if let drive = drivesByID[item.vaultID] {
                let url = drive.absoluteURL(forRelativePath: item.driveRelPath!)
                sendable.append(SendItem(hash: item.hash, originalURL: url,
                                         fingerprint: fingerprint, displayName: name))
            } else {
                unreachable.append(UnreachableSendItem(hash: item.hash, displayName: name,
                                                       driveName: driveNames[item.vaultID] ?? "a drive"))
            }
        }
        return SendSourcePlan(sendable: sendable, unreachable: unreachable)
    }
}
