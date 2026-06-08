import SwiftUI
import OpenPhotoCore

struct FolderGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            if state.selectedFolder == nil {
                ContentUnavailableView("Select a folder", systemImage: "folder")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                                 spacing: Theme.gridGap)],
                              spacing: Theme.gridGap) {
                        ForEach(items, id: \.instanceID) { item in
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    PhotoCellView(item: item, library: state.library!) {
                                        Task {
                                            try? await state.library?.delete(item)
                                            try? state.refreshQueries()
                                            reload()
                                        }
                                    }
                                }
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { state.openViewer(item, within: items) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task(id: state.selectedFolder) { reload() }
        .task(id: state.refreshToken) { reload() }      // refresh after rescans
    }

    private func reload() {
        guard let lib = state.library, let dir = state.selectedFolder else { items = []; return }
        items = (try? lib.items(inDir: dir)) ?? []
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(state.selectedFolder?.replacingOccurrences(of: "/", with: " › ") ?? "Folders")
                .font(.system(size: 15, weight: .semibold))
            Text("\(items.count) items")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            if let dir = state.selectedFolder,
               let root = state.library?.vaults.first?.rootURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [root.appendingPathComponent(dir)])
                } label: { Label("Reveal in Finder", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }
}
