import SwiftUI
import OpenPhotoCore

struct FolderGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false

    private var orderedSelectable: [SelectableItem] {
        items.map { SelectableItem(id: $0.instanceID) }
    }
    private var selectedItems: [TimelineItem] {
        items.filter { selection.contains($0.instanceID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            content
        }
        .task(id: state.selectedFolder) {
            selection.clear(); selectMode = false       // leaving a folder ends select mode
            reload()
        }
        .task(id: state.refreshToken) { reload() }      // refresh after rescans (keep selection)
        .alert("Move \(selection.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let toEvict = selectedItems
                Task {
                    await state.evict(toEvict)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text(evictAlertMessage(total: selection.count,
                                   onlyCopy: state.onlyCopyCount(selectedItems)))
        }
    }

    @ViewBuilder private var content: some View {
        if state.selectedFolder == nil {
            ContentUnavailableView("Select a folder", systemImage: "folder")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                             spacing: Theme.gridGap)],
                          spacing: Theme.gridGap) {
                    ForEach(items, id: \.instanceID) { item in
                        cell(item)
                    }
                }
                .padding(12)
            }
            .coordinateSpace(name: "foldergrid")
            .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                         space: "foldergrid", enabled: selectMode))
        }
    }

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { PhotoCellView(item: item, library: state.library!) }
            .clipped()
            .selectionChrome(selected: selection.contains(item.instanceID), show: selectMode)
            .cellFrame(item.instanceID, in: "foldergrid")
            .contentShape(Rectangle())
            .onTapGesture {
                if selectMode {
                    if let idx = items.firstIndex(where: { $0.instanceID == item.instanceID }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: items)
                }
            }
    }

    private func reload() {
        guard let lib = state.library, let dir = state.selectedFolder else { items = []; return }
        items = (try? lib.items(inDir: dir)) ?? []
    }

    private var selectionBar: some View {
        SelectionActionBar(count: selection.count,
                           onEvict: { showEvict = true },
                           onDeselect: { selection.clear() },
                           onDone: { selection.clear(); selectMode = false })
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(state.selectedFolder?.replacingOccurrences(of: "/", with: " › ") ?? "Folders")
                .font(.system(size: 15, weight: .semibold))
            Text("\(items.count) items")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            if state.selectedFolder != nil {
                Button("Select") { selectMode = true }.controlSize(.small)
            }
            if let dir = state.selectedFolder,
               let root = state.library?.vaults.first?.rootURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [root.appendingPathComponent(dir)])
                } label: { Label("Reveal in Finder", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 48...220).frame(width: 120)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}
