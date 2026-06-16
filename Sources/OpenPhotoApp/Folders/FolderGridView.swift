import SwiftUI
import OpenPhotoCore

struct FolderGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false
    @State private var showForceEvict = false
    @State private var showDelete = false
    @State private var showSend = false
    @State private var dragToMove = false

    private var orderedSelectable: [SelectableItem] {
        items.map { SelectableItem(id: $0.instanceID) }
    }
    private var selectedItems: [TimelineItem] {
        items.filter { selection.contains($0.instanceID) }
    }
    /// Evict/move-to-bin only applies to local files; drive-only assets are view-only.
    private var evictableItems: [TimelineItem] { selectedItems.filter { $0.driveRelPath == nil } }
    private var rehydratableItems: [TimelineItem] { state.rehydratableItems(selectedItems) }
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            content
        }
        .task(id: state.selectedFolder) {
            selection.clear(); selectMode = false; dragToMove = false       // leaving a folder ends select mode
            reload()
        }
        .task(id: state.photoMoveToken) { selection.clear() }   // moved items left this folder
        .task(id: state.refreshToken) { reload() }      // refresh after rescans (keep selection)
        .task(id: state.videoOnly) { reload() }          // re-filter when the video-only toggle flips
        .task(id: state.foldersRecursive) { reload() }   // re-query when include-subfolders flips
        .alert("Move \(evictableItems.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let toEvict = evictableItems
                Task {
                    await state.evict(toEvict)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text(evictAlertMessage(total: evictableItems.count,
                                   onlyCopy: state.onlyCopyCount(evictableItems)))
        }
        .alert("Delete \(evictableItems.count) photo\(evictableItems.count == 1 ? "" : "s")?",
               isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let toDelete = evictableItems
                Task {
                    await state.delete(toDelete)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text("They move to the bin (restore anytime). On connected drives, their copies are then queued for removal — review under the drive before anything is deleted there.")
        }
        .sheet(isPresented: $showSend) {
            if let target = state.connectedSendTarget() {
                SendSheet(state: state, items: selectedItems, device: target) {
                    selection.clear(); selectMode = false
                }
            }
        }
        .sheet(isPresented: $showForceEvict) {
            ForceEvictSheet(count: evictableItems.count) {
                let toEvict = evictableItems
                Task { _ = await state.evict(toEvict, mode: .forced); selection.clear(); selectMode = false }
            }
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
                                         space: "foldergrid", enabled: selectMode && !dragToMove))
            .pinchZoomGrid($state.gridMinSize)
        }
    }

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        if selectMode && dragToMove {
            tile(item).draggable(dragPayload(for: item))
        } else {
            tile(item)
        }
    }

    /// Dragging a selected tile carries the whole selection; an unselected tile just itself.
    private func dragPayload(for item: TimelineItem) -> String {
        PhotoMovePayload.encode(selection.contains(item.instanceID)
                                ? Array(selection.selected) : [item.instanceID])
    }

    @ViewBuilder private func tile(_ item: TimelineItem) -> some View {
        MediaTile(
            id: item.instanceID,
            selectMode: selectMode,
            selected: selection.contains(item.instanceID),
            rubberBandSpace: "foldergrid",
            thumbnail: ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: thumbPixels),
            badges: { TimelineTileBadges(item: item, backedUp: state.isBackedUpOnCanonical(item)) },
            onTap: {
                if selectMode {
                    if let idx = items.firstIndex(where: { $0.instanceID == item.instanceID }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: items)
                }
            })
    }

    private func reload() {
        guard let lib = state.library, let dir = state.selectedFolder else { items = []; return }
        let all = (try? lib.items(inDir: dir, recursive: state.foldersRecursive)) ?? []
        items = state.videoOnly ? all.filter { $0.kind == MediaKind.video.rawValue } : all
    }

    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            moveControls: AnyView(moveControls),
            sendTargetName: state.connectedSendTarget()?.name,
            onSend: { showSend = true },
            onDelete: { if !evictableItems.isEmpty { showDelete = true } },
            onEvict: { if !evictableItems.isEmpty { showEvict = true } },
            onForceEvict: { if !evictableItems.isEmpty { showForceEvict = true } },
            showRehydrate: !rehydratableItems.isEmpty,
            onRehydrate: { let items = rehydratableItems
                           Task { _ = await state.rehydrate(items); selection.clear(); selectMode = false } },
            tagControls: AnyView(TagPersonMenu(
                state: state, hashes: selectedItems.map(\.hash),
                onDone: { selection.clear(); selectMode = false; dragToMove = false })),
            shareControls: AnyView(
                ShareLink(items: state.localFileURLs(for: selectedItems)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }.controlSize(.small)),
            onDeselect: { selection.clear() },
            onDone: { selection.clear(); selectMode = false; dragToMove = false })
    }

    /// A single "Move to…" folder menu (plus the drag-to-move toggle). Pick a destination and the
    /// selected photos move there immediately — no inline new-folder field.
    private var moveControls: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $dragToMove) {
                Label("Drag to Move", systemImage: "hand.draw")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Drag selected photos onto a folder in the sidebar. Turn off to rubber-band select again.")
            Menu("Move to\u{2026}") {
                ForEach(allFolders, id: \.self) { f in
                    if f != state.selectedFolder {
                        Button(folderMenuLabel(f)) {
                            let ids = selection.selected
                            // Optimistic: the moved photos leave this folder's grid immediately; the
                            // actual file move + rescan run in the background and reconcile on refresh.
                            items.removeAll { ids.contains($0.instanceID) }
                            selection.clear()
                            Task { await state.movePhotos(ids: Array(ids), into: f) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .disabled(selection.count == 0)
        }
    }

    private var allFolders: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { paths.append(n.path); walk(n.children) } }
        walk(state.folderTree)
        return paths.sorted()
    }
    /// Human label for a folder path in the move menu ("" = library root).
    private func folderMenuLabel(_ path: String) -> String {
        if path.isEmpty { return state.folderTree.first { $0.path == "" }?.name ?? "Library Root" }
        return path.replacingOccurrences(of: "/", with: " \u{203A} ")
    }

    /// Header label for the selected folder; the root node has dirPath "" so show its display name.
    private var breadcrumb: String {
        guard let dir = state.selectedFolder else { return "Folders" }
        if dir.isEmpty { return state.folderTree.first { $0.path == "" }?.name ?? "Library Root" }
        return dir.replacingOccurrences(of: "/", with: " › ")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(breadcrumb)
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
            if state.selectedFolder != nil {
                Toggle(isOn: Binding(get: { state.foldersRecursive },
                                     set: { state.foldersRecursive = $0 })) {
                    Image(systemName: "rectangle.stack")
                }
                .toggleStyle(.button).controlSize(.small).help("Include photos from subfolders")
                Toggle(isOn: Binding(get: { state.videoOnly },
                                     set: { state.videoOnly = $0 })) {
                    Image(systemName: "video.fill")
                }
                .toggleStyle(.button).controlSize(.small).help("Show videos only")
            }
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 48...220).frame(width: 120)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}
