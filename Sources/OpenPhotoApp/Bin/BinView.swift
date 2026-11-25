import SwiftUI
import OpenPhotoCore

struct BinView: View {
    @Bindable var state: AppState
    @State private var restoring = false
    @State private var showUniqueOnly = false
    @State private var uniqueComputing = false
    @State private var liveHashes: Set<String> = []   // live-library hashes, snapshotted when filtering

    /// Bin entries with no other copy anywhere in the live library — the only-copies. Snapshot-based:
    /// `liveHashes` is captured when the filter turns on.
    private var shownEntries: [LibraryService.BinEntry] {
        showUniqueOnly ? state.binEntries.filter { !liveHashes.contains($0.item.hash) } : state.binEntries
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bin").font(.system(size: 15, weight: .semibold))
                Text(showUniqueOnly ? "\(shownEntries.count) unique of \(state.binEntries.count)"
                                    : "\(state.binEntries.count) items")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
                Button(showUniqueOnly ? "Show All" : "Only Unique") { toggleUniqueOnly() }
                    .disabled(state.binEntries.isEmpty || uniqueComputing)
                    .help("Show only binned photos that have no other copy anywhere in your library "
                          + "(this Mac or your drives) — the ones lost for good if you empty the bin.")
                Button("Restore All") { restoreAll() }
                    .disabled(state.binEntries.isEmpty || restoring)
                    .help("Move every photo in the bin back to where it was.")
                Button("Clear Drive Bins…", role: .destructive) { confirmEmptyDriveBins() }
                    .help("Reclaim space by clearing the deleted-photo bin on each connected drive.")
                Button("Empty Bin…", role: .destructive) { confirmEmpty() }
                    .disabled(state.binEntries.isEmpty)
            }
            .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if state.binEntries.isEmpty {
                ContentUnavailableView {
                    Label("Bin is empty", systemImage: "trash")
                } description: {
                    Text("Deleted photos rest here until you empty the bin.\nNothing leaves your drives until then.")
                }
                .frame(maxHeight: .infinity)
            } else if showUniqueOnly && shownEntries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing unique", systemImage: "checkmark.circle")
                } description: {
                    Text("Every photo in the bin also exists elsewhere in your library —\nnothing here is the only copy.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(shownEntries) { entry in
                            VStack(spacing: 6) {
                                if let lib = state.library {
                                    // Same square/rounded chrome as every other grid in the app.
                                    MediaTile(
                                        id: entry.item.hash,
                                        thumbnail: ThumbnailImage(id: entry.item.hash, provider: { _ in
                                            try? await lib.thumbnails.thumbnail(
                                                for: ContentHash(stringValue: entry.item.hash), sourceURL: entry.fileURL,
                                                kind: MediaKind.of(filename: entry.fileURL.lastPathComponent) ?? .photo)
                                        }),
                                        badges: { EmptyView() })
                                }
                                Text((entry.item.path as NSString).lastPathComponent)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint).lineLimit(1)
                                Button("Restore") {
                                    Task {
                                        try? await state.library?.restore(entry)
                                        try? state.refreshQueries()
                                    }
                                }.controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    /// Toggle the "only unique" filter. Turning it on snapshots the live-library hash set off-main
    /// (a DB read), so the button stays responsive.
    private func toggleUniqueOnly() {
        if showUniqueOnly { showUniqueOnly = false; return }
        uniqueComputing = true
        Task {
            liveHashes = await state.liveLibraryHashesAsync()
            showUniqueOnly = true
            uniqueComputing = false
        }
    }

    /// Restore every binned photo to where it was. Non-destructive (you can re-delete). Snapshots the
    /// list up front since each restore removes its entry, and refreshes once at the end.
    private func restoreAll() {
        let entries = state.binEntries
        guard !entries.isEmpty else { return }
        restoring = true
        Task {
            _ = try? await state.library?.restore(entries)   // batched: one rescan per vault
            try? state.refreshQueries()
            restoring = false
        }
    }

    private func confirmEmptyDriveBins() {
        let count = state.connectedDriveBinCount()
        let alert = NSAlert()
        guard count > 0 else {
            alert.messageText = "No drive bins to clear"
            alert.informativeText = "Connected drives have nothing in their bin. (An offline drive's bin clears when you reconnect it and clear again.)"
            alert.addButton(withTitle: "OK"); alert.runModal(); return
        }
        alert.messageText = "Clear the bin on connected drives?"
        alert.informativeText = "\(count) already-deleted item\(count == 1 ? "" : "s") will be removed from your connected drives to reclaim space. Where the drive supports it they go to the drive's Trash (recoverable); otherwise they're removed permanently. Offline drives are skipped."
        alert.addButton(withTitle: "Clear Drive Bins")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = state.clearConnectedDriveBins()
        try? state.refreshQueries()
    }

    private func confirmEmpty() {
        let alert = NSAlert()
        alert.messageText = "Empty the bin?"
        alert.informativeText = "\(state.binEntries.count) items will move to the macOS Trash — still recoverable from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for vault in state.library?.vaults ?? [] {
            do {
                if FileManager.default.fileExists(atPath: vault.binDirURL.path) {
                    try FileManager.default.trashItem(at: vault.binDirURL, resultingItemURL: nil)
                }
                try AtomicFile.write(Data(), to: vault.binLogURL)   // only after successful trash
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        try? state.refreshQueries()
    }
}

