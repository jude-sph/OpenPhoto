import AppKit
import OpenPhotoCore

/// Sends library photos to a connected iPhone via AirDrop, then confirms each by
/// re-enumerating the device over USB (size+date fingerprint — proven byte-stable
/// by the round-trip spike). The cable is used only for identity + verification;
/// AirDrop is the transport. Thin + hardware-validated (not unit-tested).
final class AirDropDestination: SendDestination, @unchecked Sendable {
    let destinationKey: String
    let displayName: String
    let deviceKind: DeviceKind = .phone
    private let camera: CameraSource

    init(camera: CameraSource) {
        // The CameraSource is owned and lifecycle-managed by DeviceWatcher, which
        // closes the ICC session on unplug/quit. We reuse that shared session and
        // never close it here; open() is idempotent. (Do NOT add a close() here —
        // it would tear down a session the import flow also uses.)
        self.camera = camera
        self.destinationKey = camera.sourceKey      // same keyspace as imports (cam-<serial>)
        self.displayName = camera.displayName
    }

    /// Current contents of the iPhone as size+date fingerprints (no hash — can't
    /// cheaply hash device files). Opens the session if needed.
    func enumeratePresent() async throws -> [PresenceFingerprint] {
        try await camera.open()
        let items = try await camera.enumerateItems()
        return items.map {
            PresenceFingerprint(
                size: $0.byteSize,
                captureDateMs: $0.takenAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
                hash: nil)
        }
    }

    /// Present the macOS AirDrop sheet for the originals, then poll the device
    /// until each item's fingerprint appears (confirmed) or a timeout (unconfirmed).
    func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome] {
        let urls = items.map(\.originalURL)
        // Present the AirDrop sheet on the main actor. If the service is unavailable
        // (e.g. AirDrop/Bluetooth off), fail fast rather than polling the full
        // timeout against a send that never happened.
        let presented = await MainActor.run { () -> Bool in
            guard let svc = NSSharingService(named: .sendViaAirDrop) else { return false }
            svc.perform(withItems: urls)
            return true
        }
        guard presented else {
            return items.map { SendOutcome(item: $0, status: .failed, error: "AirDrop unavailable") }
        }
        progress(SendProgress(stage: .verifying, done: 0, total: items.count, currentName: ""))

        var confirmed = Set<Int>()
        // Poll until each item lands or we give up. Each tick re-enumerates the
        // device (ICC), which can itself take up to ~6s to settle, so worst-case
        // wall-clock is roughly 30 × (2s + enumerate); typically much faster once
        // the session is already open.
        for _ in 0..<30 {
            if confirmed.count == items.count { break }
            try? await Task.sleep(for: .seconds(2))
            let present = (try? await enumeratePresent()) ?? []
            for (i, item) in items.enumerated() where !confirmed.contains(i) {
                if present.contains(where: { $0.looselyMatches(item.fingerprint) }) {
                    confirmed.insert(i)
                }
            }
            progress(SendProgress(stage: .verifying, done: confirmed.count,
                                  total: items.count, currentName: ""))
        }
        return items.enumerated().map { i, item in
            SendOutcome(item: item, status: confirmed.contains(i) ? .confirmed : .unconfirmed)
        }
    }
}
