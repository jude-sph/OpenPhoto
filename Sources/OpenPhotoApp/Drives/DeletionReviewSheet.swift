import SwiftUI
import OpenPhotoCore

/// Standalone deletion-review gate. Computes eligibility on appear (no external state to go
/// stale — the lesson from Slices 1/2), defaults to all-selected, and confirms with
/// "Move N to drive bin". Restore on a row undeletes the photo and drops it from the list.
struct DeletionReviewSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [PendingDeletion]?
    @State private var selected: Set<String> = []
    @State private var result: DeletionPropagator.Result?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review Deletions — \(drive.rootURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
            }.padding(16)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 620, height: 480)
        .task { reload(defaultSelectAll: true) }
    }

    @ViewBuilder private var content: some View {
        if let result {
            ContentUnavailableView {
                Label("Moved \(result.propagated) to drive bin",
                      systemImage: result.failed > 0 ? "exclamationmark.triangle" : "checkmark.seal")
            } description: {
                Text(result.failed > 0
                     ? "\(result.failed) couldn't be moved — still queued, will retry."
                     : "The drive's copies are in its bin — recoverable, never hard-deleted.")
            }
        } else if let entries {
            if entries.isEmpty {
                ContentUnavailableView("No deletions to propagate",
                    systemImage: "checkmark.seal",
                    description: Text("Photos you delete on this Mac that still exist on \(drive.rootURL.lastPathComponent) appear here."))
            } else {
                VStack(spacing: 10) {
                    Text("These photos were deleted on this Mac and still exist on \(drive.rootURL.lastPathComponent). Confirm to move the drive's copies into its bin (recoverable).")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.top, 12)
                    DeletionListView(state: state, entries: entries,
                                     selected: $selected, onRestore: restore)
                        .padding(.horizontal, 12)
                    HStack {
                        Spacer()
                        Button("Move \(selected.count) to drive bin") { propagate() }
                            .keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
                    }.padding(16)
                }
            }
        } else {
            ProgressView().padding(24).frame(maxHeight: .infinity)
        }
    }

    private func reload(defaultSelectAll: Bool) {
        state.refreshPendingDeletions()
        let e = state.drivePendingDeletions[drive.descriptor.vaultID] ?? []
        entries = e
        selected = defaultSelectAll ? Set(e.map(\.hash)) : selected.intersection(Set(e.map(\.hash)))
    }

    private func restore(_ e: PendingDeletion) {
        Task { await state.restorePending(e); reload(defaultSelectAll: false) }
    }

    private func propagate() {
        let chosen = (entries ?? []).filter { selected.contains($0.hash) }
        Task { result = await state.propagateDeletions(drive: drive, selected: chosen) }
    }
}
