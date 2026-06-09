import SwiftUI
import OpenPhotoCore

struct SyncPlanSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var plan: SyncPlan?
    @State private var freeBytes: Int64 = 0
    @State private var progress: SyncProgress?
    @State private var result: SyncResult?
    @State private var running = false
    @State private var deletionSelection: Set<String> = []

    private var volume: FileSystemVolume { FileSystemVolume(rootURL: drive.rootURL) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync to \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }.disabled(running)
            }.padding(16)
            Divider().overlay(Theme.hairline)
            Group {
                if let result { resultView(result) }
                else if let p = progress { progressView(p) }
                else if let plan { planView(plan) }
                else { ProgressView().padding(24) }
            }.frame(maxHeight: .infinity)
        }
        .frame(width: 540, height: 360)
        .task { await computePlan() }
    }

    private func computePlan() async {
        guard let lib = state.library else { return }
        let engine = SyncEngine(library: lib)
        plan = (try? engine.plan(sources: lib.vaults, destinationVault: drive)) ?? SyncPlan()
        freeBytes = (try? volume.freeSpaceBytes()) ?? 0
    }

    @ViewBuilder private func planView(_ plan: SyncPlan) -> some View {
        let enough = freeBytes >= plan.totalCopyBytes
        VStack(alignment: .leading, spacing: 10) {
            Text("\(plan.copies.count) new photos · \(byteString(plan.totalCopyBytes))")
                .font(.system(size: 14, weight: .medium))
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
                Button("Sync") { Task { await runApply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enough || (plan.copies.isEmpty && plan.sidecarUpdates.isEmpty
                                          && deletionSelection.isEmpty))
            }
        }.padding(24)
    }

    @ViewBuilder private func progressView(_ p: SyncProgress) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(Theme.accent)
            Text("\(p.stage.rawValue.capitalized)… \(p.done)/\(p.total) · \(p.currentName)")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
        }.padding(24)
    }

    @ViewBuilder private func resultView(_ r: SyncResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync complete").font(.system(size: 14, weight: .semibold))
            Text("\(r.copied) copied · \(r.skipped) already there · \(r.sidecarsWritten) sidecars")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            if r.conflicts > 0 || !r.failed.isEmpty {
                Text("\(r.conflicts) conflicts · \(r.failed.count) failed")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24)
    }

    private func runApply() async {
        guard !running, let plan, let lib = state.library else { return }
        running = true
        let engine = SyncEngine(library: lib)
        let r = await engine.apply(plan, destinationVault: drive, volume: volume) { p in
            Task { @MainActor in progress = p }
        }
        try? state.refreshCanonicalPresence(driveVault: drive)
        let pending = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
        let chosen = pending.filter { deletionSelection.contains($0.hash) }
        if !chosen.isEmpty { _ = await state.propagateDeletions(drive: drive, selected: chosen) }
        result = r
        running = false
    }

    private func restore(_ e: PendingDeletion) {
        Task { await state.restorePending(e) }
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
