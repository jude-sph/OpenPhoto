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
    @State private var deletionDrive: Vault?
    @State private var cloningDriveIDs: Set<String> = []
    @State private var adoptTarget: VaultRecord?
    @State private var adoptDismissed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drives").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Add Drive\u{2026}") { state.addDriveViaPanel() }.controlSize(.small)
            }
            .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if state.durableVaults.isEmpty {
                ContentUnavailableView("No canonical drive yet",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("Add a drive or folder to hold your canonical library."))
            } else {
                List(state.durableVaults, id: \.id) { vr in row(vr) }.listStyle(.inset)
            }
        }
        .sheet(item: $syncDrive) { drive in SyncPlanSheet(state: state, drive: drive) }
        .sheet(item: $drift) { d in DriftReviewSheet(state: state, drive: d.drive, verify: d.verify) }
        .sheet(item: $deletionDrive) { d in DeletionReviewSheet(state: state, drive: d) }
        .alert("Forget \u{201c}\(forgetTarget.map { ($0.rootPath as NSString).lastPathComponent } ?? "")\u{201d}?",
               isPresented: Binding(get: { forgetTarget != nil },
                                    set: { if !$0 { forgetTarget = nil } }),
               presenting: forgetTarget) { vr in
            Button("Cancel", role: .cancel) { forgetTarget = nil }
            Button("Forget", role: .destructive) { state.forgetDrive(vr); forgetTarget = nil }
        } message: { _ in
            Text("Removes this drive from OpenPhoto. The files on the drive are not deleted \u{2014} you can add it again later. Photos that exist only on this drive will stop appearing.")
        }
        .alert(adoptTarget.map { vr in
            let name = (vr.rootPath as NSString).lastPathComponent
            let count = state.adoptablePhotoCount(vr)
            return "\u{201c}\(name)\u{201d} carries a photo library (\(count) photos). Adopt it so you can browse it here?"
        } ?? "",
               isPresented: Binding(get: { adoptTarget != nil },
                                    set: { if !$0 { adoptTarget = nil } }),
               presenting: adoptTarget) { vr in
            Button("Adopt") {
                let vaultRecord = vr
                adoptTarget = nil
                Task { await state.adoptDrive(vaultRecord) }
            }
            Button("Not now", role: .cancel) {
                adoptDismissed.insert(vr.id)
                adoptTarget = nil
            }
        } message: { _ in
            Text("OpenPhoto will import the drive\u{2019}s photo index so you can browse its contents immediately. This only reads the drive\u{2019}s catalog \u{2014} your original files are never modified.")
        }
        .onChange(of: state.adoptableDrive?.id) { _, _ in
            if let vr = state.adoptableDrive, !adoptDismissed.contains(vr.id) {
                adoptTarget = vr
            }
        }
        .onAppear {
            if let vr = state.adoptableDrive, !adoptDismissed.contains(vr.id) {
                adoptTarget = vr
            }
        }
    }

    @ViewBuilder private func row(_ vr: VaultRecord) -> some View {
        let present = state.driveIsPresent(vr)
        let ejected = state.driveIsEjected(vr)
        HStack(spacing: 12) {
            Image(systemName: ejected ? "eject" : state.driveKind(vr).symbol)
                .font(.system(size: 22)).foregroundStyle(Theme.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text((vr.rootPath as NSString).lastPathComponent).font(.system(size: 13.5, weight: .semibold))
                statusText(vr)
                statusLine(vr)
                pendingDeletionsLine(vr)
            }
            Spacer()
            if vr.id != state.canonicalVault?.id,
               let canon = state.canonicalVault, state.driveIsPresent(canon),
               !state.driveIsEjected(vr) {
                let behind = state.backupBehindCount(vr)
                let cloning = cloningDriveIDs.contains(vr.id)
                Button(vr.role == "backup" ? (behind > 0 ? "Update backup (\(behind))" : "Up to date")
                                           : "Make backup") {
                    cloningDriveIDs.insert(vr.id)
                    Task {
                        _ = await state.cloneToBackup(vr)
                        cloningDriveIDs.remove(vr.id)
                    }
                }
                .controlSize(.small)
                .disabled((vr.role == "backup" && behind == 0) || cloning || !present)
            }
            Button("Sync\u{2026}") { syncDrive = state.openVault(for: vr) }
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
        let kind = state.driveKind(vr).label
        let roleLabel = vr.role == "canonical" ? "Canonical" : vr.role == "backup" ? "Backup" : nil
        let kindWithRole = roleLabel.map { "\($0) \u{00b7} \(kind)" } ?? kind
        if state.driveIsEjected(vr) {
            Text("\(kindWithRole) \u{00b7} Ejected").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        } else if state.driveFolderExists(vr) {
            Text("\(kindWithRole) \u{00b7} Connected \u{00b7} \(vr.rootPath)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        } else {
            Text("\(kindWithRole) \u{00b7} Not connected").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
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
                Label("Forget Drive\u{2026}", systemImage: "minus.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
    }

    /// Pending-deletions indicator \u{2014} opens the standalone review sheet. Honest count from the
    /// eligibility cache (refreshed on connect + after any delete/restore/sync/propagate).
    @ViewBuilder private func pendingDeletionsLine(_ vr: VaultRecord) -> some View {
        if state.driveIsPresent(vr), let pend = state.drivePendingDeletions[vr.id], !pend.isEmpty {
            Button {
                if let v = state.openVault(for: vr) { deletionDrive = v }
            } label: {
                Label("\(pend.count) deletion\(pend.count == 1 ? "" : "s") pending \u{00b7} Review",
                      systemImage: "trash")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }.buttonStyle(.plain)
        }
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
                    Label("\(n) change\(n == 1 ? "" : "s") \u{00b7} Review", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }
        }
    }
}

private extension DriveKind {
    var label: String {
        switch self {
        case .removable: "External Drive"
        case .network: "Network"
        case .folder: "Folder"
        case .unknown: "Drive"
        }
    }
    var symbol: String {
        switch self {
        case .removable: "externaldrive"
        case .network: "network"
        case .folder: "folder"
        case .unknown: "externaldrive"
        }
    }
}
