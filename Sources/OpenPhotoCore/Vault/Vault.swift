import Foundation

/// A self-describing library location — vault-format-v1 §1.
public struct Vault: Sendable {
    public let rootURL: URL
    public let descriptor: VaultDescriptor

    public static let stateDirName = ".openphoto"

    public var stateDirURL: URL { rootURL.appendingPathComponent(Self.stateDirName) }
    public var manifestURL: URL { stateDirURL.appendingPathComponent("manifest.jsonl") }
    public var syncLogURL: URL { stateDirURL.appendingPathComponent("sync-log.jsonl") }
    public var binDirURL: URL { stateDirURL.appendingPathComponent("bin") }
    public var binLogURL: URL { stateDirURL.appendingPathComponent("bin.jsonl") }

    /// rome2022/IMG_1.heic → rome2022/.openphoto/IMG_1.heic.xmp  (format §5)
    public func sidecarURL(forMediaAt media: URL) -> URL {
        media.deletingLastPathComponent()
            .appendingPathComponent(Self.stateDirName)
            .appendingPathComponent(media.lastPathComponent + ".xmp")
    }

    /// Vault-root-relative path with "/" separators, NFC-normalized (format §4).
    public func relativePath(of url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        let rel = p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : p
        return rel.precomposedStringWithCanonicalMapping
    }

    public func absoluteURL(forRelativePath rel: String) -> URL {
        rootURL.appendingPathComponent(rel)
    }

    public static func openOrCreate(at root: URL, role: VaultRole) throws -> Vault {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw VaultError.notADirectory(root.path)
        }
        let vjson = root.appendingPathComponent(stateDirName).appendingPathComponent("vault.json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: vjson) {
            let desc = try decoder.decode(VaultDescriptor.self, from: data)
            guard desc.formatVersion <= VaultDescriptor.currentFormatVersion else {
                throw VaultError.unsupportedFormatVersion(desc.formatVersion)
            }
            return Vault(rootURL: root, descriptor: desc)
        }
        let desc = VaultDescriptor.new(role: role)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(desc), to: vjson)
        return Vault(rootURL: root, descriptor: desc)
    }
}
