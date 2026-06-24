import SwiftUI
import OpenPhotoCore

/// Observable snapshot of an in-flight (or just-finished) background sync. The sheet + sidebar chip
/// read this; `AppState.syncActivity` is the single source of truth, updated on the MainActor.
struct SyncActivity: Sendable {
    enum Phase: Sendable, Equatable { case running, finished, cancelled }
    var driveName: String
    var stage: SyncProgress.Stage
    var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
    var filesDone = 0, filesTotal = 0
    var currentName = ""
    var speedBytesPerSec = 0.0
    var etaSeconds: Double?
    var phase: Phase = .running
    var result: SyncResult?                    // set when phase != .running
}

/// A tiny thread-safe Bool the off-actor engine `shouldCancel` closure can poll directly. The engine
/// runs its copy loop off the MainActor, so it can't safely read AppState's @MainActor cancel flag;
/// instead `startSync` hands the closure one of these (captured by value, not `self`).
final class SyncCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

extension AppState {
    /// Start a background sync to `drive`. Stores a cancellable Task; streams progress into
    /// `syncActivity` (speed/ETA via SyncRateMeter). Post-sync bookkeeping (presence, deletions,
    /// snapshot, albums) runs here so it survives the sheet being minimized.
    func startSync(plan: SyncPlan, drive: Vault, chosenDeletions: [PendingDeletion] = []) {
        guard syncTask == nil, let lib = library else { return }
        let volume = FileSystemVolume(rootURL: drive.rootURL)
        syncCancelRequested = false
        let cancelFlag = SyncCancelFlag()
        syncCancelFlag = cancelFlag
        syncDrive = drive
        syncRateMeter = SyncRateMeter()
        syncActivity = SyncActivity(driveName: drive.rootURL.lastPathComponent, stage: .copying,
                                    bytesTotal: plan.totalCopyBytes, filesTotal: plan.copies.count)
        let engine = SyncEngine(library: lib)
        let start = Date()
        // The @Sendable progress/cancel closures must not capture the outer Task's `self`; give the
        // progress closure its own independent weak reference (it hops to @MainActor before use).
        weak var weakSelf = self
        syncTask = Task {
            let r = await engine.apply(plan, destinationVault: drive, volume: volume,
                shouldCancel: { cancelFlag.isCancelled },
                progress: { p in
                    Task { @MainActor in
                        guard let self = weakSelf, var a = self.syncActivity else { return }
                        let (speed, eta) = self.syncRateMeter.update(
                            bytesDone: p.bytesDone, bytesTotal: p.bytesTotal,
                            now: Date().timeIntervalSince(start))
                        a.stage = p.stage; a.bytesDone = p.bytesDone; a.bytesTotal = p.bytesTotal
                        a.filesDone = p.done; a.currentName = p.currentName
                        a.speedBytesPerSec = speed; a.etaSeconds = eta
                        self.syncActivity = a
                    }
                })
            await weakSelf?.finishSync(result: r, drive: drive, chosenDeletions: chosenDeletions)
        }
    }

    @MainActor private func finishSync(result r: SyncResult, drive: Vault,
                                       chosenDeletions: [PendingDeletion]) async {
        // (Moved verbatim from the old SyncPlanSheet.runApply post-apply block.)
        try? refreshCanonicalPresence(driveVault: drive)
        refreshPendingDeletions()
        let pending = drivePendingDeletions[drive.descriptor.vaultID] ?? []
        let chosen = pending.filter { p in chosenDeletions.contains { $0.hash == p.hash } }
        if !chosen.isEmpty { _ = await propagateDeletions(drive: drive, selected: chosen) }
        if let lib = library {
            let cat = lib.catalog, thumbs = lib.thumbnails, syncedDrive = drive
            let macRoot = lib.vaults.first?.rootURL
            await Task.detached(priority: .utility) {
                try? CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: syncedDrive)
                if let macRoot { try? AlbumStore.syncToDrive(libraryRoot: macRoot, driveStateDir: syncedDrive.stateDirURL) }
            }.value
        }
        var a = syncActivity ?? SyncActivity(driveName: drive.rootURL.lastPathComponent, stage: .finishing)
        a.phase = r.cancelled ? .cancelled : .finished
        a.result = r
        syncActivity = a
        syncTask = nil
        syncCancelFlag = nil
    }

    func cancelSync() { syncCancelRequested = true; syncCancelFlag?.cancel() }

    /// Re-run a sync for just the selected previously-failed items.
    func retrySyncFailures(_ items: [PlanItem], drive: Vault) {
        guard syncTask == nil else { return }
        var plan = SyncPlan()
        plan.copies = items
        plan.totalCopyBytes = items.reduce(0) { $0 + $1.size }
        startSync(plan: plan, drive: drive)
    }

    func dismissSyncResult() {
        guard syncTask == nil else { return }   // don't clear a running sync
        syncActivity = nil; syncDrive = nil; syncSheetDrive = nil
    }
}
