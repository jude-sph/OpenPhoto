import Foundation

/// One known location of an asset, with how sure we are and when we last knew.
public struct Location: Sendable, Equatable, Identifiable {
    public enum Place: Sendable, Equatable {
        case thisMac
        case device(key: String, name: String, kind: DeviceKind)
    }
    /// confirmed = present right here / seen on connect; believed = we sent it and
    /// verified it landed but haven't re-checked since; historical = it was once on
    /// a device (e.g. imported from) — may be gone now.
    public enum Confidence: String, Sendable { case confirmed, believed, historical }
    public let place: Place
    public let confidence: Confidence
    public let detail: String
    public init(place: Place, confidence: Confidence, detail: String) {
        self.place = place; self.confidence = confidence; self.detail = detail
    }
    public var id: String {
        switch place {
        case .thisMac: return "mac"
        case .device(let key, _, _): return "dev:\(key):\(confidence.rawValue)"
        }
    }
}

/// Catalog-derived "where is this photo?" view (spec §4.7). Rebuildable; reads the
/// catalog + the import/send/device registries. Supersedes Stage A's BackupProbe
/// for the eviction only-copy judgment.
public struct PresenceService: Sendable {
    private let catalog: Catalog
    private let imports: ImportRegistry
    private let sends: SendRegistry
    private let devices: DeviceRegistry

    public init(catalog: Catalog, imports: ImportRegistry, sends: SendRegistry, devices: DeviceRegistry) {
        self.catalog = catalog; self.imports = imports; self.sends = sends; self.devices = devices
    }

    /// All known locations of an asset, This-Mac first, then sent-to, then came-from.
    public func locations(forHash hash: String) -> [Location] {
        var out: [Location] = []
        var seenDevices = Set<String>()

        // This Mac (confirmed) — from the catalog.
        if let instances = try? catalog.instances(forHash: hash), !instances.isEmpty {
            let folders = Set(instances.map { $0.dirPath.isEmpty ? "(root)" : $0.dirPath })
            out.append(Location(place: .thisMac, confidence: .confirmed,
                                detail: folders.sorted().joined(separator: ", ")))
        }

        // Registered drive vaults (confirmed) — presence derived from their manifests.
        if let vaults = try? catalog.registeredVaults() {
            for vr in vaults where vr.role != "local" {
                guard let present = try? catalog.vaultPresenceHashes(forVault: vr.id),
                      present.contains(hash), !seenDevices.contains(vr.id) else { continue }
                seenDevices.insert(vr.id)
                let name = (vr.rootPath as NSString).lastPathComponent
                out.append(Location(place: .device(key: vr.id, name: name, kind: .volume),
                                    confidence: .confirmed, detail: vr.role))
            }
        }

        // Sent to devices (believed) — confirmed at send time, not re-checked since.
        for e in sends.entries(forHash: hash) where !seenDevices.contains(e.destinationKey) {
            seenDevices.insert(e.destinationKey)
            let name = devices.name(forKey: e.destinationKey) ?? e.deviceName
            out.append(Location(place: .device(key: e.destinationKey, name: name,
                                               kind: DeviceKind(rawValue: e.deviceKind) ?? kind(forKey: e.destinationKey)),
                                confidence: .believed, detail: "sent " + day(e.confirmedAt)))
        }

        // Imported from devices (historical) — may be gone now.
        for e in imports.entries(forHash: hash) where !seenDevices.contains(e.sourceKey) {
            seenDevices.insert(e.sourceKey)
            let name = devices.name(forKey: e.sourceKey) ?? e.sourceKey
            out.append(Location(place: .device(key: e.sourceKey, name: name, kind: kind(forKey: e.sourceKey)),
                                confidence: .historical, detail: "imported " + day(e.importedAt)))
        }
        return out
    }

    /// True when no copy is known on any device with confidence confirmed/believed
    /// (historical "came from" doesn't count — that card may have been wiped).
    public func isOnlyOnThisMac(hash: String) -> Bool {
        // Drives surface as `.confirmed` device locations in locations(), so this single
        // check already accounts for canonical/backup presence — no separate vault walk needed.
        !locations(forHash: hash).contains { loc in
            if case .device = loc.place { return loc.confidence == .confirmed || loc.confidence == .believed }
            return false
        }
    }

    /// Subset of `hashes` that appear to exist only on this Mac.
    public func onlyOnThisMac(hashes: [String]) -> [String] {
        var seen = Set<String>()
        return hashes.filter { seen.insert($0).inserted }.filter(isOnlyOnThisMac)
    }

    private func kind(forKey key: String) -> DeviceKind { key.hasPrefix("cam-") ? .phone : .volume }
    private func day(_ iso: String) -> String { String(iso.prefix(10)) }   // YYYY-MM-DD
}
