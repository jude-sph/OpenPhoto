import SwiftUI
import OpenPhotoCore

struct FolderGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []
    /// Rebuilt whenever `items` is assigned (see `setItems`) so the rubber-band modifier, tile taps
    /// and the selection → items lookup never walk the whole folder on a selection tick.
    @State private var index = SelectionIndex()
    /// What a confirmation (bin / delete / force-evict) acts on + the only-copy count its message
    /// quotes, captured when the confirmation is requested: alert titles and `message:` closures are
    /// evaluated on every body pass, so they read these snapshots instead of re-deriving the selection.
    @State private var pendingItems: [TimelineItem] = []
    @State private var pendingOnlyCopy = 0
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false
    @State private var showForceEvict = false
    @State private var showDelete = false
    @State private var showSend = false
    @State private var dragToMove = false

    /// The selection as items, in grid order — O(selection). `body` resolves it once and hands the
    /// result down; action closures call it when they fire.
    private var selectedItems: [TimelineItem] {
        index.selectedItems(selection, from: items) { $0.instanceID }
    }
    /// Evict/move-to-bin only applies to local files; drive-only assets are view-only.
    private var evictableItems: [TimelineItem] { selectedItems.filter { $0.driveRelPath == nil } }
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    private func setItems(_ new: [TimelineItem]) {
        items = new
        index = SelectionIndex(ids: new.lazy.map(\.instanceID))
    }

    var body: some View {
        let selected = selectMode ? selectedItems : []   // resolved once per body pass
        VStack(spacing: 0) {
            if selectMode { selectionBar(selected) } else { toolbar }
            Divider().overlay(Theme.hairline)
            content
        }
        .copyTargets(selectMode ? selectedItems : [], owner: "folders", state: state,
                     changeKey: SelectionKey(selectMode: selectMode, selected: selection.selected))
        .onChange(of: state.selectedFolder) {
            selection.clear(); selectMode = false; dragToMove = false       // leaving a folder ends select mode
        }
        .task(id: state.photoMoveToken) { selection.clear() }   // moved items left this folder
        // ONE reload per change of anything the query depends on (folder / rescan refresh, which
        // keeps the selection / video-only / include-subfolders). Four separate tasks used to run
        // four identical queries on first appear.
        .task(id: reloadKey) { await reload() }
        .alert("Move \(pendingItems.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let toEvict = pendingItems
                Task {
                    await state.evict(toEvict)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text(evictAlertMessage(total: pendingItems.count, onlyCopy: pendingOnlyCopy))
        }
        .alert("Delete \(pendingItems.count) photo\(pendingItems.count == 1 ? "" : "s")?",
               isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let toDelete = pendingItems
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
            ForceEvictSheet(count: pendingItems.count) {
                let toEvict = pendingItems
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
            .modifier(RubberBandModifier(selection: $selection, items: index.ordered,
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
        // Guard the library: a teardown (Close Library) can nil it while a grid/sheet is still
        // on screen, and a force-unwrap here would crash (S57). Render nothing if it's gone.
        if let library = state.library {
            // `.equatable()` so a marquee tick only re-renders cells whose inputs changed (the tap
            // closure reads @State/@Bindable, always current, so memoizing the body is safe).
            MediaGridCell(
                id: item.instanceID,
                item: item,
                selectMode: selectMode,
                selected: selection.contains(item.instanceID),
                backedUp: state.isBackedUpOnCanonical(item),
                thumbPixels: thumbPixels,
                space: "foldergrid",
                library: library,
                density: GridCellDensity(cellMin: state.gridMinSize),
                onTap: {
                    if selectMode {
                        if let idx = index.position(of: item.instanceID) {
                            selection.tap(index: idx, items: index.ordered,
                                          extendingRange: NSEvent.modifierFlags.contains(.shift))
                        }
                    } else {
                        state.openViewer(item, within: items)
                    }
                })
            .equatable()
            .copyContextMenu(state: state) { copyTargets(for: item) }   // resolved when the menu opens
        }
    }

    /// Right-clicking a tile inside the selection copies the whole selection; anywhere else, just
    /// that tile.
    private func copyTargets(for item: TimelineItem) -> [TimelineItem] {
        selectMode && selection.contains(item.instanceID) ? selectedItems : [item]
    }

    /// Everything the folder query depends on.
    private struct ReloadKey: Hashable {
        let folder: String?
        let refreshToken: Int
        let videoOnly: Bool
        let recursive: Bool
    }
    private var reloadKey: ReloadKey {
        ReloadKey(folder: state.selectedFolder, refreshToken: state.refreshToken,
                  videoOnly: state.videoOnly, recursive: state.foldersRecursive)
    }

    /// Runs the catalog query off the main actor. The grid keeps showing what it has until the
    /// result lands; a result for a key that is no longer current is dropped.
    private func reload() async {
        guard let lib = state.library, let dir = state.selectedFolder else {
            setItems([]); return
        }
        let key = reloadKey
        let loaded = await Task.detached(priority: .userInitiated) { () -> [TimelineItem] in
            let all = (try? lib.items(inDir: dir, recursive: key.recursive)) ?? []
            return key.videoOnly ? all.filter { $0.kind == MediaKind.video.rawValue } : all
        }.value
        guard !Task.isCancelled, key == reloadKey else { return }
        setItems(loaded)
    }

    /// Snapshot what a confirmation acts on (see `pendingItems`). False when nothing in the selection
    /// is a local file, in which case no confirmation is shown — as before.
    private func confirm(onlyCopyCount: Bool) -> Bool {
        let targets = evictableItems
        guard !targets.isEmpty else { return false }
        pendingItems = targets
        pendingOnlyCopy = onlyCopyCount ? state.onlyCopyCount(targets) : 0
        return true
    }

    /// `selected` is the selection resolved once by `body`; everything the bar RENDERS derives from
    /// it. Button actions re-resolve when they fire, and snapshot what a confirmation needs.
    private func selectionBar(_ selected: [TimelineItem]) -> some View {
        let hashes = selected.map(\.hash)
        return SelectionActionBar(
            count: selection.count,
            moveControls: AnyView(moveControls),
            sendTargetName: state.connectedSendTarget()?.name,
            onSend: { showSend = true },
            onDelete: { if confirm(onlyCopyCount: false) { showDelete = true } },
            onEvict: { if confirm(onlyCopyCount: true) { showEvict = true } },
            onForceEvict: { if confirm(onlyCopyCount: false) { showForceEvict = true } },
            showRehydrate: !state.rehydratableItems(selected).isEmpty,
            onRehydrate: { let items = state.rehydratableItems(selectedItems)
                           Task { _ = await state.rehydrate(items); selection.clear(); selectMode = false } },
            tagControls: AnyView(TagPersonMenu(
                state: state, hashes: hashes,
                onDone: { selection.clear(); selectMode = false; dragToMove = false })),
            albumControls: AnyView(AddToAlbumMenu(
                state: state, hashes: hashes,
                onDone: { selection.clear(); selectMode = false; dragToMove = false })),
            shareControls: AnyView(
                ShareLink(items: state.localFileURLs(for: selected)) {
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
                            setItems(items.filter { !ids.contains($0.instanceID) })
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
        return paths.sortedAsFolderPaths()
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
