import Foundation

public struct DriftReconciler: Sendable {
    public init() {}

    /// Enumerate the drive's media files (rel → (size, mtimeString)), mirroring Scanner's walk.
    static func walk(_ drive: Vault) -> [String: (size: Int64?, mtime: String)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var out: [String: (size: Int64?, mtime: String)] = [:]
        guard let en = fm.enumerator(at: drive.rootURL, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if url.lastPathComponent == Vault.stateDirName { en.skipDescendants() }
                continue
            }
            guard MediaKind.of(filename: url.lastPathComponent) != nil else { continue }
            out[drive.relativePath(of: url)] = (v.fileSize.map(Int64.init),
                ISO8601Millis.string(from: v.contentModificationDate ?? Date()))
        }
        return out
    }

    /// Fast drift scan — existence + size + mtime vs the manifest. No hashing.
    public func scan(drive: Vault) throws -> DriftReport {
        let manifest = try Manifest.read(from: drive.manifestURL)
        let onDisk = Self.walk(drive)
        let manifestPaths = Set(manifest.map(\.path))

        var report = DriftReport()
        for e in manifest {
            if let d = onDisk[e.path] {
                if let s = d.size, s == e.size, d.mtime == e.mtime {
                    report.presentHashes.insert(e.hash.stringValue)
                } else {
                    report.changed.append(DriftFinding(kind: .changed, relPath: e.path,
                        recordedHash: e.hash.stringValue, recordedSize: e.size, onDiskSize: d.size))
                }
            } else {
                report.missing.append(DriftFinding(kind: .missing, relPath: e.path,
                    recordedHash: e.hash.stringValue, recordedSize: e.size))
            }
        }
        for (rel, d) in onDisk where !manifestPaths.contains(rel) {
            report.unknown.append(DriftFinding(kind: .unknown, relPath: rel, onDiskSize: d.size))
        }
        // Stable order for deterministic UI/tests.
        report.missing.sort { $0.relPath < $1.relPath }
        report.unknown.sort { $0.relPath < $1.relPath }
        report.changed.sort { $0.relPath < $1.relPath }
        return report
    }
}
