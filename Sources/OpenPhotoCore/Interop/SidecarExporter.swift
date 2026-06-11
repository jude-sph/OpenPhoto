import Foundation

/// Export human-authored metadata as a portable mirror tree of standard XMP sidecars under `dest`,
/// for interop with Lightroom / other XMP tools. One-way; reads the hidden `.openphoto/` store, writes
/// only under `dest`, never touches the library. Naming: `dest/<relPath>.xmp` (append). Skips assets
/// with no human metadata. Returns the count written.
public enum SidecarExporter {
    @discardableResult
    public static func export(library: LibraryService, to dest: URL) throws -> Int {
        var count = 0
        for vault in library.vaults {
            let store = SidecarStore(vault: vault)
            for entry in try Manifest.read(from: vault.manifestURL) {
                let data = try store.read(forMediaRelPath: entry.path)
                guard data != .empty else { continue }
                try AtomicFile.write(Data(XMP.serialize(data).utf8),
                                     to: dest.appendingPathComponent(entry.path + ".xmp"))
                count += 1
            }
        }
        return count
    }
}
