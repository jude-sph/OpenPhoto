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

    // Stub — fully implemented in Task 4. No `progress:` param yet so this compiles now.
    public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume) async -> SyncResult {
        SyncResult()
    }
}
