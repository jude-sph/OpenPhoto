import SwiftUI
import OpenPhotoCore

/// Reusable "Add to Album…" menu for a set of selected photos (by content hash). Lists every album
/// (✓ when all selected photos are already in it), plus "New Album from Selection…". Injected into
/// the Timeline and Folders selection bars.
struct AddToAlbumMenu: View {
    @Bindable var state: AppState
    let hashes: [String]
    var onDone: () -> Void = {}

    @State private var showNew = false
    @State private var newName = ""

    private var containingAll: Set<String> { state.albumsContainingAll(hashes) }

    var body: some View {
        Menu("Add to Album\u{2026}") {
            Button("New Album from Selection\u{2026}") { newName = ""; showNew = true }
            if !state.albums.isEmpty { Divider() }
            ForEach(state.albums) { album in
                Button {
                    state.addToAlbum(hashes: hashes, albumID: album.id); onDone()
                } label: {
                    if containingAll.contains(album.id) {
                        Label(album.name, systemImage: "checkmark")
                    } else {
                        Text(album.name)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(hashes.isEmpty)
        .alert("New Album", isPresented: $showNew) {
            TextField("Album name", text: $newName)
            Button("Create") {
                if let id = state.createAlbum(name: newName, fromHashes: hashes) {
                    state.selection = .albums
                    state.selectedAlbumID = id
                }
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new album containing the selected photo\(hashes.count == 1 ? "" : "s").")
        }
    }
}
