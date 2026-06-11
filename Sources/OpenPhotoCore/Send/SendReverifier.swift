import Foundation

/// The reconciliation verdict for one previously-sent asset on a now-connected device.
public enum ReverifyVerdict: String, Sendable, Equatable {
    case present   // still on the device (re-enumeration found a fingerprint/hash match)
    case gone      // we confirmed sending it but it's no longer on the device
}

/// Pure reconciler: given a device's confirmed-send entries (from sends.jsonl) and that device's
/// CURRENT read-only listing (SendDestination.enumeratePresent()), decide present/gone per entry.
/// No I/O, no ImageCaptureCore, no FileManager — the unit-tested heart. The live enumeration + the
/// connect hook are the App's job (untestable without hardware); this classification is fully
/// synthetic-testable.
public struct SendReverifier: Sendable {
    public init() {}

    /// - Parameters:
    ///   - entries: sends.jsonl entries for one destinationKey (SendRegistry.entries(forDestinationKey:)).
    ///   - present: the device's current contents (SendDestination.enumeratePresent()).
    /// - Returns: verdict per entry, keyed by `entry.hash`. Two-layer match (identical to
    ///   SendEngine.isPresent): a present fingerprint's authoritative `hash` (volumes) is matched
    ///   first; else the size + capture-SECOND fingerprint (phones) via PresenceFingerprint.looselyMatches.
    public func reconcile(entries: [SendRegistry.Entry],
                          present: [PresenceFingerprint]) -> [String: ReverifyVerdict] {
        var out: [String: ReverifyVerdict] = [:]
        for e in entries {
            let entryFP = PresenceFingerprint(size: e.fpSize, captureDateMs: e.fpCaptureDateMs, hash: nil)
            let isPresent = present.contains { p in
                if let ph = p.hash { return ph == e.hash }   // authoritative content hash (volumes)
                return p.looselyMatches(entryFP)             // size + capture-second (phones)
            }
            out[e.hash] = isPresent ? .present : .gone
        }
        return out
    }
}
