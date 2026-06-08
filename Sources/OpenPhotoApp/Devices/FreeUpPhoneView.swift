import SwiftUI
import OpenPhotoCore

/// Opt-in deletion flow — spec §5. Nothing preselected; only registry-verified
/// items are listed; deletion is per-item with per-item failure reporting.
struct FreeUpPhoneView: View {
    let source: any ImportSource
    let registry: ImportRegistry
    let library: LibraryService          // for the device-delete sync-log event
    let vault: Vault
    let deviceItems: [ImportItem]
    let sessionImportedIDs: Set<String>
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var deleting = false
    @State private var results: [DeleteResult]?
    @State private var confirming = false

    private var verifiedOnDevice: [ImportItem] {
        deviceItems.filter { item in
            let taken = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
            return registry.contains(sourceKey: source.sourceKey, name: item.name,
                                     size: item.byteSize, takenAt: taken)
        }
    }
    private var thisSession: [ImportItem] {
        verifiedOnDevice.filter { sessionImportedIDs.contains($0.id) }
    }
    private var previous: [ImportItem] {
        verifiedOnDevice.filter { !sessionImportedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Free up space on \(source.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss(); onDone() }
            }
            .padding(16)
            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) {
                chip("This session") { selection = Set(thisSession.map(\.id)) }
                chip("Screenshots") {
                    selection = Set(verifiedOnDevice
                        .filter { $0.name.lowercased().hasSuffix(".png") }.map(\.id))
                }
                chip("All") { selection = Set(verifiedOnDevice.map(\.id)) }
                chip("None") { selection.removeAll() }
                Spacer()
                Text("\(selection.count) selected")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            ScrollView {
                if !thisSession.isEmpty {
                    sectionGrid("IMPORTED THIS SESSION", thisSession)
                }
                if !previous.isEmpty {
                    DisclosureGroup("Previously imported, still on \(source.displayName) (\(previous.count))") {
                        sectionGrid(nil, previous)
                    }
                    .padding(.horizontal, 16)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                }
                if let results {
                    resultsList(results)
                }
            }

            Divider().overlay(Theme.hairline)
            HStack {
                Text("Only photos verified in your library are listed.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Spacer()
                if deleting { ProgressView().controlSize(.small) }
                Button("Delete \(selection.count) from \(source.displayName)…", role: .destructive) {
                    confirming = true
                }
                .disabled(selection.isEmpty || deleting)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .confirmationDialog(
            "Delete \(selection.count) photos from \(source.displayName)?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Delete — immediate and permanent on the device", role: .destructive) {
                Task { await runDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There is no Recently Deleted on the device for USB deletion. Verified copies exist in your library.")
        }
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered).controlSize(.small)
    }

    private func sectionGrid(_ title: String?, _ items: [ImportItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 10.5, weight: .semibold)).kerning(0.4)
                    .foregroundStyle(Theme.textFaint).padding(.horizontal, 16)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(items) { item in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay {
                            ImportItemCell(item: item, source: source,
                                           alreadyImported: false,
                                           importedThisSession: false,
                                           selected: selection.contains(item.id),
                                           onToggle: {
                                               if selection.contains(item.id) { selection.remove(item.id) }
                                               else { selection.insert(item.id) }
                                           })
                        }
                        .clipped()
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func resultsList(_ results: [DeleteResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let failed = results.filter { $0.error != nil }
            Label("\(results.count - failed.count) deleted from device" +
                  (failed.isEmpty ? "" : " · \(failed.count) failed"),
                  systemImage: failed.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(failed.isEmpty ? Theme.green : Theme.amber)
            ForEach(failed, id: \.itemID) { f in
                Text("• \(f.itemID): \(f.error ?? "")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func runDelete() async {
        deleting = true
        defer { deleting = false }
        let toDelete = verifiedOnDevice.filter { selection.contains($0.id) }
        let r = (try? await source.delete(toDelete)) ??
            toDelete.map { DeleteResult(itemID: $0.id, error: "delete request failed") }
        results = r
        let failed = r.filter { $0.error != nil }.count
        library.appendSyncLog(vault: vault, event: "device-delete",
            summary: "\(r.count - failed) deleted from \(source.displayName), \(failed) failed",
            counterpartyKey: source.sourceKey)
        selection.removeAll()
    }
}
