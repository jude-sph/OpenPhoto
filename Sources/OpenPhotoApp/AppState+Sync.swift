import SwiftUI
import OpenPhotoCore

/// Observable snapshot of an in-flight (or just-finished) background drive job — a sync, an evict,
/// or a rehydrate. The sheet + sidebar chip read this; `AppState.activeJob` is the single source of
/// truth (only ONE job runs at a time), updated on the MainActor.
struct DriveJob: Sendable {
    enum Kind: String, Sendable { case sync, evict, rehydrate }
    enum Phase: Sendable, Equatable { case running, finished, cancelled }
    var kind: Kind
    var scopeLabel: String                      // "all photos", a folder name — for display
    var driveName: String
    var stage: DriveProgress.Stage
    var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
    var filesDone = 0, filesTotal = 0
    var currentName = ""
    var speedBytesPerSec = 0.0
    var etaSeconds: Double?
    var phase: Phase = .running
    var result: DriveJobResult?                 // set when phase != .running
}

enum DriveJobResult: Sendable {
    case sync(SyncResult)
    case evict(EvictOutcome)
    case rehydrate(done: Int, failed: [FailedItem])
}

/// A tiny thread-safe Bool the off-actor engine `shouldCancel` closure can poll directly. The engine
/// runs its copy loop off the MainActor, so it can't safely read AppState's @MainActor cancel flag;
/// instead `startSync` hands the closure one of these (captured by value, not `self`). Shared by all
/// background jobs (sync/evict/rehydrate).
final class JobCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private extension SyncProgress.Stage {
    var asDriveStage: DriveProgress.Stage {
        switch self { case .copying: .copying; case .verifying: .verifying; case .finishing: .finishing }
    }
}

extension AppState {
    /// Start a background sync to `drive`. Stores a cancellable Task; streams progress into
    /// `activeJob` (speed/ETA via SyncRateMeter). Post-sync bookkeeping (presence, deletions,
    /// snapshot, albums) runs here so it survives the sheet being minimized.
    func startSync(plan: SyncPlan, drive: Vault, chosenDeletions: [PendingDeletion] = []) {
        guard jobTask == nil, let lib = library else { return }
        let volume = FileSystemVolume(rootURL: drive.rootURL)
        jobCancelRequested = false
        let cancelFlag = JobCancelFlag()
        jobCancelFlag = cancelFlag
        jobDrive = drive
        jobRateMeter = SyncRateMeter()
        jobRaw = nil
        let bytesTotal = plan.totalCopyBytes
        activeJob = DriveJob(kind: .sync, scopeLabel: "", driveName: drive.rootURL.lastPathComponent,
                             stage: .copying, bytesTotal: bytesTotal, filesTotal: plan.copies.count)
        let engine = SyncEngine(library: lib)
        let start = Date()
        // The @Sendable progress/cancel closures must not capture the outer Task's `self`; give them an
        // independent weak reference (they hop to @MainActor before use).
        weak var weakSelf = self

        // The ticker is the ONLY thing that updates the visible numbers: every 0.5s it samples the raw
        // buffer and computes a windowed-average speed + whole-job ETA, so the UI refreshes calmly at
        // 2 Hz instead of jittering at the engine's per-chunk callback rate (which made it flicker and
        // the speed/ETA nonsense).
        jobTickerTask = Task { @MainActor in
            while !Task.isCancelled {
                if let self = weakSelf, let raw = self.jobRaw,
                   var a = self.activeJob, a.phase == .running {
                    let (speed, eta) = self.jobRateMeter.update(
                        bytesDone: raw.bytesDone, bytesTotal: bytesTotal,
                        now: Date().timeIntervalSince(start))
                    a.bytesDone = raw.bytesDone
                    a.filesDone = raw.filesDone; a.currentName = raw.currentName; a.stage = raw.stage
                    a.speedBytesPerSec = speed; a.etaSeconds = eta
                    self.activeJob = a
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        jobTask = Task {
            let r = await engine.apply(plan, destinationVault: drive, volume: volume,
                shouldCancel: { cancelFlag.isCancelled },
                progress: { p in Task { @MainActor in weakSelf?.jobRaw = DriveProgress(
                    stage: p.stage.asDriveStage, filesDone: p.done, filesTotal: p.total,
                    bytesDone: p.bytesDone, bytesTotal: p.bytesTotal, currentName: p.currentName) } })  // buffer only; ticker renders
            await weakSelf?.finishSync(result: r, drive: drive, chosenDeletions: chosenDeletions)
        }
    }

    @MainActor private func finishSync(result r: SyncResult, drive: Vault,
                                       chosenDeletions: [PendingDeletion]) async {
        jobTickerTask?.cancel(); jobTickerTask = nil             // stop the ticker; we settle the bar below
        // If the library was closed mid-sync, skip the post-sync bookkeeping (it would run against a
        // torn-down AppState); teardown already cleared activeJob.
        guard library != nil else { jobTask = nil; jobCancelFlag = nil; jobRaw = nil; return }
        // Show a "finishing" state during the post-copy bookkeeping (writing the drive's catalog
        // snapshot + albums can take a while on a big library) so the UI doesn't sit frozen on the last
        // copied file. The copy itself is already done + safe at this point.
        if !r.cancelled, var a = activeJob, a.phase == .running {
            a.stage = .finishing; a.bytesDone = a.bytesTotal; a.filesDone = a.filesTotal
            a.currentName = ""; a.speedBytesPerSec = 0; a.etaSeconds = nil
            activeJob = a
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
        var a = activeJob ?? DriveJob(kind: .sync, scopeLabel: "",
                                      driveName: drive.rootURL.lastPathComponent, stage: .finishing)
        a.phase = r.cancelled ? .cancelled : .finished
        if !r.cancelled { a.bytesDone = a.bytesTotal; a.filesDone = a.filesTotal }   // settle the bar at 100%
        a.result = .sync(r)
        activeJob = a
        jobTask = nil; jobCancelFlag = nil; jobRaw = nil
    }

    func cancelSync() { jobCancelRequested = true; jobCancelFlag?.cancel() }

    /// Re-run a sync for just the selected previously-failed items.
    func retrySyncFailures(_ items: [PlanItem], drive: Vault) {
        guard jobTask == nil else { return }
        var plan = SyncPlan()
        plan.copies = items
        plan.totalCopyBytes = items.reduce(0) { $0 + $1.size }
        startSync(plan: plan, drive: drive)
    }

    func dismissSyncResult() {
        guard jobTask == nil else { return }   // don't clear a running job
        activeJob = nil; jobDrive = nil; jobSheetDrive = nil
    }
}
