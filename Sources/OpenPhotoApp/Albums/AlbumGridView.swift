import SwiftUI
import OpenPhotoCore

/// The selected album's photos: a reorderable MediaTile grid, with a faint on-page explanation of
/// Albums-vs-Folders as the empty / first-open state. Removing here removes from the album only.
struct AlbumGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []
    @State private var selectMode = false
    @State private var selection = SelectionModel()

    private let space = "albumgrid"
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }
    private var orderedSelectable: [SelectableItem] { items.map { SelectableItem(id: $0.instanceID) } }
    private var selectedItems: [TimelineItem] { items.filter { selection.contains($0.instanceID) } }
    private var currentAlbum: AlbumSummary? { state.albums.first { $0.id == state.selectedAlbumID } }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            content
        }
        .task(id: state.selectedAlbumID) { selection.clear(); selectMode = false; reload() }
        .task(id: state.refreshToken) { reload() }
    }

    private func reload() {
        guard let id = state.selectedAlbumID else { items = []; return }
        items = (try? state.library?.catalog.itemsInAlbum(id: id)) ?? []
    }

    // MARK: Toolbars

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(currentAlbum?.name ?? "Albums")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            if state.selectedAlbumID != nil {
                Text("\(items.count) photo\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if state.selectedAlbumID != nil && !items.isEmpty {
                Button("Select") { selectMode = true }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            if !selectedItems.isEmpty {
                ShareLink(items: state.localFileURLs(for: selectedItems)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }.controlSize(.small)
            }
            Button("Remove from Album", systemImage: "minus.circle") {
                if let id = state.selectedAlbumID {
                    state.removeFromAlbum(hashes: selectedItems.map(\.hash), albumID: id)
                }
                selection.clear(); selectMode = false
            }
            .controlSize(.small).disabled(selection.count == 0)
            Button("Deselect") { selection.clear() }.controlSize(.small)
            Button("Done") { selection.clear(); selectMode = false }.controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if state.selectedAlbumID == nil {
            albumsExplanation                                    // first-open / no selection
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("This album is empty", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("Select photos anywhere and choose “Add to Album”, or drag them onto this album in the sidebar.")
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize), spacing: Theme.gridGap)],
                          spacing: Theme.gridGap) {
                    ForEach(items, id: \.instanceID) { cell($0) }
                }
                .padding(12)
            }
            .coordinateSpace(name: space)
            .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                         space: space, enabled: selectMode))
            .pinchZoomGrid($state.gridMinSize)
        }
    }

    /// Faint, watermark-style onboarding explaining albums vs folders (no popup).
    private var albumsExplanation: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack").font(.system(size: 42, weight: .thin))
            Text("Albums vs Folders").font(.system(size: 17, weight: .semibold))
            Text("""
                 Folders are where your photos physically live on disk — each photo sits in exactly one \
                 folder, and moving it changes its location.

                 Albums are flexible collections — add a photo to as many albums as you like (birthdays, \
                 event X, situation Y) without moving or copying the file.

                 Deleting an album never deletes the photos.
                 """)
                .font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 480)
            if state.albums.isEmpty {
                Text("Create your first album with the ＋ button, or select photos anywhere and choose “Add to Album”.")
                    .font(.system(size: 12)).multilineTextAlignment(.center)
            } else {
                Text("Select an album on the left to view it.")
                    .font(.system(size: 12))
            }
        }
        .foregroundStyle(Theme.textFaint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Cells (drag-to-reorder in browse mode; rubber-band select in select mode)

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        if selectMode {
            tile(item)
        } else {
            tile(item)
                .draggable(item.hash)
                .dropDestination(for: String.self) { dropped, _ in
                    reorder(dragged: dropped.first, before: item.hash)
                }
        }
    }

    @ViewBuilder private func tile(_ item: TimelineItem) -> some View {
        if let library = state.library {
            MediaTile(
                id: item.instanceID,
                selectMode: selectMode,
                selected: selection.contains(item.instanceID),
                rubberBandSpace: space,
                thumbnail: ThumbnailImage(timelineItem: item, library: library, targetPixel: thumbPixels),
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
            .contextMenu {
                Button("Set as Album Cover", systemImage: "photo") {
                    if let id = state.selectedAlbumID { state.setAlbumCover(id: id, hash: item.hash) }
                }
                Button("Remove from Album", systemImage: "minus.circle", role: .destructive) {
                    if let id = state.selectedAlbumID { state.removeFromAlbum(hashes: [item.hash], albumID: id) }
                }
            }
        }
    }

    /// Move `dragged` to just before `targetHash` and persist the new order.
    private func reorder(dragged: String?, before targetHash: String) -> Bool {
        guard let dragged, dragged != targetHash, let id = state.selectedAlbumID else { return false }
        var order = items.map(\.hash)
        guard order.contains(dragged), order.contains(targetHash) else { return false }
        order.removeAll { $0 == dragged }
        let insertAt = order.firstIndex(of: targetHash) ?? order.endIndex
        order.insert(dragged, at: insertAt)
        state.reorderAlbum(id: id, orderedHashes: order)
        return true
    }
}
