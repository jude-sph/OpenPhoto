import SwiftUI
import OpenPhotoCore

struct FolderTreeView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.folderTree) { node in
                    FolderRow(node: node, state: state, depth: 0)
                }
            }
            .padding(8)
        }
        .background(Theme.bg2.opacity(0.5))
    }
}

private struct FolderRow: View {
    let node: FolderNode
    @Bindable var state: AppState
    let depth: Int
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if node.children.isEmpty {
                    Spacer().frame(width: 14)
                } else {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: 14)
                    }.buttonStyle(.plain)
                }
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(state.selectedFolder == node.path ? Theme.accent : Theme.textDim)
                Text(node.name).font(.system(size: 13))
                Spacer()
                if node.count > 0 {
                    Text("\(node.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .padding(.leading, CGFloat(depth) * 14)
            .background(state.selectedFolder == node.path ? Theme.accentDim : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { state.selectedFolder = node.path }
            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, state: state, depth: depth + 1)
                }
            }
        }
    }
}
