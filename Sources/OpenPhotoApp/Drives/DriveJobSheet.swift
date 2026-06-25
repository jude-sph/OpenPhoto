import SwiftUI
import OpenPhotoCore

struct DriveJobSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var plan: SyncPlan?
    @State private var freeBytes: Int64 = 0
    @State private var deletionSelection: Set<String> = []
    @State private var showThumbs = false
    @State private var retrySelection: Set<String> = []   // by item.destRelPath

    private var volume: FileSystemVolume { FileSystemVolume(rootURL: drive.rootURL) }
    private var isRunning: Bool { state.activeJob?.phase == .running }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.activeJob.map(title) ?? "Sync to \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }.disabled(isRunning)
            }.padding(16)
            Divider().overlay(Theme.hairline)
            Group {
                if let a = state.activeJob {
                    if a.phase == .running {
                        runningView(a)
                    } else if !failures(a).isEmpty {
                        failureView(a)
                    } else {
                        finishedView(a)
                    }
                } else if let plan {
                    planView(plan)
                } else {
                    ProgressView().padding(24)
                }
            }.frame(maxHeight: .infinity)
        }
        .frame(width: 540, height: 360)
        .task { await computePlan() }
    }

    // MARK: Kind-aware labels

    private func verb(_ a: DriveJob) -> String {
        switch a.kind { case .sync: "Copying"; case .evict: "Verifying"; case .rehydrate: "Downloading" }
    }
    private func title(_ a: DriveJob) -> String {
        switch a.kind {
        case .sync: "Sync to \(a.driveName)"
        case .evict: "Free up Mac space" + (a.scopeLabel.isEmpty ? "" : " · \(a.scopeLabel)")
        case .rehydrate: "Download to Mac" + (a.scopeLabel.isEmpty ? "" : " · \(a.scopeLabel)")
        }
    }

    private func computePlan() async {
        guard state.activeJob == nil, let lib = state.library else { return }
        await state.reconcileFolderOps(driveVault: drive)   // apply offline moves before planning the sync
        let engine = SyncEngine(library: lib)
        plan = (try? engine.plan(sources: lib.vaults, destinationVault: drive)) ?? SyncPlan()
        freeBytes = (try? volume.freeSpaceBytes()) ?? 0
    }

    // MARK: Confirm

    @ViewBuilder private func planView(_ plan: SyncPlan) -> some View {
        let enough = freeBytes >= plan.totalCopyBytes
        VStack(alignment: .leading, spacing: 10) {
            Text("\(plan.copies.count) new files · \(byteString(plan.totalCopyBytes))")
                .font(.system(size: 14, weight: .medium))
                .help("Every media file to back up — includes live-photo videos and any photo that lives in more than one folder, so it can exceed the deduplicated Timeline count.")
            Text("\(plan.sidecarUpdates.count) metadata sidecars")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            if plan.conflicts.count > 0 {
                Label("\(plan.conflicts.count) conflicts skipped (different file already on drive)",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Text("Free space: \(byteString(freeBytes))")
                .font(.system(size: 12)).foregroundStyle(enough ? Theme.textDim : .red)
            let pending = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
            if !pending.isEmpty {
                Divider().overlay(Theme.hairline)
                Text("Deletions to review (\(pending.count))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text("Deleted on this Mac, still on the drive. Tick to move the drive's copies into its bin.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                DeletionListView(state: state, entries: pending,
                                 selected: $deletionSelection, onRestore: restore)
                    .frame(maxHeight: 160)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Sync") { startSync(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enough || (plan.copies.isEmpty && plan.sidecarUpdates.isEmpty
                                          && deletionSelection.isEmpty))
            }
        }.padding(24)
    }

    private func startSync(_ plan: SyncPlan) {
        let pending = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
        let chosen = pending.filter { deletionSelection.contains($0.hash) }
        state.startSync(plan: plan, drive: drive, chosenDeletions: chosen)
        // No dismiss(): activeJob becomes non-nil, so the sheet flips to the running phase.
    }

    // MARK: Running

    @ViewBuilder private func runningView(_ a: DriveJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if a.stage == .finishing {
                // Copy is done + safe; for sync this is the (potentially slow) catalog-snapshot/album write.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(a.kind == .sync ? "Finishing — saving the catalog to the drive…" : "Finishing…")
                        .font(.system(size: 13))
                }
                Text("\(byteString(a.bytesTotal)) copied · \(a.filesTotal) files · keep the drive connected")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            } else {
                ProgressView(value: Double(a.bytesDone), total: Double(max(a.bytesTotal, 1))).tint(Theme.accent)
                Text("\(byteString(a.bytesDone)) / \(byteString(a.bytesTotal)) · \(speedString(a.speedBytesPerSec))"
                     + (a.etaSeconds.map { " · ~\(etaString($0)) left" } ?? ""))
                    .font(.system(size: 13).monospacedDigit())
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(verb(a)) \(a.currentName) · \(a.filesDone)/\(a.filesTotal) files")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack {
                if a.stage != .finishing { Button("Cancel", role: .destructive) { state.cancelSync() } }
                Spacer()
                Button("Minimize") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24)
    }

    // MARK: Finished — success

    private func finishedHeadline(_ a: DriveJob) -> String {
        switch a.result {
        case .sync: "Sync complete"; case .evict: "Freed up space"
        case .rehydrate: "Download complete"; case .none: "Done"
        }
    }
    private func finishedDetail(_ a: DriveJob) -> String {
        switch a.result {
        case let .sync(r): "\(r.copied) copied · \(r.skipped) already there · \(r.sidecarsWritten) sidecars"
        case let .evict(o): "\(o.evicted) photos moved to Trash" + (o.refused > 0 ? " · \(o.refused) kept (couldn’t verify on the drive)" : "")
        case let .rehydrate(done, failed): "\(done) photos downloaded" + (failed.isEmpty ? "" : " · \(failed.count) failed")
        case .none: ""
        }
    }

    @ViewBuilder private func finishedView(_ a: DriveJob) -> some View {
        let syncConflicts: Int = { if case let .sync(r) = a.result { return r.conflicts }; return 0 }()
        VStack(alignment: .leading, spacing: 8) {
            Text(a.phase == .cancelled ? "\(title(a)) — cancelled" : finishedHeadline(a))
                .font(.system(size: 14, weight: .semibold))
            Text(finishedDetail(a))
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            if syncConflicts > 0 {
                Text("\(syncConflicts) conflicts skipped")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { state.dismissSyncResult(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24)
    }

    // MARK: Finished — failure report

    /// The retryable failure list, drawn from whichever result carries `FailedItem`s. Sync + rehydrate
    /// both fail with `FailedItem`s (each wraps a `PlanItem`); evict has no per-file failure list.
    private func failures(_ a: DriveJob) -> [FailedItem] {
        switch a.result { case let .sync(r): r.failed; case let .rehydrate(_, f): f; default: [] }
    }

    @ViewBuilder private func failureView(_ a: DriveJob) -> some View {
        let failed = failures(a)
        let retryable = failed.filter { $0.reason.isRetryable }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(failed.count) of \(succeededCount(a) + failed.count) files didn’t \(a.kind == .rehydrate ? "download" : "sync")",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Toggle("Thumbnails", isOn: $showThumbs).toggleStyle(.switch).controlSize(.mini)
            }
            List(failed, id: \.item.destRelPath) { f in
                HStack(spacing: 8) {
                    if f.reason.isRetryable {
                        Toggle("", isOn: Binding(
                            get: { retrySelection.contains(f.item.destRelPath) },
                            set: { on in
                                if on { retrySelection.insert(f.item.destRelPath) }
                                else { retrySelection.remove(f.item.destRelPath) }
                            }))
                            .labelsHidden()
                    } else {
                        Image(systemName: "slash.circle").foregroundStyle(Theme.textFaint)
                    }
                    if showThumbs {
                        FailureThumb(state: state, hash: f.item.hash)
                            .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text((f.item.destRelPath as NSString).lastPathComponent)
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(f.reason.userText).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
            }.frame(maxHeight: .infinity)
            HStack {
                if a.kind != .evict {
                    Button("Retry \(retrySelection.count) selected") {
                        let selected = failed.filter { retrySelection.contains($0.item.destRelPath) }
                        switch a.kind {
                        case .rehydrate:
                            state.retryRehydrateFailures(selected, scopeLabel: a.scopeLabel, driveName: a.driveName)
                        default:   // .sync (.evict is excluded above)
                            state.retrySyncFailures(selected.map(\.item), drive: drive)
                        }
                    }.disabled(retrySelection.isEmpty)
                }
                Spacer()
                Button("Done") { state.dismissSyncResult(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20)
        .onAppear { retrySelection = Set(retryable.map { $0.item.destRelPath }) }   // default-on retryable
    }

    /// Count of files that succeeded, for the "N of M didn’t …" header.
    private func succeededCount(_ a: DriveJob) -> Int {
        switch a.result {
        case let .sync(r): r.copied
        case let .rehydrate(done, _): done
        default: 0
        }
    }

    private func restore(_ e: PendingDeletion) {
        Task { await state.restorePending(e) }
    }
}

/// Optional 28px thumbnail by asset hash for the failure report (only rendered when the toggle is on).
/// Reads the library's cached thumbnail; falls back to a glyph when nothing is cached.
private struct FailureThumb: View {
    @Bindable var state: AppState
    let hash: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.hairline)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
        }
        .task(id: hash) {
            image = await state.library?.thumbnails.cachedDisplayImage(
                for: ContentHash(stringValue: hash), maxPixel: 64)
        }
    }
}
