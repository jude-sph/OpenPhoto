import SwiftUI
import OpenPhotoCore

struct DrivesView: View {
    @Bindable var state: AppState
    @State private var syncDrive: Vault?
    @State private var driftDrive: Vault?
    @State private var driftReport: DriftReport?
    @State private var verifying = false

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
        .sheet(item: $syncDrive) { drive in
            SyncPlanSheet(state: state, drive: drive)
        }
        .sheet(item: $driftDrive) { drive in
            DriftReviewSheet(state: state, drive: drive, report: driftReport ?? DriftReport())
        }
    }

    @ViewBuilder private func row(_ vr: VaultRecord) -> some View {
        let present = state.driveIsPresent(vr)
        HStack(spacing: 12) {
            Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(Theme.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text((vr.rootPath as NSString).lastPathComponent).font(.system(size: 13.5, weight: .semibold))
                Text(present ? "Connected · \(vr.rootPath)" : "Not connected")
                    .font(.system(size: 11)).foregroundStyle(present ? Theme.textDim : Theme.textFaint)
            }
            Spacer()
            Button("Sync…") {
                syncDrive = state.openVault(for: vr)
            }.controlSize(.small).disabled(!present)
            Button("Check") {
                if let v = state.openVault(for: vr) { driftReport = state.driftScan(v); driftDrive = v }
            }.controlSize(.small).disabled(!present)
            Button("Verify Integrity") {
                if let v = state.openVault(for: vr) {
                    verifying = true
                    Task {
                        let r = await state.verifyIntegrity(v) { _ in }
                        driftReport = r; driftDrive = v; verifying = false
                    }
                }
            }.controlSize(.small).disabled(!present || verifying)
        }
        .padding(.vertical, 4)
    }
}
