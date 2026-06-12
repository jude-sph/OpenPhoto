import AppKit
import OpenPhotoCore

// ⌘Z via the WINDOW's native UndoManager (text fields keep their own undo while focused).
// SAFETY DESIGN (slice doc §2): descriptors are data-only; applyUndo ONLY dispatches to
// existing, already-tested operations with inverse arguments. Stale state makes an inverse
// fail exactly like it would for a hand-driven user (.missing / rename conflict / not in
// bin) — nothing is forced, nothing overwritten. No redo: applyUndo never registers.
extension AppState {

    /// Register one undoable action with the window's UndoManager. No-op while an undo is
    /// replaying (so the replayed ops never re-record → Redo stays disabled by design) and
    /// when no window manager has been captured yet.
    func recordUndo(_ action: UndoAction) {
        guard !isApplyingUndo, let um = windowUndoManager else { return }
        um.levelsOfUndo = 50
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.applyUndo(action) }
        }
        um.setActionName(action.label)
    }

    /// Replay the inverse of a recorded action. Pure dispatch — no file operations live here;
    /// every branch calls an existing public op with inverse arguments.
    func applyUndo(_ action: UndoAction) async {
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        switch action {

        case .deletePhotos(let hashes, _):
            guard let library else { return }
            let wanted = Set(hashes)
            let entries = ((try? library.binItems()) ?? [])
                .filter { wanted.contains($0.item.hash) }
            var restored = 0
            for entry in entries {
                do { try await library.restore(entry); restored += 1 } catch { continue }
            }
            try? refreshQueries()
            // Failures: entries that errored + hashes with no bin entry left at all.
            let foundHashes = Set(entries.map(\.item.hash))
            let failures = (entries.count - restored) + wanted.subtracting(foundHashes).count
            if failures > 0 {
                let alert = NSAlert()
                alert.messageText = "Couldn't undo Delete"
                alert.informativeText = failures == 1
                    ? "1 item was no longer in the bin."
                    : "\(failures) items were no longer in the bin."
                alert.runModal()
            }

        case .movePhotos(let moves):
            // Count how many requested instanceIDs actually resolve in the catalog now, so we
            // can warn the user about any subset that was already gone before the undo ran.
            // This is a read-only pre-flight; the movePhotos calls below remain unchanged.
            guard let library else { return }
            let groups = UndoPlan.inverseMoveGroups(moves)
            var unresolved = 0
            for group in groups {
                let resolved = (try? library.catalog.items(instanceIDs: group.ids))?.count ?? 0
                unresolved += group.ids.count - resolved
            }
            // movePhotos already alerts its own failures and is stale-safe (.missing skips).
            for group in groups {
                await movePhotos(ids: group.ids, into: group.destDir)
            }
            if unresolved > 0 {
                let alert = NSAlert()
                alert.messageText = "Couldn't undo Move for \(unresolved) item\(unresolved == 1 ? "" : "s")"
                alert.informativeText = "They were no longer where the move left them — nothing was changed for those items."
                alert.runModal()
            }

        case .moveFolder(let from, let to):
            // moveFolder surfaces its own collision/missing alerts.
            await moveFolder(from: to, into: (from as NSString).deletingLastPathComponent)

        case .rename(let vaultID, let relPath, let oldName):
            guard let library else { return }
            let item = ((try? library.catalog.items(instanceIDs: [vaultID + "|" + relPath])) ?? [])
                .first
            guard let item else {
                let alert = NSAlert()
                alert.messageText = "Couldn't undo Rename"
                alert.informativeText = "The file is no longer where it was."
                alert.runModal()
                return
            }
            do {
                try await library.rename(item, to: oldName)
                try refreshQueries()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't undo Rename"
                alert.informativeText = "The original name is taken, or the file changed since."
                alert.runModal()
            }
        }
    }
}
