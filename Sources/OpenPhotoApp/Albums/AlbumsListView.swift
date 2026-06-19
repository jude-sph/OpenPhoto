import SwiftUI
import OpenPhotoCore

/// Sidebar list of albums: cover + name + lock-gated count, selection, "＋ New Album", per-row
/// Rename/Delete, and a drop target so photos dragged from any grid are added to that album.
struct AlbumsListView: View {
    @Bindable var state: AppState
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: AlbumSummary?
    @State private var renameText = ""
    @State private var deleting: AlbumSummary?
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if state.albums.isEmpty {
                Spacer()
                Text("No albums yet")
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.albums) { row($0) }
                    }
                    .padding(8)
                }
            }
        }
        .background(Theme.bg2.opacity(0.5))
        .alert("New Album", isPresented: $showNew) {
            TextField("Album name", text: $newName)
            Button("Create") {
                if let id = state.createAlbum(name: newName) { state.selectedAlbumID = id }
                newName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create an empty album, then add photos to it from anywhere — they aren’t moved or copied.")
        }
        .alert("Rename Album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Album name", text: $renameText)
            Button("Rename") { if let a = renaming { state.renameAlbum(id: a.id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete Album?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let a = deleting { state.deleteAlbum(id: a.id) }; deleting = nil }
        } message: {
            Text("Removes the album only — your photos are not deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Albums")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textFaint).textCase(.uppercase)
            Spacer(minLength: 0)
            Button { newName = ""; showNew = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("New Album")
        }
        .padding(.horizontal, 8).frame(height: Theme.toolbarHeight)
    }

    private func row(_ album: AlbumSummary) -> some View {
        HStack(spacing: 8) {
            cover(album)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.name).font(.system(size: 13)).lineLimit(1)
                Text("\(album.count) photo\(album.count == 1 ? "" : "s")")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(
            dropTarget == album.id ? Theme.accent.opacity(0.22)
                : (state.selectedAlbumID == album.id ? Theme.accentDim : .clear),
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedAlbumID = album.id }
        .dropDestination(for: String.self) { payloads, _ in
            guard let p = payloads.first, let ids = PhotoMovePayload.decode(p), !ids.isEmpty else { return false }
            state.addToAlbum(instanceIDs: ids, albumID: album.id)
            return true
        } isTargeted: { dropTarget = $0 ? album.id : nil }
        .contextMenu {
            Button("Rename\u{2026}", systemImage: "pencil") { renameText = album.name; renaming = album }
            Button("Delete Album\u{2026}", systemImage: "trash", role: .destructive) { deleting = album }
        }
    }

    @ViewBuilder private func cover(_ album: AlbumSummary) -> some View {
        let side: CGFloat = 36
        if let h = album.coverHash, let lib = state.library, let item = try? lib.item(hash: h) {
            ThumbnailImage(timelineItem: item, library: lib, targetPixel: 96)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Theme.bg2)
                .frame(width: side, height: side)
                .overlay(Image(systemName: "rectangle.stack")
                    .font(.system(size: 13)).foregroundStyle(Theme.textFaint))
        }
    }
}
