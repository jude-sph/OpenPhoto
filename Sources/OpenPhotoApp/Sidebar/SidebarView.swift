import SwiftUI
import OpenPhotoCore

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    state.sidebarShown = false
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 24)
                .padding(.trailing, 8)
            }
            .padding(.top, 8)
            Text("LIBRARY")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.44)
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            ForEach(SidebarItem.allCases, id: \.self) { item in
                let active = state.selection == item
                Button {
                    state.selection = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.label).font(.system(size: 13.5, weight: .medium))
                        Spacer()
                        if item == .bin, !state.binEntries.isEmpty {
                            Text("\(state.binEntries.count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? Theme.accentDim : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(active ? Theme.accent : Theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
            if let p = state.scanProgress {
                ActivityIndicatorView(progress: p)
            }
        }
        .frame(width: Theme.sidebarWidth)
        .background(.ultraThinMaterial)
    }
}

struct ActivityIndicatorView: View {
    let progress: Scanner.Progress
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Indexing library").font(.system(size: 12, weight: .medium))
            }
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Theme.accent)
                Text("\(progress.done) of \(progress.total) · \(progress.stage.rawValue)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(12)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}
