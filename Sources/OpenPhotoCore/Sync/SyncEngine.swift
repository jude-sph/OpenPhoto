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

    /// Plan a canonical→backup mirror: diff the source drive's manifest against the destination's,
    /// queueing every source file (and sidecar) missing from the destination, IDENTITY-mapped
    /// (destRelPath == source manifest path — the source drive's paths are already in drive layout,
    /// so there is no root-basename re-prefix). Additive: a destination path with the same hash is
    /// skipped; with a different hash (or unreadable) it is a conflict, never overwritten.
    public func planClone(source: Vault, destinationVault dest: Vault) throws -> SyncPlan {
        let fm = FileManager.default
        let destEntries = try Manifest.read(from: dest.manifestURL)
        var destByPath: [String: String] = [:]
        for e in destEntries { destByPath[e.path] = e.hash.stringValue }

        var plan = SyncPlan()
        for e in try Manifest.read(from: source.manifestURL) {
            let path = e.path                                   // identity map — a mirror
            let srcURL = source.absoluteURL(forRelativePath: path)
            let destURL = dest.rootURL.appendingPathComponent(path)

            if let known = destByPath[path] {
                if known != e.hash.stringValue {
                    plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                   destRelPath: path, size: e.size))
                } // same hash → already present, skip
            } else if fm.fileExists(atPath: destURL.path) {
                let onDisk = try? ContentHash.ofFile(at: destURL).stringValue
                if onDisk != e.hash.stringValue {
                    plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                   destRelPath: path, size: e.size))
                }
            } else {
                plan.copies.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                            destRelPath: path, size: e.size))
                plan.totalCopyBytes += e.size
            }

            // Sidecar: mirror identically (source drive's sidecar lives at <dir>/.openphoto/<file>.xmp).
            let dir = (path as NSString).deletingLastPathComponent
            let fileName = (path as NSString).lastPathComponent
            let sidecarRel = dir.isEmpty ? ".openphoto/\(fileName).xmp"
                                         : "\(dir)/.openphoto/\(fileName).xmp"
            let srcSidecar = source.rootURL.appendingPathComponent(sidecarRel)
            guard fm.fileExists(atPath: srcSidecar.path),
                  let srcData = try? Data(contentsOf: srcSidecar), !srcData.isEmpty else { continue }
            let destSidecar = dest.rootURL.appendingPathComponent(sidecarRel)
            if (try? Data(contentsOf: destSidecar)) != srcData {
                plan.sidecarUpdates.append(PlanItem(hash: "", sourceURL: srcSidecar,
                                                    destRelPath: sidecarRel, size: Int64(srcData.count)))
            }
        }
        return plan
    }

    public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                      event: String = "sync", counterpartyVaultID: String? = nil,
                      shouldCancel: (@Sendable () -> Bool)? = nil,
                      progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()
        for item in plan.conflicts { result.failed.append(FailedItem(item: item, reason: .conflict)) }

        if let free = try? volume.freeSpaceBytes(), free < plan.totalCopyBytes {
            result.failed.append(contentsOf: plan.copies.map { FailedItem(item: $0, reason: .copyFailed) })
            return result
        }

        var verified: [String: ManifestEntry] = [:]
        if let prior = try? Manifest.read(from: drive.manifestURL) {
            for e in prior where fm.fileExists(atPath: drive.rootURL.appendingPathComponent(e.path).path) {
                verified[e.path] = e
            }
        }

        let total = plan.copies.count
        let bytesTotal = plan.totalCopyBytes
        var bytesDone: Int64 = 0
        for (i, item) in plan.copies.enumerated() {
            if shouldCancel?() == true { result.cancelled = true; break }
            let name = (item.destRelPath as NSString).lastPathComponent
            let base = bytesDone
            progress?(SyncProgress(stage: .copying, done: i, total: total,
                                   bytesDone: base, bytesTotal: bytesTotal, currentName: name))
            let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
            do {
                if fm.fileExists(atPath: destURL.path) {
                    let onDisk = try ContentHash.ofFile(at: destURL).stringValue
                    if onDisk == item.hash {
                        verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                        result.skipped += 1; bytesDone += item.size; continue
                    } else {
                        result.failed.append(FailedItem(item: item, reason: .conflict)); continue
                    }
                }
                let outcome = VerifiedCopy.copy(
                    from: item.sourceURL, to: destURL, expectedHash: item.hash,
                    onBytes: { fileBytes in
                        progress?(SyncProgress(stage: .copying, done: i, total: total,
                                               bytesDone: base + fileBytes, bytesTotal: bytesTotal,
                                               currentName: name))
                    },
                    shouldCancel: { shouldCancel?() == true })
                switch outcome {
                case .copied:
                    verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                    result.copied += 1; bytesDone += item.size
                case .cancelled:
                    result.cancelled = true
                case .failed(let reason):
                    result.failed.append(FailedItem(item: item, reason: reason))
                }
                if result.cancelled { break }
            } catch {
                result.failed.append(FailedItem(item: item, reason: .copyFailed))
            }
        }

        if !result.cancelled {
            for item in plan.sidecarUpdates {
                let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
                do {
                    try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AtomicFile.write(try Data(contentsOf: item.sourceURL), to: destURL)
                    result.sidecarsWritten += 1
                } catch { result.failed.append(FailedItem(item: item, reason: .copyFailed)) }
            }
        }

        progress?(SyncProgress(stage: .finishing, done: total, total: total,
                               bytesDone: bytesDone, bytesTotal: bytesTotal, currentName: ""))
        try? Manifest.write(verified.values.sorted { $0.path < $1.path }, to: drive.manifestURL)

        let summary = "\(result.copied) copied, \(result.skipped) skipped, " +
                      "\(result.sidecarsWritten) sidecars, \(result.conflicts) conflicts, " +
                      "\(result.retryableFailures.count) failed" + (result.cancelled ? ", cancelled" : "")
        if event == "sync" {
            library.appendSyncLog(vault: drive, event: "sync", summary: summary,
                                  counterpartyKey: library.vaults.first?.descriptor.vaultID ?? "")
            if let mac = library.vaults.first {
                library.appendSyncLog(vault: mac, event: "sync", summary: summary,
                                      counterpartyKey: drive.descriptor.vaultID)
            }
        } else {
            library.appendSyncLog(vault: drive, event: event, summary: summary,
                                  counterpartyKey: counterpartyVaultID ?? "")
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
