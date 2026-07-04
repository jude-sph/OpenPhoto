import SwiftUI
import OpenPhotoCore

/// The reconnect "changes since last connect" review. Two groups: the offline edits you made on this
/// Mac (moves + deletions) to propagate or undo (drive = ground truth), and drift found on the drive
/// (added / missing / changed) with the usual adopt / restore / acknowledge. Per-row immediate actions
/// with per-section bulk; nothing touches the drive until you act. Corruption stays in Verify Integrity.
struct ReviewChangesSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var payload: ReviewChanges?
    /// Non-nil while an action is running — shows the busy overlay so the sheet never looks frozen.
    @State private var busy: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes since last connect — \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.disabled(busy != nil)
            }.padding(16)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 640, height: 520)
        .overlay { if let busy { busyOverlay(busy) } }
        .animation(.default, value: busy)
        .task { await load() }
    }

    /// Blocking progress overlay shown while an action runs. Propagating to a drive does real file I/O
    /// (copies/moves), so a batch can take a while — this makes it visible instead of a frozen sheet.
    @ViewBuilder private func busyOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.45)                       // scrim also blocks taps on the controls below
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            }
            .padding(28)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var content: some View {
        if let payload {
            if payload.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("All caught up", systemImage: "checkmark.seal")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
                    Text("This drive matches your Mac.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
            } else {
                List {
                    moves(payload.ops.filter { $0.op == "moveFile" })
                    folderChanges(payload.ops.filter { $0.op != "moveFile" })
                    deletions(payload.deletions)
                    driftFindings(payload.drift)
                }.listStyle(.inset)
            }
        } else {
            ProgressView().padding(24).frame(maxHeight: .infinity)
        }
    }

    // MARK: Group A — your offline changes

    @ViewBuilder private func moves(_ ops: [PendingFolderOp]) -> some View {
        if !ops.isEmpty {
            Section {
                ForEach(ops, id: \.id) { op in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lastComponent(op.dst ?? op.src)).font(.system(size: 12))
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(dirLabel(op.src)) → \(dirLabel(op.dst))")
                                .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Button("Undo") { act("Undoing") { await state.reviewUndo(op) } }.controlSize(.small)
                        Button("Propagate") { act("Propagating") { await state.reviewPropagate(op) } }.controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Moved here (\(ops.count))"); Spacer()
                    Button("Propagate all") { propagateAllWithProgress("Propagating", ops) }
                        .font(.system(size: 11))
                    Button("Undo all") { runBatch("Undoing", ops) { await state.reviewUndo($0) } }
                        .font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder private func folderChanges(_ ops: [PendingFolderOp]) -> some View {
        if !ops.isEmpty {
            Section {
                ForEach(ops, id: \.id) { op in
                    HStack {
                        Text(folderOpLabel(op)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Apply") { act("Applying") { await state.reviewPropagate(op) } }.controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Folder changes (\(ops.count))"); Spacer()
                    Button("Apply all") { propagateAllWithProgress("Applying", ops) }
                        .font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder private func deletions(_ entries: [PendingDeletion]) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries, id: \.hash) { e in
                    HStack {
                        Text(e.relPath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Restore") { act("Restoring") { await state.restorePending(e) } }.controlSize(.small)
                        Button("Bin on drive") {
                            act("Removing from drive") { _ = await state.propagateDeletions(drive: drive, selected: [e]) }
                        }.controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Deleted here (\(entries.count))"); Spacer()
                    Button("Bin all on drive") {
                        act("Removing \(entries.count) from drive") {
                            _ = await state.propagateDeletions(drive: drive, selected: entries)
                        }
                    }.font(.system(size: 11))
                    Button("Restore all") { runBatch("Restoring", entries) { await state.restorePending($0) } }
                        .font(.system(size: 11))
                }
            }
        }
    }

    // MARK: Group B — drift found on the drive (mirrors DriftReviewSheet; corrupt is Verify-only)

    @ViewBuilder private func driftFindings(_ r: DriftReport) -> some View {
        if !r.unknown.isEmpty {
            Section {
                ForEach(r.unknown, id: \.relPath) { f in
                    HStack {
                        Text(f.relPath).font(.system(size: 12)); Spacer()
                        Button("Adopt") { adoptWithProgress([f.relPath]) }
                    }
                }
            } header: {
                HStack {
                    Text("Found on the drive (added outside OpenPhoto)"); Spacer()
                    Button("Adopt all") { adoptWithProgress(r.unknown.map(\.relPath)) }
                        .font(.system(size: 11))
                }
            }
        }
        if !r.missing.isEmpty {
            let recoverable = r.missing.filter { if case .recoverable = $0.recoverability { true } else { false } }
            Section {
                ForEach(r.missing, id: \.relPath) { f in
                    HStack {
                        Text(f.relPath).font(.system(size: 12)); Spacer()
                        HStack(spacing: 8) {
                            recoverabilityLabel(f.recoverability)
                            if case .recoverable = f.recoverability {
                                Button("Restore") { setDrift(state.restoreDriftFile(f, on: drive)) }
                            }
                            Button("Acknowledge gone") { setDrift(state.acknowledgeGone(relPath: f.relPath, on: drive)) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Missing from the drive"); Spacer()
                    if !recoverable.isEmpty {
                        Button("Restore all recoverable") { setDrift(state.restoreAllRecoverable(recoverable, on: drive)) }
                            .font(.system(size: 11))
                    }
                }
            }
        }
        if !r.changed.isEmpty {
            Section("Changed on the drive (report only)") {
                ForEach(r.changed, id: \.relPath) { f in
                    HStack {
                        Text(f.relPath).font(.system(size: 12)); Spacer()
                        recoverabilityLabel(f.recoverability)
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func load() async {
        _ = state.driftScan(drive)                       // fresh fast scan, then read the payload
        payload = state.reviewPayload(forDrive: drive)
    }
    private func reload() { payload = state.reviewPayload(forDrive: drive) }

    /// Run an async action, then refresh the payload from the catalog (ops/deletions drop out as resolved).
    /// Run one async action behind the busy overlay, then refresh.
    private func act(_ label: String = "Working", _ body: @escaping () async -> Void) {
        Task { busy = "\(label)…"; await body(); busy = nil; reload() }
    }

    /// Run a batch of async actions one at a time, showing "label i of n" progress, then refresh once.
    private func runBatch<T>(_ label: String, _ items: [T], _ body: @escaping (T) async -> Void) {
        Task {
            let n = items.count
            for (i, it) in items.enumerated() {
                busy = "\(label) \(i + 1) of \(n)\u{2026}"
                await body(it)
            }
            busy = nil
            reload()
        }
    }

    /// Propagate ALL queued ops with progress, reconciling once at the end (not per op).
    private func propagateAllWithProgress(_ label: String, _ ops: [PendingFolderOp]) {
        Task {
            busy = "\(label) \(ops.count)\u{2026}"
            await state.reviewPropagateAll(ops) { done, total in busy = "\(label) \(done) of \(total)\u{2026}" }
            busy = nil
            reload()
        }
    }

    /// Adopt drift files off-main with live progress ("Adopting 1500 of 3000…"), then merge the fresh
    /// report. The heavy work is batched + off the main actor, so the sheet stays responsive.
    private func adoptWithProgress(_ relPaths: [String]) {
        Task {
            busy = "Adopting \(relPaths.count) photo\(relPaths.count == 1 ? "" : "s")\u{2026}"
            let report = await state.adoptAll(relPaths, on: drive) { done, total in
                if done % 20 == 0 || done == total {
                    Task { @MainActor in busy = "Adopting \(done) of \(total)\u{2026}" }
                }
            }
            busy = nil
            setDrift(report)
        }
    }

    /// A drift action returns the updated report; merge it into the payload without a full re-scan.
    private func setDrift(_ r: DriftReport) {
        if var p = payload { p.drift = r; payload = p }
    }

    private func lastComponent(_ path: String?) -> String { ((path ?? "") as NSString).lastPathComponent }
    private func dirLabel(_ path: String?) -> String {
        let dir = ((path ?? "") as NSString).deletingLastPathComponent
        return dir.isEmpty ? "Library root" : dir
    }
    private func folderOpLabel(_ op: PendingFolderOp) -> String {
        switch op.op {
        case "move":   return "Moved folder → \(op.dst ?? "")"
        case "rename": return "Renamed folder → \(op.dst ?? "")"
        case "create": return "New folder \(op.dst ?? "")"
        case "delete": return "Removed folder \(op.src ?? "")"
        default:       return op.dst ?? op.src ?? op.op
        }
    }

    @ViewBuilder private func recoverabilityLabel(_ r: Recoverability) -> some View {
        switch r {
        case .recoverable(let src): Text("restorable from \(src)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        case .lostNoCopy: Text("⚠️ no good copy — lost").font(.system(size: 11)).foregroundStyle(.red)
        case .unknown: EmptyView()
        }
    }
}
