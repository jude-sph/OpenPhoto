import Foundation

/// Reads/writes sidecars at their format-v1 §5 location, atomically.
public struct SidecarStore: Sendable {
    let vault: Vault
    public init(vault: Vault) { self.vault = vault }

    public func read(forMediaRelPath rel: String) throws -> SidecarData {
        let url = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel))
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try XMP.parse(try Data(contentsOf: url))
    }

    public func write(_ data: SidecarData, forMediaRelPath rel: String) throws {
        let url = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel))
        try AtomicFile.write(Data(XMP.serialize(data).utf8), to: url)
    }
}
