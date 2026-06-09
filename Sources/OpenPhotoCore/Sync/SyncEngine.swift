import Foundation

public struct SyncEngine: Sendable {
    private let library: LibraryService
    public init(library: LibraryService) { self.library = library }

    /// Drive-relative path for a source asset: "<sourceRootBasename>/<relPath>", NFC.
    static func driveRelPath(forSourceVault v: Vault, relPath: String) -> String {
        (v.rootURL.lastPathComponent + "/" + relPath).precomposedStringWithCanonicalMapping
    }

    // MARK: Plan (zero writes)

    public func plan(sources: [Vault], destinationVault drive: Vault) throws -> SyncPlan {
        let fm = FileManager.default
        let driveEntries = try Manifest.read(from: drive.manifestURL)
        var driveByPath: [String: String] = [:]
        for e in driveEntries { driveByPath[e.path] = e.hash.stringValue }

        var plan = SyncPlan()
        for v in sources {
            let entries = try Manifest.read(from: v.manifestURL)
            for e in entries {
                let dest = Self.driveRelPath(forSourceVault: v, relPath: e.path)
                let srcURL = v.absoluteURL(forRelativePath: e.path)
                let destURL = drive.rootURL.appendingPathComponent(dest)

                if let known = driveByPath[dest] {
                    if known != e.hash.stringValue {
                        plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                       destRelPath: dest, size: e.size))
                    } // else already present → skip (counted at apply)
                } else if fm.fileExists(atPath: destURL.path) {
                    // Unreadable dest (nil) or a hash mismatch is treated conservatively as a
                    // conflict — never overwritten. (Distinguishing the two needs a reason field,
                    // out of scope for Slice 1.)
                    let onDisk = try? ContentHash.ofFile(at: destURL).stringValue
                    if onDisk != e.hash.stringValue {
                        plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                       destRelPath: dest, size: e.size))
                    }
                } else {
                    plan.copies.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                destRelPath: dest, size: e.size))
                    plan.totalCopyBytes += e.size
                }

                // Sidecar: mirror if present and missing/different on the drive.
                let srcSidecar = v.sidecarURL(forMediaAt: srcURL)
                guard fm.fileExists(atPath: srcSidecar.path) else { continue }
                let dir = (e.path as NSString).deletingLastPathComponent
                let fileName = (e.path as NSString).lastPathComponent
                let sidecarSrcRel = dir.isEmpty ? ".openphoto/\(fileName).xmp"
                                                : "\(dir)/.openphoto/\(fileName).xmp"
                let destSidecarRel = Self.driveRelPath(forSourceVault: v, relPath: sidecarSrcRel)
                let destSidecar = drive.rootURL.appendingPathComponent(destSidecarRel)
                // Skip unreadable/empty source sidecars rather than queueing a bogus 0-byte update.
                guard let srcData = try? Data(contentsOf: srcSidecar), !srcData.isEmpty else { continue }
                let destData = try? Data(contentsOf: destSidecar)
                if destData != srcData {
                    plan.sidecarUpdates.append(PlanItem(hash: "", sourceURL: srcSidecar,
                        destRelPath: destSidecarRel, size: Int64(srcData.count)))
                }
            }
        }
        return plan
    }

    public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                      progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()
        result.conflicts = plan.conflicts.count

        // Free-space guard — never start a copy that will ENOSPC.
        if let free = try? volume.freeSpaceBytes(), free < plan.totalCopyBytes {
            result.failed = plan.copies
            return result
        }

        // Verified entries for the manifest (path -> ManifestEntry); seed with prior entries
        // whose files still exist (additive).
        var verified: [String: ManifestEntry] = [:]
        if let prior = try? Manifest.read(from: drive.manifestURL) {
            for e in prior where fm.fileExists(
                atPath: drive.rootURL.appendingPathComponent(e.path).path) {
                verified[e.path] = e
            }
        }

        let total = plan.copies.count
        for (i, item) in plan.copies.enumerated() {
            progress?(SyncProgress(stage: .copying, done: i, total: total,
                                   currentName: (item.destRelPath as NSString).lastPathComponent))
            let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
            do {
                // Resume pre-check: a file already at dest?
                if fm.fileExists(atPath: destURL.path) {
                    let onDisk = try ContentHash.ofFile(at: destURL).stringValue
                    if onDisk == item.hash {
                        verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                        result.skipped += 1; continue
                    } else {
                        result.failed.append(item); result.conflicts += 1; continue // never overwrite
                    }
                }
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                let tmp = destURL.deletingLastPathComponent()
                    .appendingPathComponent(".tmp-" + UUID().uuidString)
                defer { try? fm.removeItem(at: tmp) }  // no-op once moved into place
                try fm.copyItem(at: item.sourceURL, to: tmp)
                if let fh = try? FileHandle(forUpdating: tmp) {
                    _ = try? fh.synchronize(); try? fh.close()
                }
                let writtenHash = try ContentHash.ofFile(at: tmp).stringValue
                guard writtenHash == item.hash else { result.failed.append(item); continue }
                try fm.moveItem(at: tmp, to: destURL)  // atomic rename; dest is guaranteed absent here
                verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                result.copied += 1
            } catch {
                // Do NOT delete destURL here. copyItem only ever writes to `tmp` (cleaned by the
                // defer) and moveItem is atomic, so destURL is never a partial we own — it is either
                // absent, a pre-existing file, or an already-verified file. Deleting it would erase
                // good data (violating the never-hard-delete invariant). Just record the failure;
                // the next reconcile heals any file that landed but missed the manifest.
                result.failed.append(item)
            }
        }

        // Sidecars (no hash gate; not listed in the manifest).
        for item in plan.sidecarUpdates {
            let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
            do {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try AtomicFile.write(try Data(contentsOf: item.sourceURL), to: destURL)
                result.sidecarsWritten += 1
            } catch { result.failed.append(item) }
        }

        // Atomic manifest rewrite.
        progress?(SyncProgress(stage: .finishing, done: total, total: total, currentName: ""))
        try? Manifest.write(verified.values.sorted { $0.path < $1.path }, to: drive.manifestURL)

        // Sync-log on both ends.
        let summary = "\(result.copied) copied, \(result.skipped) skipped, " +
                      "\(result.sidecarsWritten) sidecars, \(result.conflicts) conflicts, " +
                      "\(result.failed.count) failed"
        library.appendSyncLog(vault: drive, event: "sync", summary: summary,
                              counterpartyKey: library.vaults.first?.descriptor.vaultID ?? "")
        if let mac = library.vaults.first {
            library.appendSyncLog(vault: mac, event: "sync", summary: summary,
                                  counterpartyKey: drive.descriptor.vaultID)
        }
        return result
    }

    static func manifestEntry(for item: PlanItem, at url: URL) throws -> ManifestEntry {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mDate = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return ManifestEntry(hash: ContentHash(stringValue: item.hash), path: item.destRelPath,
                             size: item.size, mtime: ISO8601Millis.string(from: mDate))
    }
}
