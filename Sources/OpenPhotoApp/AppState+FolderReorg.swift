import AppKit
import OpenPhotoCore

// Folder reorganization on the Folders view. Every structural op is applied to the Mac primary
// vault first (via the tested `VaultReorganizer`), then propagated to each *connected* durable
// drive, and *enqueued* (pending_folder_ops) for each *offline* durable drive so its structure is
// reconciled the next time it connects (see `applyPendingFolderOps`, wired into the connect path).
// Disk loops run off the @MainActor via `Task.detached`. Per the approved design this is a full
// auto-reconcile queue with NO user warning.

/// A drive whose reconnect/mount scan found pending changes — drives the auto-presented review sheet.
struct ReviewPresentation: Identifiable { let id = UUID(); let drive: Vault }

/// The reviewable diff for one drive: queued ops + eligible deletions + drive-side drift.
struct ReviewChanges {
    var ops: [PendingFolderOp] = []
    var deletions: [PendingDeletion] = []
    var drift: DriftReport = DriftReport()
    /// Corrupt is excluded — it's only found by Verify Integrity's deep re-hash, not the fast scan.
    var isEmpty: Bool {
        ops.isEmpty && deletions.isEmpty
            && drift.unknown.isEmpty && drift.missing.isEmpty && drift.changed.isEmpty
    }
    var count: Int { ops.count + deletions.count + drift.unknown.count + drift.missing.count + drift.changed.count }
}

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
        await beginReorg()                                   // exclude the background scan (S03)

        let newPath: String
        do {
            newPath = try VaultReorganizer.moveFolder(in: primaryVault, relPath: src,
                                                      intoParentRelPath: parent)
        } catch {
            endReorg()
            NSAlert(error: error).runModal()   // surface collision/invalid-target to the user
            return
        }
        // Primary move succeeded — record the inverse (move `newPath` back under `src`'s parent).
        recordUndo(.moveFolder(from: src, to: newPath))

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

        endReorg()                                           // release before the post-reorg scan
        await rescan()
        remapUIPaths(from: src, to: newPath)
    }

    // MARK: - Rename

    /// Rename folder `src` in place (same parent, new name). Applies to the Mac primary vault,
    /// propagates to connected durable drives, queues offline drives, then rescans and remaps the UI.
    func renameFolder(_ src: String, to newName: String) async {
        guard let library, let primaryVault = library.vaults.first, !src.isEmpty else { return }
        await beginReorg()                                   // exclude the background scan (S03)

        let newPath: String
        do {
            newPath = try VaultReorganizer.renameFolder(in: primaryVault, relPath: src, toName: newName)
        } catch {
            endReorg()
            NSAlert(error: error).runModal()   // surface collision/invalid-name to the user
            return
        }
        guard newPath != src else { endReorg(); return }   // unchanged (same name)
        recordUndo(.renameFolder(from: src, to: newPath))

        // Propagate to connected durable drives that actually hold `src` (off-main).
        if let basename = driveBasename() {
            let drives = connectedDurableDrives().filter {
                driveHasFolder($0.vault, macRelPath: src, basename: basename)
            }
            if !drives.isEmpty {
                let newLeaf = (newPath as NSString).lastPathComponent
                await Task.detached(priority: .userInitiated) {
                    for d in drives {
                        _ = try? VaultReorganizer.renameFolder(in: d.vault,
                            relPath: mapToDriveStatic(src, basename: basename), toName: newLeaf)
                    }
                }.value
            }
        }

        // Queue for offline drives (reconciled on their next connect).
        for driveID in offlineDurableDriveIDs() {
            _ = try? library.catalog.enqueueFolderOp(vaultID: driveID, op: "rename", src: src, dst: newPath)
        }

        // Re-key cached drive presence onto the new path (see moveFolder for why this is needed).
        try? library.catalog.rewriteVaultPresencePaths(fromDir: src, toDir: newPath)
        reloadCanonicalPresence()

        endReorg()                                           // release before the post-reorg scan
        await rescan()
        remapUIPaths(from: src, to: newPath)
    }

    // MARK: - Move photos (file-grain)

    /// Move the photos behind `ids` (grid instanceIDs) into folder `dest` ("" = library
    /// root). Local files move in the Mac primary vault; the moves propagate to connected
    /// durable drives now (exact targets keep basenames aligned) and queue ("moveFile")
    /// for offline ones. Drive-only items re-key their presence row immediately and move
    /// on (or queue for) their drive. One rescan at the end; the user stays in the folder.
    func movePhotos(ids: [String], into dest: String) async {
        guard let library, !ids.isEmpty else { return }
        let items = (try? library.catalog.items(instanceIDs: ids)) ?? []
        guard !items.isEmpty else { return }
        let destDir = dest.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        await beginReorg()                                   // exclude the background scan (S03)

        // 1. Mac primary vault (local instances; movePhotos skips drive-only + in-dest).
        let result = library.movePhotos(items.filter { $0.driveRelPath == nil }, toDir: destDir)

        // Undo bookkeeping: every file actually moved (primary vault + drive-only rekeys below)
        // as data-only records; recorded once after the final rescan.
        var undoMoves: [MovedFileRecord] = []
        if let primaryID = library.vaults.first?.descriptor.vaultID {
            for (old, new) in result.moved {
                undoMoves.append(MovedFileRecord(vaultID: primaryID, from: old, to: new))
            }
        }

        // 2. Propagate the Mac moves to durable drives. Re-key each drive's presence row NOW so the
        //    catalog reflects the move immediately — otherwise the photo lingers as a drive-only
        //    "ghost" in the OLD folder (its presence row still points there) until the next rescan.
        //    Connected drives also move the file now; offline drives queue the file move for reconnect.
        if let basename = driveBasename(), !result.moved.isEmpty {
            let connected = connectedDurableDrives()
            let connectedIDs = Set(connected.map(\.id))
            for driveID in connectedIDs.union(offlineDurableDriveIDs()) {
                for (old, new) in result.moved {
                    try? library.catalog.rewriteVaultPresencePath(vaultID: driveID,
                                                                  fromRelPath: old, toRelPath: new)
                    if !connectedIDs.contains(driveID) {
                        _ = try? library.catalog.enqueueFolderOp(vaultID: driveID, op: "moveFile",
                                                                 src: old, dst: new)
                    }
                }
            }
            if !connected.isEmpty {
                let moved = result.moved
                await Task.detached(priority: .userInitiated) {
                    for d in connected {
                        for (old, new) in moved {
                            _ = try? VaultReorganizer.moveFile(in: d.vault,
                                relPath: mapToDriveStatic(old, basename: basename),
                                toRelPath: mapToDriveStatic(new, basename: basename))
                        }
                    }
                }.value
            }
        }

        // 3. Drive-only items: re-key the presence row now (instant UI), then move the
        //    drive file now if that drive is connected, else queue. Live partners follow
        //    via their presence row.
        let driveOnly = items.filter { $0.driveRelPath != nil && $0.dirPath != destDir }
        if !driveOnly.isEmpty, let basename = driveBasename() {
            let connected = Dictionary(uniqueKeysWithValues:
                connectedDurableDrives().map { ($0.id, $0.vault) })
            var driveFileMoves: [(vault: Vault, old: String, new: String)] = []
            for item in driveOnly {
                var relPaths = [item.relPath]
                if let pairHash = item.livePairHash,
                   let pairRel = try? library.catalog.vaultPresenceRelPath(
                        vaultID: item.vaultID, hash: pairHash) {
                    relPaths.append(pairRel)
                }
                for old in relPaths {
                    let name = (old as NSString).lastPathComponent
                    let new = destDir.isEmpty ? name : destDir + "/" + name
                    guard new != old else { continue }
                    try? library.catalog.rewriteVaultPresencePath(vaultID: item.vaultID,
                                                                  fromRelPath: old, toRelPath: new)
                    undoMoves.append(MovedFileRecord(vaultID: item.vaultID, from: old, to: new))
                    if let dv = connected[item.vaultID] {
                        driveFileMoves.append((dv, old, new))
                    } else {
                        _ = try? library.catalog.enqueueFolderOp(vaultID: item.vaultID,
                                op: "moveFile", src: old, dst: new)
                    }
                }
            }
            if !driveFileMoves.isEmpty {
                let moves = driveFileMoves
                await Task.detached(priority: .userInitiated) {
                    for m in moves {
                        _ = try? VaultReorganizer.moveFile(in: m.vault,
                            relPath: mapToDriveStatic(m.old, basename: basename),
                            toRelPath: mapToDriveStatic(m.new, basename: basename))
                    }
                }.value
            }
        }

        reloadCanonicalPresence()
        endReorg()
        // Incremental: `movePhotos` already updated each moved file's catalog instance + manifest +
        // sidecar in place (and the drive propagation above did the same on connected drives), so a
        // full rescan is unnecessary — it was O(whole library) regardless of how few photos moved.
        // Re-derive the locked flag (a photo may have moved into/out of a locked folder), then just
        // rebuild the queries.
        try? library.catalog.applyLockedFolders(lockedFolders)
        try? refreshQueries()
        photoMoveToken += 1
        if !undoMoves.isEmpty { recordUndo(.movePhotos(moves: undoMoves)) }

        // 4. Failures: one aggregate alert (successes are silent, like folder moves).
        if !result.failures.isEmpty {
            let alert = NSAlert()
            let n = result.failures.count
            alert.messageText = "Couldn't move \(n) item\(n == 1 ? "" : "s")"
            alert.informativeText = result.failures
                .sorted { $0.key < $1.key }.prefix(4)
                .map { "\(($0.key as NSString).lastPathComponent): \($0.value)" }
                .joined(separator: "\n") + (n > 4 ? "\n…" : "")
            alert.runModal()
        }
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
        for op in ops where await propagateFolderOp(op, to: driveVault, basename: basename) {
            try? library.catalog.clearFolderOp(id: op.id)
        }
    }

    /// Apply ONE queued op to a connected drive (the drive file/folder operation), off-main. Returns
    /// true when the op is handled (the caller clears it). A `.missing`/`.notEmpty` from the drive is
    /// treated as handled (the op is moot); other errors return false so the op stays queued for retry.
    @MainActor func propagateFolderOp(_ op: PendingFolderOp, to driveVault: Vault, basename: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                switch op.op {
                case "move":
                    guard let s = op.src, let d = op.dst else { return false }
                    try VaultReorganizer.moveFolder(in: driveVault, relPath: mapToDriveStatic(s, basename: basename),
                        intoParentRelPath: mapToDriveStatic(parentOf(d), basename: basename))
                case "rename":
                    guard let s = op.src, let d = op.dst else { return false }
                    do { try VaultReorganizer.renameFolder(in: driveVault, relPath: mapToDriveStatic(s, basename: basename),
                            toName: (d as NSString).lastPathComponent) }
                    catch VaultReorganizer.ReorgError.missing {}     // drive never held it — moot
                case "create":
                    guard let d = op.dst else { return false }
                    try VaultReorganizer.createFolder(in: driveVault, relPath: mapToDriveStatic(d, basename: basename))
                case "delete":
                    guard let s = op.src else { return false }
                    do { try VaultReorganizer.deleteEmptyFolder(in: driveVault, relPath: mapToDriveStatic(s, basename: basename)) }
                    catch VaultReorganizer.ReorgError.notEmpty {}    // still has content — leave dir, op handled
                case "moveFile":
                    guard let s = op.src, let d = op.dst else { return false }
                    do { try VaultReorganizer.moveFile(in: driveVault, relPath: mapToDriveStatic(s, basename: basename),
                            toRelPath: mapToDriveStatic(d, basename: basename)) }
                    catch VaultReorganizer.ReorgError.missing {}     // drive never held it — moot
                default:
                    return false   // unknown op kind — leave it queued
                }
                return true
            } catch { return false }   // leave queued for a later retry
        }.value
    }

    // MARK: - Reconnect review actions (propagate vs undo)

    /// Review "Propagate": apply one queued op to its connected drive, clear it, refresh presence.
    @MainActor func reviewPropagate(_ op: PendingFolderOp) async {
        guard let library, let basename = driveBasename(),
              let drive = connectedDurableDrives().first(where: { $0.id == op.vaultID })?.vault else { return }
        if await propagateFolderOp(op, to: drive, basename: basename) {
            try? library.catalog.clearFolderOp(id: op.id)
            try? refreshCanonicalPresence(driveVault: drive)
        }
        try? refreshQueries()
    }

    /// Review "Undo" (drive = ground truth): cancel a file move. Revert the Mac (file + instance) once,
    /// then re-path presence back and clear the matching op on EVERY drive that queued it. The drive's
    /// files are never touched. Folder-structure ops are propagate-only in v1 (no per-op undo).
    @MainActor func reviewUndo(_ op: PendingFolderOp) async {
        guard let library, op.op == "moveFile", let s = op.src, let d = op.dst else { return }
        // Revert the Mac once; use the path it ACTUALLY landed at (a collision may suffix it) so the
        // drive presence rows we rewrite below stay consistent with the local instance.
        let actualSrc = (try? library.revertLocalMove(from: d, to: s)) ?? s
        for vr in durableVaults {
            for sib in (try? library.catalog.pendingFolderOps(forVault: vr.id)) ?? []
                    where sib.op == "moveFile" && sib.src == s && sib.dst == d {
                try? library.catalog.rewriteVaultPresencePath(vaultID: vr.id, fromRelPath: d, toRelPath: actualSrc)
                try? library.catalog.clearFolderOp(id: sib.id)
            }
        }
        try? library.catalog.applyLockedFolders(lockedFolders)
        reloadCanonicalPresence()
        try? refreshQueries()
    }

    // MARK: - Reconnect review payload + auto-present

    /// The reviewable diff for `drive`: queued ops + eligible deletions + the last fast-scan drift.
    @MainActor func reviewPayload(forDrive drive: Vault) -> ReviewChanges {
        let id = drive.descriptor.vaultID
        return ReviewChanges(
            ops: (try? library?.catalog.pendingFolderOps(forVault: id)) ?? [],
            deletions: drivePendingDeletions[id] ?? [],
            drift: driveDrift[id] ?? DriftReport())
    }

    /// Auto-present the reconnect review for `drive` when it has anything to review — unless it's an
    /// adoption candidate, whose own prompt owns the first interaction.
    @MainActor func presentReviewIfNeeded(_ drive: Vault) {
        guard adoptableDrive?.id != drive.descriptor.vaultID else { return }
        if !reviewPayload(forDrive: drive).isEmpty { reviewDrive = ReviewPresentation(drive: drive) }
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
