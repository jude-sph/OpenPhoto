import SwiftUI
import OpenPhotoCore

/// The Albums section: a sidebar list of albums + the selected album's photo grid (mirrors FoldersView).
struct AlbumsView: View {
    @Bindable var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            AlbumsListView(state: state)
                .frame(width: Theme.folderTreeWidth)
            Divider().overlay(Theme.hairline)
                .ignoresSafeArea(.container, edges: .top)
            AlbumGridView(state: state)
        }
    }
}
