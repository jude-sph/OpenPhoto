import Foundation

/// Runs one send batch: remember device → live-dedup → send → record confirmed →
/// log. Spec: docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md §4.4.
public final class SendEngine: Sendable {
    public struct Result: Sendable {
        public var confirmed: [SendOutcome] = []
        public var alreadyPresent: [SendOutcome] = []
        public var unconfirmed: [SendOutcome] = []
        public var failed: [SendOutcome] = []
    }

    private let library: LibraryService
    private let sends: SendRegistry
    private let devices: DeviceRegistry

    public init(library: LibraryService, sends: SendRegistry, devices: DeviceRegistry) {
        self.library = library; self.sends = sends; self.devices = devices
    }

    public func run(destination: any SendDestination, items: [SendItem], vault: Vault,
                    progress: (@Sendable (SendProgress) -> Void)? = nil) async -> Result {
        var result = Result()

        // 1. Remember the device (friendly name + last-seen).
        devices.upsert(key: destination.destinationKey, name: destination.displayName,
                       kind: destination.deviceKind.rawValue, at: ISO8601Millis.string(from: Date()))

        // 2. Live dedup against what's currently on the target.
        let present = (try? await destination.enumeratePresent()) ?? []
        var toSend: [SendItem] = []
        for item in items {
            if isPresent(item, in: present) {
                result.alreadyPresent.append(SendOutcome(item: item, status: .alreadyPresent))
            } else {
                toSend.append(item)
            }
        }

        // Timestamp the send start (distinct from confirmation — matters for AirDrop).
        let startedAt = ISO8601Millis.string(from: Date())

        // 3. Send the remainder.
        let outcomes: [SendOutcome]
        if toSend.isEmpty {
            outcomes = []
        } else {
            outcomes = (try? await destination.send(toSend, progress: { progress?($0) }))
                ?? toSend.map { SendOutcome(item: $0, status: .failed, error: "send failed") }
        }

        // 4. Record confirmed sends; bucket the rest.
        let now = ISO8601Millis.string(from: Date())
        for o in outcomes {
            switch o.status {
            case .confirmed:
                try? sends.append(.init(
                    hash: o.item.hash, destinationKey: destination.destinationKey,
                    deviceName: destination.displayName, deviceKind: destination.deviceKind.rawValue,
                    sentAt: startedAt, confirmedAt: now,
                    fpSize: o.item.fingerprint.size, fpCaptureDateMs: o.item.fingerprint.captureDateMs))
                result.confirmed.append(o)
            case .unconfirmed: result.unconfirmed.append(o)
            case .failed: result.failed.append(o)
            case .alreadyPresent: result.alreadyPresent.append(o)
            }
        }

        // 5. Journal.
        library.appendSyncLog(vault: vault, event: "send",
            summary: "\(result.confirmed.count) sent, \(result.alreadyPresent.count) already there, " +
                     "\(result.unconfirmed.count) unconfirmed, \(result.failed.count) failed → \(destination.displayName)",
            counterpartyKey: destination.destinationKey)
        return result
    }

    /// Two-layer dedup: authoritative content hash when the target exposes it
    /// (volumes), else the size+capture-second fingerprint (phones).
    private func isPresent(_ item: SendItem, in present: [PresenceFingerprint]) -> Bool {
        present.contains { p in
            if let ph = p.hash { return ph == item.hash }
            return p.looselyMatches(item.fingerprint)
        }
    }
}
