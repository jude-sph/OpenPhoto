import SwiftUI
import OpenPhotoCore

struct TimelineView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                             spacing: Theme.gridGap)],
                          spacing: Theme.gridGap,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(state.sections, id: \.dayStartMs) { section in
                        Section {
                            ForEach(section.items, id: \.hash) { item in
                                PhotoCellView(item: item, library: state.library!) {
                                    Task {
                                        try? await state.library?.delete(item)
                                        try? state.refreshQueries()
                                    }
                                }
                                .aspectRatio(1, contentMode: .fill)
                                .onTapGesture { state.openedItem = item }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                    .font(.system(size: 16, weight: .bold))
                                Spacer()
                                Text("\(section.items.count) items")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 8)
                            .background(Theme.windowBG.opacity(0.92))
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("Timeline").font(.system(size: 15, weight: .semibold))
            Text(stats).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 92...220).frame(width: 120)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private var stats: String {
        let all = state.flatItems
        let v = all.filter { $0.kind == MediaKind.video.rawValue }.count
        return "\(all.count - v) photos · \(v) videos"
    }
}
