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
    func connectedDurableDrives() -> [(id: String, vault: Vault)] {
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
                let failedIDs = await Task.detached(priority: .userInitiated) { () -> [String] in
                    var failed: [String] = []
                    for d in drives {
                        do {
                            try VaultReorganizer.moveFolder(in: d.vault,
                                relPath: mapToDriveStatic(src, basename: basename),
                                intoParentRelPath: mapToDriveStatic(parent, basename: basename))
                        } catch {
                            failed.append(d.id)   // DON'T swallow — queue it below
                        }
                    }
                    return failed
                }.value
                // A connected drive whose move failed gets a queued op instead of a silent drop, so it
                // surfaces in the reconnect review and retries. With the tolerance fix, an already-applied
                // move now clears (and tidies the old folder) instead of sticking — this closes the
                // silent-duplication gap (a swallowed failure + additive sync = a folder left at both paths).
                for id in failedIDs {
                    _ = try? library.catalog.enqueueFolderOp(vaultID: id, op: "move", src: src, dst: newPath)
                }
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
        rewriteTravelPaths(from: src, to: newPath)           // trips follow their folders
    }

    // MARK: - Merge (set union)

    /// The move/bin counts a merge of `src` into `dest` would perform, for the confirmation preview.
    func mergeFolderCounts(_ src: String, into dest: String) -> (move: Int, bin: Int) {
        guard let library, let plan = try? library.mergeFolderPlan(src: src, into: dest) else { return (0, 0) }
        return (plan.moves.count, plan.binInstanceIDs.count)
    }

    /// True when folder `src` holds NO local (on-Mac) items — it's drive-only (or empty), so a
    /// set-union merge would move nothing. Used to block a meaningless "0 / 0" merge with a clear note.
    func folderHasNoLocalItems(_ src: String) -> Bool {
        guard let library else { return true }
        let items = (try? library.items(inDir: src, recursive: true)) ?? []
        return !items.contains { $0.driveRelPath == nil }
    }

    /// Merge folder `src` into `dest` by CONTENT (set union): photos not already in `dest` move in
    /// (sub-path preserved); exact-duplicate copies go to the bin (recoverable); the emptied `src` tree
    /// is pruned. Reuses the batched movePhotos + delete paths, so drive propagation + safety apply.
    func mergeFolder(_ src: String, into dest: String) async {
        guard let library, src != dest else { return }
        let plan = (try? library.mergeFolderPlan(src: src, into: dest)) ?? MergeFolderPlan()
        // 1. Move the uniques, grouped by their destination sub-dir.
        for (dir, group) in Dictionary(grouping: plan.moves, by: \.intoDir) {
            await movePhotos(ids: group.map(\.instanceID), into: dir)
        }
        // 2. Bin the exact duplicates (recoverable; connected drives queue removal for review).
        if !plan.binInstanceIDs.isEmpty {
            let dups = (try? library.catalog.items(instanceIDs: plan.binInstanceIDs)) ?? []
            await delete(dups)
        }
        // 3. Prune the now-empty source tree (safe — never removes a dir that still holds photos).
        if let primary = library.vaults.first { VaultReorganizer.pruneEmptyDirs(in: primary, under: src) }
        try? refreshQueries()
        photoMoveToken += 1
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
        rewriteTravelPaths(from: src, to: newPath)           // trips follow their folders
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
        //    Run OFF the @MainActor: the file renames + the (single, batched) manifest write + the
        //    catalog transaction are blocking I/O that must not stall the window. LibraryService is
        //    Sendable and its catalog uses a serial DB queue, so this is safe off-main; beginReorg()
        //    has already fenced the background scanner. UI-state refresh resumes on main below.
        let localItems = items.filter { $0.driveRelPath == nil }
        let result = await Task.detached(priority: .userInitiated) { [library] in
            library.movePhotos(localItems, toDir: destDir)
        }.value

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
            let offlineMoves = result.moved.map { (src: $0.key, dst: $0.value) }
            for driveID in connectedIDs.union(offlineDurableDriveIDs()) {
                // One presence-rewrite transaction per drive for the whole batch (was one per file).
                try? library.catalog.rewriteVaultPresencePaths(vaultID: driveID, mapping: result.moved)
                if !connectedIDs.contains(driveID) {
                    // One enqueue transaction per offline drive (was one per file).
                    try? library.catalog.enqueueFolderOps(vaultID: driveID, op: "moveFile", moves: offlineMoves)
                }
            }
            if !connected.isEmpty {
                let moved = result.moved
                await Task.detached(priority: .userInitiated) {
                    for d in connected {
                        // One manifest rewrite per drive for the whole batch (was one per file).
                        let moves = moved.map { (from: mapToDriveStatic($0.key, basename: basename),
                                                 to: mapToDriveStatic($0.value, basename: basename)) }
                        _ = try? VaultReorganizer.moveFilesExact(in: d.vault, moves: moves)
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
            var driveFileMovesByVault: [String: [(old: String, new: String)]] = [:]   // vaultID → moves
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
                    if connected[item.vaultID] != nil {
                        driveFileMovesByVault[item.vaultID, default: []].append((old, new))
                    } else {
                        _ = try? library.catalog.enqueueFolderOp(vaultID: item.vaultID,
                                op: "moveFile", src: old, dst: new)
                    }
                }
            }
            if !driveFileMovesByVault.isEmpty {
                let movesByVault = driveFileMovesByVault, conn = connected
                await Task.detached(priority: .userInitiated) {
                    for (vaultID, list) in movesByVault {
                        guard let v = conn[vaultID] else { continue }
                        // One manifest rewrite per drive for the whole batch (was one per file).
                        let moves = list.map { (from: mapToDriveStatic($0.old, basename: basename),
                                                to: mapToDriveStatic($0.new, basename: basename)) }
                        _ = try? VaultReorganizer.moveFilesExact(in: v, moves: moves)
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
                    let driveSrc = mapToDriveStatic(s, basename: basename)
                    do { try VaultReorganizer.moveFolder(in: driveVault, relPath: driveSrc,
                            intoParentRelPath: mapToDriveStatic(parentOf(d), basename: basename)) }
                    catch VaultReorganizer.ReorgError.missing {}     // drive never held the source — moot
                    catch VaultReorganizer.ReorgError.destinationExists {
                        // Already at the destination (applied earlier / additive sync). The op is done;
                        // tidy up the now-redundant OLD folder — but only if it's empty (deleteEmptyFolder
                        // refuses a non-empty dir, so this can never remove photos).
                        try? VaultReorganizer.deleteEmptyFolder(in: driveVault, relPath: driveSrc)
                    }
                case "rename":
                    guard let s = op.src, let d = op.dst else { return false }
                    let driveSrc = mapToDriveStatic(s, basename: basename)
                    do { try VaultReorganizer.renameFolder(in: driveVault, relPath: driveSrc,
                            toName: (d as NSString).lastPathComponent) }
                    catch VaultReorganizer.ReorgError.missing {}     // drive never held it — moot
                    catch VaultReorganizer.ReorgError.destinationExists {
                        try? VaultReorganizer.deleteEmptyFolder(in: driveVault, relPath: driveSrc)   // already renamed
                    }
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

    /// Propagate MANY queued ops with the O(whole-library) reconcile done ONCE at the end, not per op
    /// (the per-op `refreshQueries` was why "Propagate all" of thousands of moves froze for minutes).
    /// Each op's file work is still off-main and per-op-atomic (so failures stay queued for retry);
    /// only the expensive main-actor rebuild is hoisted out of the loop. `progress(done, total)` fires
    /// per op — the callback runs on the main actor.
    @MainActor func reviewPropagateAll(_ ops: [PendingFolderOp],
                                       progress: (Int, Int) -> Void = { _, _ in }) async {
        guard let library, let basename = driveBasename() else { return }
        let connected = connectedDurableDrives()
        var touched: Set<String> = []          // drive IDs whose presence needs a refresh
        for (i, op) in ops.enumerated() {
            progress(i + 1, ops.count)
            guard let drive = connected.first(where: { $0.id == op.vaultID })?.vault else { continue }
            if await propagateFolderOp(op, to: drive, basename: basename) {
                try? library.catalog.clearFolderOp(id: op.id)
                touched.insert(op.vaultID)
            }
        }
        guard !touched.isEmpty else { return }
        for d in connected where touched.contains(d.id) { try? refreshCanonicalPresence(driveVault: d.vault) }
        try? refreshQueries()                  // ONCE, not per op
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
        // A lock is stored by PATH: moving or renaming a locked folder (or any ancestor) must carry
        // the lock to the new path, or the folder silently unlocks and stays unlocked.
        let remappedLocks = lockedFolders.map(remap)
        if remappedLocks != lockedFolders {
            lockedFolders = remappedLocks
            if let root = library?.vaults.first?.rootURL {
                try? LockedFolderStore.save(lockedFolders, libraryRoot: root)
            }
            try? library?.catalog.applyLockedFolders(lockedFolders)
        }
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
