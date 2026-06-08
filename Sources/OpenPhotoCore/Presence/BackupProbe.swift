import Foundation

/// Stage-A presence signal: is a given asset known to exist anywhere but this
/// Mac? Derived purely from the import registry (`imports.jsonl`). Stage C
/// replaces this with a full PresenceService (drives, sends, reconciliation).
public struct BackupProbe: Sendable {
    private let registry: ImportRegistry
    public init(registry: ImportRegistry) { self.registry = registry }

    /// Device source-keys this asset is known to have lived on.
    public func knownDeviceKeys(forHash hash: String) -> Set<String> {
        registry.deviceKeys(forHash: hash)
    }

    /// True when OpenPhoto has no record of this asset anywhere but this Mac.
    public func isOnlyOnThisMac(hash: String) -> Bool {
        knownDeviceKeys(forHash: hash).isEmpty
    }

    /// Subset of `hashes` that appear to exist only on this Mac.
    public func onlyOnThisMac(hashes: [String]) -> [String] {
        hashes.filter(isOnlyOnThisMac)
    }
}
