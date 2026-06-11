import AppKit
import OpenPhotoCore

// Folder reorganization on the Folders view. Every structural op is applied to the Mac primary
// vault first (via the tested `VaultReorganizer`), then propagated to each *connected* durable
// drive, and *enqueued* (pending_folder_ops) for each *offline* durable drive so its structure is
// reconciled the next time it connects (see `applyPendingFolderOps`, wired into the connect path).
// Disk loops run off the @MainActor via `Task.detached`. Per the approved design this is a full
// auto-reconcile queue with NO user warning.
extension AppState {

    // MARK: - Drive relpath mapping

    // NOTE: A drive mirrors a Mac source vault by basename: a Mac relPath `r` lives on the drive at
    // `<sourceVaultBasename>/r` (NFC), and the drive's manifest paths use that prefixed form. This is
    // exactly `SyncEngine.driveRelPath(forSourceVault:relPath:)`, but that helper is `internal` to
    // OpenPhotoCore and not visible here, so we inline the identical formula against the primary
    // vault's basename. `DrivePathMap.driveToMacRelPath` (public) is its inverse.
    private func driveBasename() -> String? {
        library?.vaults.first?.rootURL.lastPathComponent
    }

    private func mapToDrive(_ relPath: String, basename: String) -> String {
        (basename + "/" + relPath).precomposedStringWithCanonicalMapping
    }

    /// Connected durable drives (canonical + backups) as open Vaults, paired with their vaultID.
    private func connectedDurableDrives() -> [(id: String, vault: Vault)] {
        durableVaults.filter { driveIsPresent($0) }
            .compactMap { vr in openVault(for: vr).map { (vr.id, $0) } }
    }

    /// Registered durable drives that are NOT currently connected (queue their ops).
    private func offlineDurableDriveIDs() -> [String] {
        durableVaults.filter { !driveIsPresent($0) }.map { $0.id }
    }

    /// True if the drive holds the folder for Mac relPath `src` on disk (so a move there is meaningful).
    private func driveHasFolder(_ vault: Vault, macRelPath: String, basename: String) -> Bool {
        let url = vault.absoluteURL(forRelativePath: mapToDrive(macRelPath, basename: basename))
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func parentRelPath(of relPath: String) -> String {
        (relPath as NSString).deletingLastPathComponent
    }

    // MARK: - Move

    /// Move folder `src` so it becomes a child of `parent` (empty `parent` == library root). Applies
    /// to the Mac primary vault, propagates to connected durable drives, queues offline drives, then
    /// rescans and remaps the UI (selection + expanded set) onto the new path.
    func moveFolder(from src: String, into parent: String) async {
        guard let library, let primaryVault = library.vaults.first else { return }

        let newPath: String
        do {
            newPath = try VaultReorganizer.moveFolder(in: primaryVault, relPath: src,
                                                      intoParentRelPath: parent)
        } catch {
            NSAlert(error: error).runModal()   // surface collision/invalid-target to the user
            return
        }

        // Propagate to connected durable drives whose copy of `src` actually exists (off-main).
        if let basename = driveBasename() {
            let drives = connectedDurableDrives().filter {
                driveHasFolder($0.vault, macRelPath: src, basename: basename)
            }
            if !drives.isEmpty {
                await Task.detached(priority: .userInitiated) {
                    for d in drives {
                        _ = try? VaultReorganizer.moveFolder(in: d.vault,
                            relPath: mapToDriveStatic(src, basename: basename),
                            intoParentRelPath: mapToDriveStatic(parent, basename: basename))
                    }
                }.value
            }
        }

        // Queue the move for offline drives (reconciled on their next connect).
        for driveID in offlineDurableDriveIDs() {
            _ = try? library.catalog.enqueueFolderOp(vaultID: driveID, op: "move", src: src, dst: newPath)
        }

        // Re-key cached drive presence onto the new path (every drive, connected or offline). The Mac
        // move + the connected-drive manifest rewrites above keep disk/manifests aligned, but the
        // drive-presence CACHE (vault_presence) is keyed by the Mac-aligned dirPath and isn't touched
        // by either. Without this, a folder holding drive-only originals (kept on a drive, freed from
        // the Mac) would still be counted under the old dirPath and re-appear as a phantom that errors
        // (`.missing`) if dragged again. Pure catalog op; must run BEFORE rescan rebuilds folderTree.
        try? library.catalog.rewriteVaultPresencePaths(fromDir: src, toDir: newPath)
        reloadCanonicalPresence()

        await rescan()
        remapUIPaths(from: src, to: newPath)
    }

    // MARK: - Create

    /// Create a new folder `name` under `parent` (nil/empty == library root). Applies to the Mac
    /// primary vault + connected durable drives, queues offline drives, then selects + expands it.
    func createFolder(named name: String, under parent: String?) async {
        guard let library, let primaryVault = library.vaults.first else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let relPath = (parent?.isEmpty == false) ? parent! + "/" + trimmed : trimmed

        do {
            try VaultReorganizer.createFolder(in: primaryVault, relPath: relPath)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        if let basename = driveBasename() {
            let drives = connectedDurableDrives()
            if !drives.isEmpty {
                await Task.detached(priority: .userInitiated) {
                    for d in drives {
                        try? VaultReorganizer.createFolder(in: d.vault,
                            relPath: mapToDriveStatic(relPath, basename: basename))
                    }
                }.value
            }
        }

        for driveID in offlineDurableDriveIDs() {
            _ = try? library.catalog.enqueueFolderOp(vaultID: driveID, op: "create", src: nil, dst: relPath)
        }

        // A create adds no assets, so the timeline/folder queries just need a refresh (no full
        // rescan): `folderTree()` unions in real filesystem dirs from the primary vault.
        try? refreshQueries()
        selectedFolder = relPath
        expandedFolders.insert(relPath)
        if let parent, !parent.isEmpty { expandedFolders.insert(parent) }
    }

    // MARK: - Delete

    /// Delete folder `path`: bin its media (recursively, via the existing `delete` path so pending
    /// deletions are queued for drive review), remove the now-empty folder on the Mac + connected
    /// durable drives, queue offline drives, then rescan.
    func deleteFolder(_ path: String) async {
        guard let library, let primaryVault = library.vaults.first, !path.isEmpty else { return }

        // Bin the media first (this also enqueues pending_deletions for drive propagation review).
        let items = (try? library.items(inDir: path, recursive: true)) ?? []
        if !items.isEmpty { await delete(items) }

        // Remove the (now-empty) folder on the Mac primary vault. `notEmpty` is ignored: a folder
        // still holding non-binned content (e.g. drive-only items) is intentionally left in place.
        try? VaultReorganizer.deleteEmptyFolder(in: primaryVault, relPath: path)

        if let basename = driveBasename() {
            let drives = connectedDurableDrives()
            if !drives.isEmpty {
                await Task.detached(priority: .userInitiated) {
                    for d in drives {
                        try? VaultReorganizer.deleteEmptyFolder(in: d.vault,
                            relPath: mapToDriveStatic(path, basename: basename))
                    }
                }.value
            }
        }

        for driveID in offlineDurableDriveIDs() {
            _ = try? library.catalog.enqueueFolderOp(vaultID: driveID, op: "delete", src: path, dst: nil)
        }

        await rescan()
        // If the deleted folder (or a descendant) was selected/expanded, drop it.
        if let sel = selectedFolder, sel == path || sel.hasPrefix(path + "/") { selectedFolder = nil }
        expandedFolders = expandedFolders.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    // MARK: - Apply queued ops on connect

    /// Reconcile a freshly-connected drive's folder structure by replaying its queued ops in `id`
    /// order, off-main. Each op is mapped onto the drive's prefixed relpaths and applied with the
    /// tested `VaultReorganizer`; on success the op is cleared. Wrapped in `try?` per-op so one
    /// failure (e.g. a folder a prior op already moved) doesn't block the rest.
    func applyPendingFolderOps(forDriveID driveID: String, driveVault: Vault) async {
        guard let library, let basename = driveBasename() else { return }
        let ops = (try? library.catalog.pendingFolderOps(forVault: driveID)) ?? []
        guard !ops.isEmpty else { return }

        let appliedIDs = await Task.detached(priority: .userInitiated) { () -> [Int64] in
            var done: [Int64] = []
            for op in ops {
                do {
                    switch op.op {
                    case "move":
                        guard let src = op.src, let dst = op.dst else { continue }
                        try VaultReorganizer.moveFolder(in: driveVault,
                            relPath: mapToDriveStatic(src, basename: basename),
                            intoParentRelPath: mapToDriveStatic(parentOf(dst), basename: basename))
                    case "create":
                        guard let dst = op.dst else { continue }
                        try VaultReorganizer.createFolder(in: driveVault,
                            relPath: mapToDriveStatic(dst, basename: basename))
                    case "delete":
                        guard let src = op.src else { continue }
                        do {
                            try VaultReorganizer.deleteEmptyFolder(in: driveVault,
                                relPath: mapToDriveStatic(src, basename: basename))
                        } catch VaultReorganizer.ReorgError.notEmpty {
                            // Folder still holds content on this drive — leave it, but consider the
                            // op handled (it will be reconciled by normal deletion propagation).
                        }
                    default:
                        continue   // unknown op kind — leave it queued
                    }
                    done.append(op.id)
                } catch {
                    // Leave this op queued for a later retry; keep going with the rest.
                    continue
                }
            }
            return done
        }.value

        for id in appliedIDs { try? library.catalog.clearFolderOp(id: id) }
    }

    // MARK: - UI path remap

    /// After a move from `src` → `dst`, rewrite the selection and every expanded-folder entry whose
    /// path is `src` or sits under it, preserving the remainder of the path.
    private func remapUIPaths(from src: String, to dst: String) {
        func remap(_ p: String) -> String {
            if p == src { return dst }
            if p.hasPrefix(src + "/") { return dst + String(p.dropFirst(src.count)) }
            return p
        }
        if let sel = selectedFolder { selectedFolder = remap(sel) }
        expandedFolders = Set(expandedFolders.map(remap))
    }
}

// Free functions usable inside `Task.detached` closures (which can't call @MainActor instance
// methods). They duplicate the basename-prefix mapping documented on `AppState.mapToDrive`.
private func mapToDriveStatic(_ relPath: String, basename: String) -> String {
    (basename + "/" + relPath).precomposedStringWithCanonicalMapping
}

private func parentOf(_ relPath: String) -> String {
    (relPath as NSString).deletingLastPathComponent
}
