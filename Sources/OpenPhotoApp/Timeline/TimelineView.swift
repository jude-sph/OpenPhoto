import SwiftUI
import OpenPhotoCore

struct TimelineView: View {
    @Bindable var state: AppState
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false
    @State private var showSend = false

    private var orderedSelectable: [SelectableItem] {
        state.flatItems.map { SelectableItem(id: $0.instanceID) }
    }
    private var selectedItems: [TimelineItem] {
        state.flatItems.filter { selection.contains($0.instanceID) }
    }
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            grid
        }
        .alert("Move \(selection.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let items = selectedItems
                Task {
                    await state.evict(items)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text(evictAlertMessage(total: selection.count,
                                   onlyCopy: state.onlyCopyCount(selectedItems)))
        }
        .sheet(isPresented: $showSend) {
            if let target = state.connectedSendTarget() {
                SendSheet(state: state, items: selectedItems, device: target) {
                    selection.clear(); selectMode = false
                }
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
                            ForEach(section.items, id: \.instanceID) { item in
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
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { PhotoCellView(item: item, library: state.library!,
                                     targetPixel: thumbPixels,
                                     backedUp: state.isBackedUpOnCanonical(item),
                                     driveOnly: item.driveRelPath != nil) }
            .clipped()
            .selectionChrome(selected: selection.contains(item.instanceID), show: selectMode)
            .cellFrame(item.instanceID, in: "timelinegrid", active: selectMode)
            .contentShape(Rectangle())
            .onTapGesture {
                if selectMode {
                    if let idx = state.flatItems.firstIndex(where: { $0.instanceID == item.instanceID }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: state.flatItems)
                }
            }
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
            sendTargetName: state.connectedSendTarget()?.name,
            onSend: { showSend = true },
            onEvict: { showEvict = true },
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
