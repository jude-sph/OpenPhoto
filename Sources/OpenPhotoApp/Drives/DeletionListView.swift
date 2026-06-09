import SwiftUI
import OpenPhotoCore

/// Shared, selectable list of pending deletions — small cached thumbnails, Select-All, and a
/// per-row Restore (distinct from unchecking). Used by both the standalone review sheet and the
/// Sync plan's Deletions section.
struct DeletionListView: View {
    @Bindable var state: AppState
    let entries: [PendingDeletion]
    @Binding var selected: Set<String>      // selected hashes
    let onRestore: (PendingDeletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entries.count) photo\(entries.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(entries.map(\.hash))
                }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 4).padding(.bottom, 4)
            List(entries, id: \.hash) { e in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(e.hash) },
                        set: { if $0 { selected.insert(e.hash) } else { selected.remove(e.hash) } }))
                        .labelsHidden().toggleStyle(.checkbox)
                    DeletionThumb(state: state, hash: e.hash)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.relPath).font(.system(size: 12))
                            .lineLimit(1).truncationMode(.middle)
                        Text("deleted \(relativeAge(e.deletedAtMs))")
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Button { onRestore(e) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }.controlSize(.small).font(.system(size: 11))
                }
            }.listStyle(.inset)
        }
    }

    private var allSelected: Bool { !entries.isEmpty && selected.count == entries.count }

    private func relativeAge(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// 32px cached thumbnail by hash (works with the local original deleted + the drive unplugged);
/// falls back to a glyph when nothing is cached.
private struct DeletionThumb: View {
    @Bindable var state: AppState
    let hash: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.hairline)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            }
        }
        .task(id: hash) {
            image = await state.library?.thumbnails.cachedDisplayImage(
                for: ContentHash(stringValue: hash), maxPixel: 64)
        }
    }
}
