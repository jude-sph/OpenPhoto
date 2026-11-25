import SwiftUI
import OpenPhotoCore

struct TimelineView: View {
    @Bindable var state: AppState
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false
    @State private var showForceEvict = false
    @State private var showDelete = false
    @State private var showSend = false
    @State private var sendChooser = false
    @State private var chosenSendDevice: ConnectedDevice?

    /// Derived from `state.flatItems` ONCE per change of that list (see `rebuildDerived`), never per
    /// render: the selectable list + id → position lookup, and the toolbar's photo/video counts.
    // Timeline is deduped by content, so a tile is identified by its content `hash` (unique here),
    // not `instanceID` — so a photo in two folders is one tile/one selectable.
    @State private var index = SelectionIndex()
    @State private var stats = ""
    /// The items a confirmation (bin / delete / force-evict) acts on, and the only-copy count its
    /// message quotes — captured at the moment the confirmation is requested. Alert titles and
    /// `message:` closures are evaluated on EVERY body pass (browse mode included), so they must read
    /// these snapshots, not re-derive the selection from the whole library.
    @State private var pendingItems: [TimelineItem] = []
    @State private var pendingOnlyCopy = 0

    /// The selection as items, in timeline order. O(selection), not O(library). Still not free —
    /// `body` resolves it once and hands the result down; action closures call it when they fire.
    private var selectedItems: [TimelineItem] {
        index.selectedItems(selection, from: state.flatItems) { $0.hash }
    }
    /// Evict/move-to-bin only applies to local files; drive-only assets are view-only.
    private var evictableItems: [TimelineItem] { selectedItems.filter { $0.driveRelPath == nil } }
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    private func rebuildDerived() {
        let all = state.flatItems
        index = SelectionIndex(ids: all.lazy.map(\.hash))
        let v = all.reduce(0) { $1.kind == MediaKind.video.rawValue ? $0 + 1 : $0 }
        stats = "\(all.count - v) photos · \(v) videos"
    }

    var body: some View {
        let selected = selectMode ? selectedItems : []   // resolved once per body pass
        VStack(spacing: 0) {
            if selectMode { selectionBar(selected) } else { toolbar }
            Divider().overlay(Theme.hairline)
            VideosOnlyBanner(state: state)
            grid
        }
        // Array `==` short-circuits on identical storage, so this costs nothing until the list is
        // actually replaced.
        .onChange(of: state.flatItems, initial: true) { rebuildDerived() }
        .copyTargets(selectMode ? selectedItems : [], owner: "timeline", state: state,
                     changeKey: SelectionKey(selectMode: selectMode, selected: selection.selected))
        .alert("Move \(pendingItems.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let items = pendingItems
                Task {
                    await state.evict(items)
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
                let items = pendingItems
                Task {
                    await state.deletePhotos(items)   // timeline is deduped → delete the photo everywhere
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text("They move to the bin (restore anytime). On connected drives, their copies are then queued for removal — review under the drive before anything is deleted there.")
        }
        .sheet(isPresented: $showSend, onDismiss: { chosenSendDevice = nil }) {
            if let target = chosenSendDevice ?? state.connectedSendTarget() {
                SendSheet(state: state, items: selectedItems, device: target) {
                    selection.clear(); selectMode = false
                }
            }
        }
        .confirmationDialog("Send to which device?", isPresented: $sendChooser, titleVisibility: .visible) {
            ForEach(state.connectedSendTargets(), id: \.id) { dev in
                Button(dev.name) { chosenSendDevice = dev; showSend = true }
            }
        }
        .sheet(isPresented: $showForceEvict) {
            ForceEvictSheet(count: pendingItems.count) {
                let items = pendingItems
                Task { _ = await state.evict(items, mode: .forced); selection.clear(); selectMode = false }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: Theme.gridGap, pinnedViews: [.sectionHeaders]) {
                ForEach(state.sections, id: \.dayStartMs) { section in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                                     spacing: Theme.gridGap)],
                                  spacing: Theme.gridGap) {
                            ForEach(section.items, id: \.hash) { item in
                                cell(item)
                            }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
        .coordinateSpace(name: "timelinegrid")
        .modifier(RubberBandModifier(selection: $selection, items: index.ordered,
                                     space: "timelinegrid", enabled: selectMode))
        .pinchZoomGrid($state.gridMinSize)
    }

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        if let library = state.library {
            // `.equatable()` so a marquee tick only re-renders cells whose inputs changed (the tap
            // closure reads @State/@Bindable, always current, so memoizing the body is safe).
            MediaGridCell(
                id: item.hash,
                item: item,
                selectMode: selectMode,
                selected: selection.contains(item.hash),
                backedUp: state.isBackedUpOnCanonical(item),
                thumbPixels: thumbPixels,
                space: "timelinegrid",
                library: library,
                onTap: {
                    if selectMode {
                        if let idx = index.position(of: item.hash) {
                            selection.tap(index: idx, items: index.ordered,
                                          extendingRange: NSEvent.modifierFlags.contains(.shift))
                        }
                    } else {
                        state.openViewer(item, within: state.flatItems)
                    }
                })
            .equatable()
            .copyContextMenu(state: state) { copyTargets(for: item) }   // resolved when the menu opens
        }
    }

    /// Right-clicking a tile inside the selection copies the whole selection; anywhere else, just
    /// that tile.
    private func copyTargets(for item: TimelineItem) -> [TimelineItem] {
        selectMode && selection.contains(item.hash) ? selectedItems : [item]
    }

    @ViewBuilder private func sectionHeader(_ section: TimelineSection) -> some View {
        if state.grouping != .none {
            HStack {
                Text(section.title).font(.system(size: 16, weight: .bold))
                Spacer()
                Text("\(section.items.count) items")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.windowBG.opacity(0.92))
        }
    }

    /// `selected` is the selection resolved once by `body`; everything the bar RENDERS derives from
    /// it. Button actions re-resolve when they fire (rare), and snapshot what a confirmation needs.
    private func selectionBar(_ selected: [TimelineItem]) -> some View {
        let hashes = selected.map(\.hash)
        return SelectionActionBar(
            count: selection.count,
            moveControls: AnyView(moveControls),
            sendTargetName: {
                let targets = state.connectedSendTargets()
                return targets.count > 1 ? "device\u{2026}" : targets.first?.name
            }(),
            onSend: {
                let targets = state.connectedSendTargets()
                if targets.count <= 1 { showSend = true }
                else { sendChooser = true }
            },
            onDelete: { if confirm(onlyCopyCount: false) { showDelete = true } },
            onEvict: { if confirm(onlyCopyCount: true) { showEvict = true } },
            onForceEvict: { if confirm(onlyCopyCount: false) { showForceEvict = true } },
            showRehydrate: !state.rehydratableItems(selected).isEmpty,
            onRehydrate: { let items = state.rehydratableItems(selectedItems)
                           Task { _ = await state.rehydrate(items); selection.clear(); selectMode = false } },
            tagControls: AnyView(TagPersonMenu(
                state: state, hashes: hashes,
                onDone: { selection.clear(); selectMode = false })),
            albumControls: AnyView(AddToAlbumMenu(
                state: state, hashes: hashes,
                onDone: { selection.clear(); selectMode = false })),
            shareControls: AnyView(
                ShareLink(items: state.localFileURLs(for: selected)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }.controlSize(.small)),
            onDeselect: { selection.clear() },
            onDone: { selection.clear(); selectMode = false })
    }

    /// Snapshot what a confirmation acts on (see `pendingItems`). False when nothing in the selection
    /// is a local file, in which case no confirmation is shown — as before.
    private func confirm(onlyCopyCount: Bool) -> Bool {
        let items = evictableItems
        guard !items.isEmpty else { return false }
        pendingItems = items
        pendingOnlyCopy = onlyCopyCount ? state.onlyCopyCount(items) : 0
        return true
    }

    /// "Move to…" folder menu — parity with the Folders view. The Timeline is deduped by content
    /// hash (not folder-scoped), so move each selected photo's representative local instance into
    /// the chosen folder; the photo stays in the timeline. Drive-only items re-key via movePhotos.
    private var moveControls: some View {
        Menu("Move to\u{2026}") {
            ForEach(allFolders, id: \.self) { f in
                Button(folderMenuLabel(f)) {
                    let ids = selectedItems.map(\.instanceID)
                    selection.clear(); selectMode = false
                    Task { await state.movePhotos(ids: ids, into: f) }
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(selection.count == 0)
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

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("Timeline").font(.system(size: 15, weight: .semibold))
            Text(stats).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Select") { selectMode = true }.controlSize(.small)
            Toggle(isOn: Binding(get: { state.videoOnly },
                                 set: { state.videoOnly = $0 })) {   // didSet refreshes queries
                Image(systemName: "video.fill")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Show videos only")
            Picker("Group", selection: $state.grouping) {
                Text("Day").tag(TimelineGrouping.day)
                Text("Week").tag(TimelineGrouping.week)
                Text("Month").tag(TimelineGrouping.month)
                Text("Year").tag(TimelineGrouping.year)
                Text("Continuous").tag(TimelineGrouping.none)
            }
            .pickerStyle(.menu).labelsHidden()
            .onChange(of: state.grouping) { try? state.refreshQueries() }
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 48...220).frame(width: 120)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}
