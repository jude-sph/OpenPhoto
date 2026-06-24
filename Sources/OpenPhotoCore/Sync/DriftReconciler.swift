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

    /// Is `hash` restorable from somewhere other than `excludingVault`?
    public func recoverability(forHash hash: String, excludingVault driveID: String,
                               presence: PresenceService) -> Recoverability {
        for loc in presence.locations(forHash: hash) where loc.confidence == .confirmed {
            switch loc.place {
            case .thisMac: return .recoverable(source: "This Mac")
            case .device(let key, let name, _): if key != driveID { return .recoverable(source: name) }
            }
        }
        return .lostNoCopy
    }

    /// Fill in `recoverability` on every missing/changed/corrupt finding in `report`.
    public func annotateRecoverability(_ report: inout DriftReport, driveID: String,
                                       presence: PresenceService) {
        func annotate(_ list: inout [DriftFinding]) {
            list = list.map { f in
                guard let h = f.recordedHash else { return f }
                var c = f
                c.recoverability = recoverability(forHash: h, excludingVault: driveID, presence: presence)
                return c
            }
        }
        annotate(&report.missing); annotate(&report.changed); annotate(&report.corrupt)
    }

    /// Add an on-disk file to the manifest (its content is recorded as authoritative). Returns the hash.
    @discardableResult
    public func adopt(relPath: String, on drive: Vault) throws -> String {
        let url = drive.absoluteURL(forRelativePath: relPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DriftError.notOnDisk }
        let hash = try ContentHash.ofFile(at: url).stringValue
        try writeManifestEntry(hash: hash, relPath: relPath, fileURL: url, on: drive)
        return hash
    }

    /// Copy a verified-good copy back into a missing slot, then record it. Never overwrites.
    public func restore(relPath: String, expectedHash: String, from source: URL, on drive: Vault) throws {
        let dest = drive.absoluteURL(forRelativePath: relPath)
        guard VerifiedCopy.copy(from: source, to: dest, expectedHash: expectedHash) == .copied else {
            throw DriftError.restoreFailed
        }
        try writeManifestEntry(hash: expectedHash, relPath: relPath, fileURL: dest, on: drive)
    }

    /// Repair a corrupt (bit-rot) file from a verified-good `source`. Bin-then-replace ordering:
    /// stage + verify a copy to a temp on the drive FIRST, so a rotten/short source throws before
    /// anything is binned; then quarantine the rotten original to the drive bin (origin .repaired,
    /// sidecar kept in place), atomically place the verified file, and re-record its size/mtime
    /// (hash unchanged). Never overwrites: the placement target is absent after binning.
    public func repairCorrupt(relPath: String, expectedHash: String, from source: URL,
                              on drive: Vault) throws {
        let fm = FileManager.default
        let dest = drive.absoluteURL(forRelativePath: relPath)
        let tmp = drive.stateDirURL.appendingPathComponent("repair-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        // 1. Stage + verify a good copy. A rotten/short source fails here — nothing is binned.
        guard VerifiedCopy.copy(from: source, to: tmp, expectedHash: expectedHash) == .copied else {
            throw DriftError.restoreFailed
        }
        // 2. Quarantine the rotten original (recoverable; keep its sidecar at the live location).
        try BinStore(vault: drive).moveToBin(relPath: relPath,
            hash: ContentHash(stringValue: expectedHash), origin: .repaired, includeSidecar: false)
        // 3. Place the verified file (dest is now absent → atomic, same-volume rename).
        try fm.moveItem(at: tmp, to: dest)
        // 4. Re-record size/mtime to the placed file (hash stays `expectedHash`).
        try writeManifestEntry(hash: expectedHash, relPath: relPath, fileURL: dest, on: drive)
    }

    /// Drop an already-absent file from the manifest (records reality; deletes nothing).
    public func acknowledgeGone(relPath: String, on drive: Vault) throws {
        var entries = try Manifest.read(from: drive.manifestURL)
        entries.removeAll { $0.path == relPath }
        try Manifest.write(entries, to: drive.manifestURL)
    }

    /// Full integrity check — re-hash every file vs the manifest. Catches bit-rot (corrupt) on
    /// top of the fast findings. Slow; reports progress.
    public func verify(drive: Vault, progress: (DriftProgress) -> Void = { _ in }) throws -> DriftReport {
        let manifest = try Manifest.read(from: drive.manifestURL)
        let onDisk = Self.walk(drive)
        let manifestPaths = Set(manifest.map(\.path))

        var report = DriftReport()
        report.verified = true
        let total = manifest.count
        for (i, e) in manifest.enumerated() {
            progress(DriftProgress(done: i, total: total,
                                   currentName: (e.path as NSString).lastPathComponent))
            guard onDisk[e.path] != nil else {
                report.missing.append(DriftFinding(kind: .missing, relPath: e.path,
                    recordedHash: e.hash.stringValue, recordedSize: e.size)); continue
            }
            let url = drive.absoluteURL(forRelativePath: e.path)
            let actual = (try? ContentHash.ofFile(at: url).stringValue) ?? ""
            if actual == e.hash.stringValue {
                report.presentHashes.insert(e.hash.stringValue)
            } else {
                let d = onDisk[e.path]!
                let sameSizeAndTime = (d.size == e.size) && (d.mtime == e.mtime)
                let kind: DriftFinding.Kind = sameSizeAndTime ? .corrupt : .changed
                let finding = DriftFinding(kind: kind, relPath: e.path, recordedHash: e.hash.stringValue,
                    onDiskHash: actual.isEmpty ? nil : actual, recordedSize: e.size, onDiskSize: d.size)
                if kind == .corrupt { report.corrupt.append(finding) } else { report.changed.append(finding) }
            }
        }
        for (rel, d) in onDisk where !manifestPaths.contains(rel) {
            report.unknown.append(DriftFinding(kind: .unknown, relPath: rel, onDiskSize: d.size))
        }
        report.missing.sort { $0.relPath < $1.relPath }
        report.unknown.sort { $0.relPath < $1.relPath }
        report.changed.sort { $0.relPath < $1.relPath }
        report.corrupt.sort { $0.relPath < $1.relPath }
        return report
    }

    private func writeManifestEntry(hash: String, relPath: String, fileURL: URL, on drive: Vault) throws {
        let a = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let entry = ManifestEntry(hash: ContentHash(stringValue: hash), path: relPath,
            size: (a[.size] as? Int64) ?? 0,
            mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date()))
        var entries = try Manifest.read(from: drive.manifestURL)
        entries.removeAll { $0.path == relPath }   // replace any stale line for this path
        entries.append(entry)
        try Manifest.write(entries, to: drive.manifestURL)
    }
}
