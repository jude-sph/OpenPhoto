import SwiftUI
import OpenPhotoCore

struct SearchView: View {
    @Bindable var state: AppState
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false
    @State private var showForceEvict = false
    @State private var showDelete = false
    @State private var showSend = false
    @State private var sendChooser = false
    @State private var chosenSendDevice: ConnectedDevice?

    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }
    // Search results are deduped by content, so a tile is keyed by its `hash` (like the Timeline).
    /// Rebuilt once per change of `state.searchResults`, never per render.
    @State private var index = SelectionIndex()
    /// What a confirmation acts on + the only-copy count its message quotes, captured when it is
    /// requested (alert titles/messages are evaluated on every body pass, so they read snapshots).
    @State private var pendingItems: [TimelineItem] = []
    @State private var pendingOnlyCopy = 0

    /// The selection as items, in result order — O(selection). `body` resolves it once.
    private var selectedItems: [TimelineItem] {
        index.selectedItems(selection, from: state.searchResults) { $0.hash }
    }
    private var evictableItems: [TimelineItem] { selectedItems.filter { $0.driveRelPath == nil } }

    private func confirm(onlyCopyCount: Bool) -> Bool {
        let items = evictableItems
        guard !items.isEmpty else { return false }
        pendingItems = items
        pendingOnlyCopy = onlyCopyCount ? state.onlyCopyCount(items) : 0
        return true
    }

    var body: some View {
        let selected = selectMode ? selectedItems : []   // resolved once per body pass
        VStack(spacing: 0) {
            if case .unavailable = (state.mlStatus[.semanticSearch] ?? .unknown) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Semantic (text-description) search is unavailable on this Mac — keyword and filters still work.")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .help(state.mlUnavailable.first(where: { $0.capability == .semanticSearch })?.reason ?? "")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red)
            }
            toolbar
            Divider().overlay(Theme.hairline)
            if state.searchMode == .pro {
                ProFilterBar(state: state)
            } else {
                SimpleFilterBar(state: state)
                if state.proOnlyFilterCount > 0 { proFiltersHint }
            }
            Divider().overlay(Theme.hairline)
            if selectMode {
                selectionBar(selected)   // thin action bar below the search header, only while selecting
                Divider().overlay(Theme.hairline)
            }
            resultGrid
        }
        .onChange(of: state.searchResults, initial: true) {
            index = SelectionIndex(ids: state.searchResults.lazy.map(\.hash))
        }
        .copyTargets(selectMode ? selectedItems : [], owner: "search", state: state,
                     changeKey: SelectionKey(selectMode: selectMode, selected: selection.selected))
        .alert("Move \(pendingItems.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let items = pendingItems
                Task { await state.evict(items); selection.clear(); selectMode = false }
            }
        } message: {
            Text(evictAlertMessage(total: pendingItems.count, onlyCopy: pendingOnlyCopy))
        }
        .alert("Delete \(pendingItems.count) photo\(pendingItems.count == 1 ? "" : "s")?",
               isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let items = pendingItems
                Task { await state.deletePhotos(items); selection.clear(); selectMode = false }
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
                if targets.count <= 1 { showSend = true } else { sendChooser = true }
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

    /// "Move to…" folder menu — parity with the Timeline. Moves each selected photo's representative
    /// instance into the chosen folder (results are deduped by content hash).
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
        return paths.sortedAsFolderPaths()
    }
    private func folderMenuLabel(_ path: String) -> String {
        if path.isEmpty { return state.folderTree.first { $0.path == "" }?.name ?? "Library Root" }
        return path.replacingOccurrences(of: "/", with: " \u{203A} ")
    }

    /// Shown in Simple mode when the active filters include things Simple can't display
    /// (exclusions, ≥2 of a facet, has-text, people-presence). Tapping flips to Pro.
    private var proFiltersHint: some View {
        HStack(spacing: 6) {
            Button {
                state.searchMode = .pro
            } label: {
                Text("+\(state.proOnlyFilterCount) Pro filters active")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: — Toolbar (text box + result count)

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
                .font(.system(size: 14))

            TextField("Describe a photo, or find text in it…", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { state.runSearch() }
                .onChange(of: state.searchQuery) { debounce() }

            if state.searching {
                ProgressView().controlSize(.small)
            }

            Picker("", selection: $state.searchMode) {
                Text("Simple").tag(AppState.SearchMode.simple)
                Text("Pro").tag(AppState.SearchMode.pro)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            if !state.searchQuery.isEmpty || !state.searchFilters.isEmpty {
                Text(resultCountLabel)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)

                Button {
                    state.searchQuery = ""
                    state.searchFilters = SearchFilters()
                    state.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }

            if !state.searchResults.isEmpty && !selectMode {
                Button("Select") { selectMode = true }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private var resultCountLabel: String {
        let n = state.searchResults.count
        if state.searching { return "Searching…" }
        return n == 1 ? "1 result" : "\(n) results"
    }

    // MARK: — Result grid

    @ViewBuilder
    private var resultGrid: some View {
        if state.searchQuery.isEmpty && state.searchFilters.isEmpty {
            emptyState("magnifyingglass", "Search your library",
                       "Type to match how a photo looks or text in it — and use filters for people, places, dates, and folders.")
        } else if state.searchResults.isEmpty && !state.searching {
            emptyState("photo.on.rectangle.angled", "No matches",
                       "Try different keywords or adjust the filters.")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: state.gridMinSize), spacing: Theme.gridGap)],
                    spacing: Theme.gridGap
                ) {
                    ForEach(state.searchResults, id: \.hash) { item in   // search is deduped by content
                        // The same memoising cell as the timeline/folder grids (it builds exactly the
                        // MediaTile + badges this grid used to build inline), so a selection tick only
                        // re-renders the tiles whose inputs changed.
                        MediaGridCell(
                            id: item.hash,
                            item: item,
                            selectMode: selectMode,
                            selected: selection.contains(item.hash),
                            backedUp: state.isBackedUpOnCanonical(item),
                            thumbPixels: thumbPixels,
                            space: "searchgrid",
                            library: state.library!,
                            density: GridCellDensity(cellMin: state.gridMinSize),
                            onTap: {
                                if selectMode {
                                    if let idx = index.position(of: item.hash) {
                                        selection.tap(index: idx, items: index.ordered,
                                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                                    }
                                } else {
                                    state.openViewer(item, within: state.searchResults)
                                }
                            }
                        )
                        .equatable()
                        .copyContextMenu(state: state) {   // resolved when the menu opens
                            selectMode && selection.contains(item.hash) ? selectedItems : [item]
                        }
                    }
                }
                .padding(Theme.gridGap)
            }
            .coordinateSpace(name: "searchgrid")
            .modifier(RubberBandModifier(selection: $selection, items: index.ordered,
                                         space: "searchgrid", enabled: selectMode))
            .pinchZoomGrid($state.gridMinSize)
        }
    }

    @ViewBuilder
    private func emptyState(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: — Debounce helper

    private func debounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run { state.runSearch() }
        }
    }
}
