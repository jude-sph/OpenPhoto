import Foundation
@testable import OpenPhotoCore

/// Scriptable SendDestination for engine tests. `present` is returned by
/// enumeratePresent(); `outcomeFor` decides each item's send status (default confirmed).
final class FakeSendDestination: SendDestination, @unchecked Sendable {
    let destinationKey: String
    let displayName: String
    let deviceKind: DeviceKind
    var present: [PresenceFingerprint]
    var outcomeFor: (SendItem) -> SendOutcome.Status
    private(set) var sentItems: [SendItem] = []

    init(key: String = "vol-FAKE", name: String = "Fake", kind: DeviceKind = .volume,
         present: [PresenceFingerprint] = [],
         outcomeFor: @escaping (SendItem) -> SendOutcome.Status = { _ in .confirmed }) {
        self.destinationKey = key; self.displayName = name; self.deviceKind = kind
        self.present = present; self.outcomeFor = outcomeFor
    }
    func enumeratePresent() async throws -> [PresenceFingerprint] { present }
    func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome] {
        sentItems = items
        return items.map { SendOutcome(item: $0, status: outcomeFor($0), error: nil) }
    }
}
