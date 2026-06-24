import SwiftUI
import OpenPhotoCore

extension AppState {
    /// Download a selection's originals back to this Mac as a background job on the unified job slot.
    /// Streams progress into `activeJob` via the shared ticker; finishes through `finishStorageJob`.
    func startRehydrateJob(items: [TimelineItem], scopeLabel: String, driveName: String) {
        guard jobTask == nil, let lib = library else { return }
        let drives = connectedDrivesCanonicalFirst()
        jobCancelRequested = false
        let flag = JobCancelFlag(); jobCancelFlag = flag
        jobRateMeter = SyncRateMeter(); jobRaw = nil
        jobDrive = drives.first
        let bytesTotal = items.reduce(Int64(0)) { $0 + $1.size }
        activeJob = DriveJob(kind: .rehydrate, scopeLabel: scopeLabel, driveName: driveName,
                             stage: .copying, bytesTotal: bytesTotal, filesTotal: items.count)
        let start = Date(); startJobTicker(start: start, bytesTotal: bytesTotal)
        weak var weakSelf = self
        jobTask = Task {
            let outcome = (try? await lib.rehydrate(items, connectedCanonical: drives,
                progress: { p in Task { @MainActor in weakSelf?.jobRaw = p } },
                shouldCancel: { flag.isCancelled })) ?? RehydrateOutcome()
            await weakSelf?.finishStorageJob(
                result: .rehydrate(done: outcome.rehydrated, failed: outcome.failedItems),
                cancelled: flag.isCancelled)
        }
    }

    /// Free up space by evicting a selection's verified local originals to the Trash as a background
    /// job on the unified job slot. Streams progress into `activeJob`; finishes through `finishStorageJob`.
    func startEvictJob(items: [TimelineItem], scopeLabel: String, driveName: String) {
        guard jobTask == nil, let lib = library else { return }
        let drives = connectedDrivesCanonicalFirst(); let presence = canonicalPresence
        jobCancelRequested = false
        let flag = JobCancelFlag(); jobCancelFlag = flag
        jobRateMeter = SyncRateMeter(); jobRaw = nil
        jobDrive = drives.first
        let bytesTotal = items.reduce(Int64(0)) { $0 + $1.size }
        activeJob = DriveJob(kind: .evict, scopeLabel: scopeLabel, driveName: driveName,
                             stage: .verifying, bytesTotal: bytesTotal, filesTotal: items.count)
        let start = Date(); startJobTicker(start: start, bytesTotal: bytesTotal)
        weak var weakSelf = self
        jobTask = Task {
            let outcome = (try? await lib.evict(items, mode: .verified, connectedCanonical: drives,
                canonicalPresence: presence,
                progress: { p in Task { @MainActor in weakSelf?.jobRaw = p } },
                shouldCancel: { flag.isCancelled })) ?? EvictOutcome()
            await weakSelf?.finishStorageJob(result: .evict(outcome), cancelled: flag.isCancelled)
        }
    }

    @MainActor private func finishStorageJob(result: DriveJobResult, cancelled: Bool) async {
        jobTickerTask?.cancel(); jobTickerTask = nil
        guard library != nil else { jobTask = nil; jobCancelFlag = nil; jobRaw = nil; return }
        reloadCanonicalPresence()
        await reloadLibraryAfterStorageChange()
        var a = activeJob ?? DriveJob(kind: .evict, scopeLabel: "", driveName: "", stage: .finishing)
        a.phase = cancelled ? .cancelled : .finished
        if !cancelled { a.bytesDone = a.bytesTotal; a.filesDone = a.filesTotal }
        a.result = result
        activeJob = a
        jobTask = nil; jobCancelFlag = nil; jobRaw = nil
    }

    /// Refresh the Timeline/grid after an evict or rehydrate so evicted items show as drive-only and
    /// rehydrated items show as local. Mirrors exactly the refresh the synchronous `evict`/`rehydrate`
    /// paths run: a drift-scan of every present durable drive re-derives canonical presence from disk,
    /// then `refreshQueries` rebuilds the timeline/folder/bin queries off that fresh state.
    @MainActor func reloadLibraryAfterStorageChange() async {
        for vr in durableVaults where driveIsPresent(vr) {
            if let v = openVault(for: vr) { _ = driftScan(v) }
        }
        try? refreshQueries()
    }
}
