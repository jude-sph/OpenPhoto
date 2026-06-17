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

    // Timeline is deduped by content, so a tile is identified by its content `hash` (unique here),
    // not `instanceID` — so a photo in two folders is one tile/one selectable.
    private var orderedSelectable: [SelectableItem] {
        state.flatItems.map { SelectableItem(id: $0.hash) }
    }
    private var selectedItems: [TimelineItem] {
        state.flatItems.filter { selection.contains($0.hash) }
    }
    /// Evict/move-to-bin only applies to local files; drive-only assets are view-only.
    private var evictableItems: [TimelineItem] { selectedItems.filter { $0.driveRelPath == nil } }
    private var rehydratableItems: [TimelineItem] { state.rehydratableItems(selectedItems) }
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            VideosOnlyBanner(state: state)
            grid
        }
        .alert("Move \(evictableItems.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let items = evictableItems
                Task {
                    await state.evict(items)
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
                let items = evictableItems
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
            ForceEvictSheet(count: evictableItems.count) {
                let items = evictableItems
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
        .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                     space: "timelinegrid", enabled: selectMode))
        .pinchZoomGrid($state.gridMinSize)
    }

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        MediaTile(
            id: item.hash,
            selectMode: selectMode,
            selected: selection.contains(item.hash),
            rubberBandSpace: "timelinegrid",
            thumbnail: ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: thumbPixels),
            badges: { TimelineTileBadges(item: item, backedUp: state.isBackedUpOnCanonical(item)) },
            onTap: {
                if selectMode {
                    if let idx = state.flatItems.firstIndex(where: { $0.hash == item.hash }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: state.flatItems)
                }
            })
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

    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            sendTargetName: {
                let targets = state.connectedSendTargets()
                return targets.count > 1 ? "device\u{2026}" : targets.first?.name
            }(),
            onSend: {
                let targets = state.connectedSendTargets()
                if targets.count <= 1 { showSend = true }
                else { sendChooser = true }
            },
            onDelete: { if !evictableItems.isEmpty { showDelete = true } },
            onEvict: { if !evictableItems.isEmpty { showEvict = true } },
            onForceEvict: { if !evictableItems.isEmpty { showForceEvict = true } },
            showRehydrate: !rehydratableItems.isEmpty,
            onRehydrate: { let items = rehydratableItems
                           Task { _ = await state.rehydrate(items); selection.clear(); selectMode = false } },
            tagControls: AnyView(TagPersonMenu(
                state: state, hashes: selectedItems.map(\.hash),
                onDone: { selection.clear(); selectMode = false })),
            shareControls: AnyView(
                ShareLink(items: state.localFileURLs(for: selectedItems)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }.controlSize(.small)),
            onDeselect: { selection.clear() },
            onDone: { selection.clear(); selectMode = false })
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

    private var stats: String {
        let all = state.flatItems
        let v = all.filter { $0.kind == MediaKind.video.rawValue }.count
        return "\(all.count - v) photos · \(v) videos"
    }
}
