import SwiftUI
import OpenPhotoCore

/// Cross-drive integrity review: verifies every connected durable drive on appear, groups findings
/// by drive, and offers one-click repair of corrupt + missing files from a verified-good copy
/// anywhere in the connected set (canonical-authoritative; a rotten source fails safe).
struct ConsensusRepairSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var results: [(vr: VaultRecord, report: DriftReport)] = []
    @State private var progress: (drive: String, p: DriftProgress)?
    @State private var running = true
    @State private var confirmRepairAll = false

    private var repairable: [(VaultRecord, DriftFinding)] {
        results.flatMap { r in (r.report.corrupt + r.report.missing)
            .filter { if case .recoverable = $0.recoverability { true } else { false } }
            .map { (r.vr, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Verify all connected drives").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !repairable.isEmpty && !running {
                    Button("Repair all (\(repairable.count))") { confirmRepairAll = true }
                }
                Button("Done") { dismiss() }.disabled(running)
            }.padding(16)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 640, height: 520)
        .task { await verifyAll() }
        .confirmationDialog("Repair \(repairable.count) file\(repairable.count == 1 ? "" : "s")?",
                            isPresented: $confirmRepairAll, titleVisibility: .visible) {
            Button("Repair from verified-good copies") { Task { await repairEverything() } }
        } message: {
            Text("Corrupt files move to their drive's bin (recoverable) and are replaced from a "
               + "hash-verified copy on another connected drive or this Mac. A bad source fails safe.")
        }
    }

    @ViewBuilder private var content: some View {
        if running {
            VStack(spacing: 10) {
                ProgressView()
                if let progress {
                    Text("Verifying \(progress.drive)\u{2026} \(progress.p.done)/\(progress.p.total) \u{00b7} \(progress.p.currentName)")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("No connected drives", systemImage: "externaldrive")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text("Connect a canonical or backup drive to verify it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
        } else if results.allSatisfy({ $0.report.isClean }) {
            VStack(alignment: .leading, spacing: 6) {
                Label("All drives verified", systemImage: "checkmark.seal")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
                Text("Every file on every connected drive matches OpenPhoto's record.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
        } else {
            List {
                ForEach(results.filter { !$0.report.isClean }, id: \.vr.id) { r in
                    Section((r.vr.rootPath as NSString).lastPathComponent) {
                        driveFindings(r.vr, r.report)
                    }
                }
            }.listStyle(.inset)
        }
    }

    @ViewBuilder private func driveFindings(_ vr: VaultRecord, _ report: DriftReport) -> some View {
        ForEach(report.corrupt + report.missing, id: \.relPath) { f in
            HStack {
                Text(f.relPath).font(.system(size: 12)); Spacer()
                kindTag(f.kind)
                switch f.recoverability {
                case .recoverable(let src):
                    Text("from \(src)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Button("Repair") { Task { await repairOne(vr, f) } }
                case .lostNoCopy:
                    Text("\u{26a0}\u{fe0f} no good copy \u{2014} lost").font(.system(size: 11)).foregroundStyle(.red)
                case .unknown:
                    EmptyView()
                }
            }
        }
    }

    private func kindTag(_ k: DriftFinding.Kind) -> some View {
        Text(k == .corrupt ? "corrupt" : "missing")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.25), in: Capsule())
            .foregroundStyle(k == .corrupt ? Theme.amber : Theme.textDim)
    }

    private func verifyAll() async {
        running = true
        results = await state.verifyAllConnected { drive, p in
            Task { @MainActor in progress = (drive, p) }
        }
        progress = nil; running = false
    }

    private func repairOne(_ vr: VaultRecord, _ f: DriftFinding) async {
        guard let drive = state.openVault(for: vr) else { return }
        _ = await state.repairFinding(f, on: drive)
        _ = state.driftScan(drive)
        await refreshResults()
    }

    private func repairEverything() async {
        for r in results where !r.report.isClean {
            guard let drive = state.openVault(for: r.vr) else { continue }
            _ = await state.repairAllRecoverable(r.report, on: drive)
        }
        await refreshResults()
    }

    /// Re-read each drive's cached report after repairs (driftScan already refreshed driveDrift).
    private func refreshResults() async {
        results = results.map { ($0.vr, state.driveDrift[$0.vr.id] ?? $0.report) }
    }
}
