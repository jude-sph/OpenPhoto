import SwiftUI
import OpenPhotoCore

/// Bundles the drive + which scan to run into one Identifiable value so `.sheet(item:)` presents
/// with the right context atomically (no separate @State that can be read stale).
private struct DriftPresentation: Identifiable {
    let id = UUID()
    let drive: Vault
    let verify: Bool
}

struct DrivesView: View {
    @Bindable var state: AppState
    @State private var syncDrive: Vault?
    @State private var drift: DriftPresentation?
    @State private var forgetTarget: VaultRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drives").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Add Drive…") { state.addDriveViaPanel() }.controlSize(.small)
            }
            .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if state.canonicalVaults.isEmpty {
                ContentUnavailableView("No canonical drive yet",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("Add a drive or folder to hold your canonical library."))
            } else {
                List(state.canonicalVaults, id: \.id) { vr in row(vr) }.listStyle(.inset)
            }
        }
        .sheet(item: $syncDrive) { drive in SyncPlanSheet(state: state, drive: drive) }
        .sheet(item: $drift) { d in DriftReviewSheet(state: state, drive: d.drive, verify: d.verify) }
        .alert("Forget “\(forgetTarget.map { ($0.rootPath as NSString).lastPathComponent } ?? "")”?",
               isPresented: Binding(get: { forgetTarget != nil },
                                    set: { if !$0 { forgetTarget = nil } }),
               presenting: forgetTarget) { vr in
            Button("Cancel", role: .cancel) { forgetTarget = nil }
            Button("Forget", role: .destructive) { state.forgetDrive(vr); forgetTarget = nil }
        } message: { _ in
            Text("Removes this drive from OpenPhoto. The files on the drive are not deleted — you can add it again later. Photos that exist only on this drive will stop appearing.")
        }
    }

    @ViewBuilder private func row(_ vr: VaultRecord) -> some View {
        let present = state.driveIsPresent(vr)
        let ejected = state.driveIsEjected(vr)
        HStack(spacing: 12) {
            Image(systemName: ejected ? "eject" : "externaldrive")
                .font(.system(size: 22)).foregroundStyle(Theme.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text((vr.rootPath as NSString).lastPathComponent).font(.system(size: 13.5, weight: .semibold))
                statusText(vr)
                statusLine(vr)
            }
            Spacer()
            Button("Sync…") { syncDrive = state.openVault(for: vr) }
                .controlSize(.small).disabled(!present)
            Button("Check") {
                if let v = state.openVault(for: vr) { drift = DriftPresentation(drive: v, verify: false) }
            }.controlSize(.small).disabled(!present)
            Button("Verify Integrity") {
                if let v = state.openVault(for: vr) { drift = DriftPresentation(drive: v, verify: true) }
            }.controlSize(.small).disabled(!present)
            driveMenu(vr)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func statusText(_ vr: VaultRecord) -> some View {
        if state.driveIsEjected(vr) {
            Text("Ejected").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        } else if state.driveFolderExists(vr) {
            Text("Connected · \(vr.rootPath)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        } else {
            Text("Not connected").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        }
    }

    @ViewBuilder private func driveMenu(_ vr: VaultRecord) -> some View {
        Menu {
            if state.driveIsEjected(vr) {
                Button { state.reconnectDrive(vr) } label: { Label("Reconnect", systemImage: "externaldrive.fill") }
            } else if state.driveFolderExists(vr) {
                Button { state.ejectDrive(vr) } label: { Label("Eject", systemImage: "eject") }
            }
            Button(role: .destructive) { forgetTarget = vr } label: {
                Label("Forget Drive…", systemImage: "minus.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
    }

    /// Passive drift status from the auto-scan cache (refreshed on connect + after any scan).
    @ViewBuilder private func statusLine(_ vr: VaultRecord) -> some View {
        if state.driveIsPresent(vr), let r = state.driveDrift[vr.id] {
            let n = r.unknown.count + r.missing.count + r.changed.count + r.corrupt.count
            if n == 0 {
                Label("No changes", systemImage: "checkmark.seal")
                    .font(.system(size: 11)).foregroundStyle(.green)
            } else {
                Button {
                    if let v = state.openVault(for: vr) { drift = DriftPresentation(drive: v, verify: false) }
                } label: {
                    Label("\(n) change\(n == 1 ? "" : "s") · Review", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }
        }
    }
}
