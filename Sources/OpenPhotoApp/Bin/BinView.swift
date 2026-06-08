import SwiftUI
import OpenPhotoCore

struct BinView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bin").font(.system(size: 15, weight: .semibold))
                Text("\(state.binEntries.count) items")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
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
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(state.binEntries) { entry in
                            VStack(spacing: 6) {
                                BinThumb(entry: entry, library: state.library!)
                                    .frame(height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
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

    private func confirmEmpty() {
        let alert = NSAlert()
        alert.messageText = "Empty the bin?"
        alert.informativeText = "\(state.binEntries.count) items will move to the macOS Trash — still recoverable from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Recycle each vault's whole bin/ dir (files + their sidecars) to macOS
        // Trash — never unlink — then reset the bin log.
        for vault in state.library?.vaults ?? [] {
            if FileManager.default.fileExists(atPath: vault.binDirURL.path) {
                NSWorkspace.shared.recycle([vault.binDirURL])
            }
            try? AtomicFile.write(Data(), to: vault.binLogURL)
        }
        try? state.refreshQueries()
    }
}

private struct BinThumb: View {
    let entry: LibraryService.BinEntry
    let library: LibraryService
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Theme.tile
            if let image {
                Image(decorative: image, scale: 1).resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task {
            let e = entry, lib = library
            image = await Task.detached {
                try? await lib.thumbnails.thumbnail(
                    for: ContentHash(stringValue: e.item.hash), sourceURL: e.fileURL,
                    kind: MediaKind.of(filename: e.fileURL.lastPathComponent) ?? .photo)
            }.value
        }
    }
}
