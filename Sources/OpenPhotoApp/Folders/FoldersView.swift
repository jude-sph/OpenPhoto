import SwiftUI
import OpenPhotoCore

struct FoldersView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            FolderTreeView(state: state)
                .frame(width: Theme.folderTreeWidth)
            Divider().overlay(Theme.hairline)
                .ignoresSafeArea(.container, edges: .top)
            FolderGridView(state: state)
        }
    }
}
