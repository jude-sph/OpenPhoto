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
        syncRaw = nil
        let bytesTotal = plan.totalCopyBytes
        syncActivity = SyncActivity(driveName: drive.rootURL.lastPathComponent, stage: .copying,
                                    bytesTotal: bytesTotal, filesTotal: plan.copies.count)
        let engine = SyncEngine(library: lib)
        let start = Date()
        // The @Sendable progress/cancel closures must not capture the outer Task's `self`; give them an
        // independent weak reference (they hop to @MainActor before use).
        weak var weakSelf = self

        // The ticker is the ONLY thing that updates the visible numbers: every 0.5s it samples the raw
        // buffer and computes a windowed-average speed + whole-job ETA, so the UI refreshes calmly at
        // 2 Hz instead of jittering at the engine's per-chunk callback rate (which made it flicker and
        // the speed/ETA nonsense).
        syncTickerTask = Task { @MainActor in
            while !Task.isCancelled {
                if let self = weakSelf, let raw = self.syncRaw,
                   var a = self.syncActivity, a.phase == .running {
                    let (speed, eta) = self.syncRateMeter.update(
                        bytesDone: raw.bytesDone, bytesTotal: bytesTotal,
                        now: Date().timeIntervalSince(start))
                    a.bytesDone = raw.bytesDone
                    a.filesDone = raw.done; a.currentName = raw.currentName; a.stage = raw.stage
                    a.speedBytesPerSec = speed; a.etaSeconds = eta
                    self.syncActivity = a
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        syncTask = Task {
            let r = await engine.apply(plan, destinationVault: drive, volume: volume,
                shouldCancel: { cancelFlag.isCancelled },
                progress: { p in Task { @MainActor in weakSelf?.syncRaw = p } })  // buffer only; ticker renders
            await weakSelf?.finishSync(result: r, drive: drive, chosenDeletions: chosenDeletions)
        }
    }

    @MainActor private func finishSync(result r: SyncResult, drive: Vault,
                                       chosenDeletions: [PendingDeletion]) async {
        syncTickerTask?.cancel(); syncTickerTask = nil           // stop the ticker; we settle the bar below
        // If the library was closed mid-sync, skip the post-sync bookkeeping (it would run against a
        // torn-down AppState); teardown already cleared syncActivity.
        guard library != nil else { syncTask = nil; syncCancelFlag = nil; syncRaw = nil; return }
        // Show a "finishing" state during the post-copy bookkeeping (writing the drive's catalog
        // snapshot + albums can take a while on a big library) so the UI doesn't sit frozen on the last
        // copied file. The copy itself is already done + safe at this point.
        if !r.cancelled, var a = syncActivity, a.phase == .running {
            a.stage = .finishing; a.bytesDone = a.bytesTotal; a.filesDone = a.filesTotal
            a.currentName = ""; a.speedBytesPerSec = 0; a.etaSeconds = nil
            syncActivity = a
        }
        await Task.yield()   // let SwiftUI paint the "finishing" state before the slow bookkeeping
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
        if !r.cancelled { a.bytesDone = a.bytesTotal; a.filesDone = a.filesTotal }   // settle the bar at 100%
        a.result = r
        syncActivity = a
        syncTask = nil; syncCancelFlag = nil; syncRaw = nil
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
