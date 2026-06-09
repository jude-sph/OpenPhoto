import SwiftUI
import OpenPhotoCore

struct DriftReviewSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @State var report: DriftReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drive changes — \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)
            Divider().overlay(Theme.hairline)
            if report.isClean {
                ContentUnavailableView("No changes", systemImage: "checkmark.seal",
                    description: Text("The drive matches OpenPhoto's record."))
            } else {
                List {
                    if !report.unknown.isEmpty {
                        Section("Unknown files (added outside OpenPhoto)") {
                            ForEach(report.unknown, id: \.relPath) { f in
                                HStack {
                                    Text(f.relPath).font(.system(size: 12))
                                    Spacer()
                                    Button("Adopt") {
                                        state.adoptDriftFile(relPath: f.relPath, on: drive)
                                        report = state.driftScan(drive)
                                    }
                                }
                            }
                        }
                    }
                    if !report.missing.isEmpty {
                        Section("Missing files") {
                            ForEach(report.missing, id: \.relPath) { f in
                                HStack {
                                    Text(f.relPath).font(.system(size: 12))
                                    Spacer()
                                    HStack(spacing: 8) {
                                        recoverabilityLabel(f.recoverability)
                                        if case .recoverable = f.recoverability {
                                            Button("Restore") {
                                                _ = state.restoreDriftFile(f, on: drive)
                                                report = state.driftScan(drive)
                                            }
                                        }
                                        Button("Acknowledge gone") {
                                            state.acknowledgeGone(relPath: f.relPath, on: drive)
                                            report = state.driftScan(drive)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !(report.changed + report.corrupt).isEmpty {
                        Section("Changed / corrupt (report only)") {
                            ForEach(report.changed + report.corrupt, id: \.relPath) { f in
                                HStack {
                                    Text(f.relPath).font(.system(size: 12))
                                    Spacer()
                                    recoverabilityLabel(f.recoverability)
                                }
                            }
                        }
                    }
                }.listStyle(.inset)
            }
        }.frame(width: 600, height: 460)
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
