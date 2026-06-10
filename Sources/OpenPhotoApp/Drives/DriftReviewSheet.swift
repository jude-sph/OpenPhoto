import SwiftUI
import OpenPhotoCore

/// Drift / integrity review. Computes its own report on appear (no external state to go stale),
/// shows progress for the slow Verify pass, and offers the safe fixes + bulk actions.
struct DriftReviewSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    let verify: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var report: DriftReport?
    @State private var progress: DriftProgress?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((verify ? "Integrity check — " : "Drive changes — ") + drive.rootURL.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 620, height: 480)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let report {
            if report.isClean {
                // Top-aligned (like the Sync sheet) rather than vertically centered, so there's no
                // large empty gap below the header.
                VStack(alignment: .leading, spacing: 6) {
                    Label(verify ? "Integrity verified" : "No changes", systemImage: "checkmark.seal")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
                    Text(verify ? "Every file matches OpenPhoto's record."
                                : "The drive matches OpenPhoto's record.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            } else {
                findings(report)
            }
        } else if let progress {
            VStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(Theme.accent)
                Text("Verifying… \(progress.done)/\(progress.total) · \(progress.currentName)")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            }.padding(24).frame(maxHeight: .infinity)
        } else {
            ProgressView().padding(24).frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func findings(_ r: DriftReport) -> some View {
        List {
            if !r.unknown.isEmpty {
                Section {
                    ForEach(r.unknown, id: \.relPath) { f in
                        HStack {
                            Text(f.relPath).font(.system(size: 12)); Spacer()
                            Button("Adopt") { report = state.adoptDriftFile(relPath: f.relPath, on: drive) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Unknown files (added outside OpenPhoto)"); Spacer()
                        Button("Adopt all") { report = state.adoptAll(r.unknown.map(\.relPath), on: drive) }
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
                                    Button("Restore") { report = state.restoreDriftFile(f, on: drive) }
                                }
                                Button("Acknowledge gone") {
                                    report = state.acknowledgeGone(relPath: f.relPath, on: drive)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Missing files"); Spacer()
                        if !recoverable.isEmpty {
                            Button("Restore all recoverable") {
                                report = state.restoreAllRecoverable(recoverable, on: drive)
                            }.font(.system(size: 11))
                        }
                    }
                }
            }
            if !(r.changed + r.corrupt).isEmpty {
                Section("Changed / corrupt (report only)") {
                    ForEach(r.changed + r.corrupt, id: \.relPath) { f in
                        HStack {
                            Text(f.relPath).font(.system(size: 12)); Spacer()
                            recoverabilityLabel(f.recoverability)
                        }
                    }
                }
            }
        }.listStyle(.inset)
    }

    private func load() async {
        guard report == nil else { return }
        if verify {
            report = await state.verifyIntegrity(drive) { p in Task { @MainActor in progress = p } }
        } else {
            report = state.driftScan(drive)
        }
    }

    @ViewBuilder private func recoverabilityLabel(_ r: Recoverability) -> some View {
        switch r {
        case .recoverable(let src):
            Text("restorable from \(src)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        case .lostNoCopy:
            Text("⚠️ no good copy — lost").font(.system(size: 11)).foregroundStyle(.red)
        case .unknown:
            EmptyView()
        }
    }
}
