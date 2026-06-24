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
    @State private var drift: DriftPresentation?
    @State private var forgetTarget: VaultRecord?
    @State private var deletionDrive: Vault?
    @State private var cloningDriveIDs: Set<String> = []
    @State private var adoptTarget: VaultRecord?
    @State private var adoptDismissed: Set<String> = []
    // Promotion / recovery
    @State private var promoteTarget: VaultRecord?
    @State private var recoverTarget: VaultRecord?
    @State private var promoteInfo: String?           // non-nil -> show "not exact copy" info alert
    @State private var guidedPlugInTarget: VaultRecord?  // canonical absent -> show plug-in prompt
    // Conflict resolution
    @State private var canonicalConflict: VaultRecord?
    @State private var conflictDismissed: Set<String> = []
    // Cross-drive integrity
    @State private var consensusRepair = false
    // Global storage ops
    @State private var confirmEvictAll = false
    @State private var evictAllItems: [TimelineItem] = []
    @State private var plugInPrompt: String?      // drive name to prompt the user to connect

    /// A backup sync (including its slow "finishing" snapshot write) is in flight. While it runs,
    /// other drive operations are disabled — they'd contend with the same files/manifest.
    private var syncing: Bool { state.jobRunning }

    var body: some View {
        mainContent
            .sheet(item: $drift) { d in DriftReviewSheet(state: state, drive: d.drive, verify: d.verify) }
            .sheet(item: $deletionDrive) { d in DeletionReviewSheet(state: state, drive: d) }
            .sheet(isPresented: $consensusRepair) { ConsensusRepairSheet(state: state) }
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
                Button("Quick View") {
                    let root = URL(fileURLWithPath: vr.rootPath)
                    adoptTarget = nil
                    Task { await state.startQuickView(root: root) }
                }
                Button("Not now", role: .cancel) {
                    adoptDismissed.insert(vr.id)
                    adoptTarget = nil
                }
            } message: { _ in
                Text("OpenPhoto will import the drive\u{2019}s photo index so you can browse its contents immediately. This only reads the drive\u{2019}s catalog \u{2014} your original files are never modified.")
            }
            .onChange(of: state.adoptableDrive?.id) { _, _ in
                if let vr = state.adoptableDrive, !adoptDismissed.contains(vr.id) { adoptTarget = vr }
            }
            .onAppear {
                if let vr = state.adoptableDrive, !adoptDismissed.contains(vr.id) { adoptTarget = vr }
                if let vr = state.conflictingCanonical, !conflictDismissed.contains(vr.id) { canonicalConflict = vr }
            }
            .modifier(PromoteAlerts(state: state,
                                    promoteTarget: $promoteTarget,
                                    promoteInfo: $promoteInfo,
                                    guidedPlugInTarget: $guidedPlugInTarget,
                                    recoverTarget: $recoverTarget))
            .modifier(ConflictAlert(state: state,
                                    canonicalConflict: $canonicalConflict,
                                    conflictDismissed: $conflictDismissed))
            .alert("Free up space on this Mac?", isPresented: $confirmEvictAll) {
                Button("Cancel", role: .cancel) {}
                Button("Free Up Space", role: .destructive) {
                    state.startEvictJob(items: evictAllItems, scopeLabel: "all photos",
                                        driveName: state.connectedDrivesCanonicalFirst().first?.rootURL.lastPathComponent ?? "")
                    state.jobSheetDrive = state.jobDrive
                }
            } message: {
                let n = evictAllItems.count
                let bytes = evictAllItems.reduce(Int64(0)) { $0 + $1.size }
                Text("Move \(n) original\(n == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) to the Trash. They stay on your drive and you can download them back anytime.")
            }
            .confirmationDialog("Plug in your drive", isPresented: Binding(
                get: { plugInPrompt != nil }, set: { if !$0 { plugInPrompt = nil } }),
                titleVisibility: .visible, presenting: plugInPrompt) { _ in
                Button("OK", role: .cancel) { plugInPrompt = nil }
            } message: { name in
                Text("Plug in \u{201c}\(name)\u{201d} so OpenPhoto can move these photos. Then try again.")
            }
            .onChange(of: state.conflictingCanonical?.id) { _, _ in
                if let vr = state.conflictingCanonical, !conflictDismissed.contains(vr.id) { canonicalConflict = vr }
            }
    }

    // MARK: - Main content (broken out to keep body type-checkable)

    @ViewBuilder private var mainContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drives").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Add Drive\u{2026}") { state.addDriveViaPanel() }.controlSize(.small)
                Button("Quick View Folder\u{2026}") { state.quickViewFolderViaPanel() }.controlSize(.small)
                Button("Verify All Drives") { consensusRepair = true }.controlSize(.small)
                    .disabled(syncing)
                Button("Free Up Mac Space\u{2026}") { prepareEvictAll() }
                    .controlSize(.small).disabled(syncing || state.durableVaults.isEmpty)
                Button("Download All to Mac\u{2026}") { prepareRehydrateAll() }
                    .controlSize(.small).disabled(syncing || state.durableVaults.isEmpty)
            }
            .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if state.durableVaults.isEmpty {
                // Fill the area below the header so the header stays pinned to the top (otherwise the
                // intrinsic-sized empty state lets the VStack shrink and the parent centers it,
                // leaving a large blank band above the header).
                ContentUnavailableView("No canonical drive yet",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("Add a drive or folder to hold your canonical library."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.durableVaults, id: \.id) { vr in row(vr) }.listStyle(.inset)
            }
        }
    }

    // MARK: - Global storage ops

    private func prepareEvictAll() {
        let items = state.allEvictableItems()
        guard !items.isEmpty else { return }
        switch state.resolveDrive(forHashes: Set(items.map(\.hash))) {
        case .ready: evictAllItems = items; confirmEvictAll = true
        case .needsDrive(let name): plugInPrompt = name
        case .nothingToDo: break
        }
    }

    private func prepareRehydrateAll() {
        let items = state.allDriveOnlyItems()
        guard !items.isEmpty else { return }
        switch state.resolveDrive(forHashes: Set(items.map(\.hash))) {
        case .ready(let drives):
            state.startRehydrateJob(items: items, scopeLabel: "all photos",
                                    driveName: drives.first?.rootURL.lastPathComponent ?? "")
            state.jobSheetDrive = state.jobDrive
        case .needsDrive(let name): plugInPrompt = name
        case .nothingToDo: break
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
            if vr.role == "backup", !ejected {
                // "Make this the canonical" -- three branches based on canonical state
                Button("Make this the canonical") {
                    if state.isPromotable(vr) {
                        promoteTarget = vr
                    } else if state.canonicalVault.map({ !state.driveIsPresent($0) }) ?? false {
                        guidedPlugInTarget = vr
                    } else {
                        promoteInfo = "This backup isn't an exact copy of the canonical yet -- Update backup first."
                    }
                }
                .controlSize(.small)
                .disabled(!present || syncing)
            }
            if vr.id != state.canonicalVault?.id,
               let canon = state.canonicalVault, state.driveIsPresent(canon),
               !ejected {
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
                .disabled((vr.role == "backup" && behind == 0) || cloning || !present || syncing)
            }
            Button("Sync\u{2026}") { state.jobSheetDrive = state.openVault(for: vr) }
                .controlSize(.small).disabled(!present || syncing)
            Button("Check") {
                if let v = state.openVault(for: vr) { drift = DriftPresentation(drive: v, verify: false) }
            }.controlSize(.small).disabled(!present || syncing)
            Button("Verify Integrity") {
                if let v = state.openVault(for: vr) { drift = DriftPresentation(drive: v, verify: true) }
            }.controlSize(.small).disabled(!present || syncing)
            Button("Quick View") {
                Task { await state.startQuickView(root: URL(fileURLWithPath: vr.rootPath)) }
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
                if (state.drivePendingSync[vr.id] ?? 0) > 0 {
                    Button { state.jobSheetDrive = state.openVault(for: vr) } label: {
                        Label("Updates to sync \u{00b7} Sync", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11)).foregroundStyle(Theme.amber)
                    }.buttonStyle(.plain)
                } else {
                    Label("No changes", systemImage: "checkmark.seal")
                        .font(.system(size: 11)).foregroundStyle(.green)
                }
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

// MARK: - Promotion / Recovery alerts (extracted ViewModifier to keep body type-checkable)

private struct PromoteAlerts: ViewModifier {
    let state: AppState
    @Binding var promoteTarget: VaultRecord?
    @Binding var promoteInfo: String?
    @Binding var guidedPlugInTarget: VaultRecord?
    @Binding var recoverTarget: VaultRecord?

    private var promoteTitle: String {
        promoteTarget.map { "Make \"\(($0.rootPath as NSString).lastPathComponent)\" the canonical?" } ?? ""
    }
    private var recoveryMessage: String {
        guard let vr = recoverTarget else { return "" }
        if let r = state.recoveryAcknowledgment(vr) {
            return "\(r.recoverableFromMac) photo(s) will be copied from this Mac onto the new canonical; \(r.lost) exist nowhere reachable and will be lost."
        }
        return "OpenPhoto can't verify this backup against your lost canonical. It will become the new canonical as-is."
    }
    private var canonName: String {
        state.canonicalVault.map { ($0.rootPath as NSString).lastPathComponent } ?? "your canonical"
    }

    func body(content: Content) -> some View {
        content
            // --- Promote confirm ---
            .alert(promoteTitle,
                   isPresented: Binding(get: { promoteTarget != nil },
                                        set: { if !$0 { promoteTarget = nil } }),
                   presenting: promoteTarget) { vr in
                Button("Make Canonical") {
                    let target = vr
                    promoteTarget = nil
                    Task {
                        if await state.promoteToCanonical(target) == false {
                            promoteInfo = "This backup is no longer an exact copy of the canonical -- run Update backup first."
                        }
                    }
                }
                Button("Cancel", role: .cancel) { promoteTarget = nil }
            } message: { _ in
                Text("Your current canonical will become a backup.")
            }
            // --- Promote failed info alert ---
            .alert("Cannot promote yet",
                   isPresented: Binding(get: { promoteInfo != nil },
                                        set: { if !$0 { promoteInfo = nil } })) {
                Button("OK") { promoteInfo = nil }
            } message: {
                Text(promoteInfo ?? "")
            }
            // --- Guided plug-in prompt (canonical absent) ---
            .confirmationDialog(
                "Plug in your canonical",
                isPresented: Binding(get: { guidedPlugInTarget != nil },
                                     set: { if !$0 { guidedPlugInTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Recover\u{2026}") {
                    let target = guidedPlugInTarget
                    guidedPlugInTarget = nil
                    recoverTarget = target
                }
                Button("Cancel", role: .cancel) { guidedPlugInTarget = nil }
            } message: {
                Text("Plug in your current canonical (\"\(canonName)\") so OpenPhoto can confirm this backup is a complete, current copy before switching -- or, if your canonical is lost, recover from this backup instead.")
            }
            // --- Recovery confirm ---
            .alert("Recover from this backup?",
                   isPresented: Binding(get: { recoverTarget != nil },
                                        set: { if !$0 { recoverTarget = nil } }),
                   presenting: recoverTarget) { vr in
                Button("Recover", role: .destructive) {
                    let target = vr
                    recoverTarget = nil
                    Task { await state.recoverCanonical(target) }
                }
                Button("Cancel", role: .cancel) { recoverTarget = nil }
            } message: { _ in Text(recoveryMessage) }
    }
}

// MARK: - Conflict alert (extracted ViewModifier to keep body type-checkable)

private struct ConflictAlert: ViewModifier {
    let state: AppState
    @Binding var canonicalConflict: VaultRecord?
    @Binding var conflictDismissed: Set<String>

    private var conflictMessage: String {
        guard let vr = canonicalConflict else { return "" }
        let name = (vr.rootPath as NSString).lastPathComponent
        let currentName = state.canonicalVault.map { ($0.rootPath as NSString).lastPathComponent } ?? "another drive"
        return "\"\(name)\" was your previous canonical; \"\(currentName)\" is canonical now. Make it a backup (it'll need updating), or Forget it?"
    }

    func body(content: Content) -> some View {
        content
            .alert("Canonical changed",
                   isPresented: Binding(get: { canonicalConflict != nil },
                                        set: { if !$0 { canonicalConflict = nil } }),
                   presenting: canonicalConflict) { vr in
                Button("Make a Backup") {
                    state.resolveCanonicalConflict(vr, makeBackup: true)
                    canonicalConflict = nil
                }
                Button("Forget", role: .destructive) {
                    state.resolveCanonicalConflict(vr, makeBackup: false)
                    canonicalConflict = nil
                }
                Button("Cancel", role: .cancel) {
                    conflictDismissed.insert(vr.id)
                    canonicalConflict = nil
                }
            } message: { _ in
                Text(conflictMessage)
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
