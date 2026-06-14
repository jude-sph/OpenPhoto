import SwiftUI
import OpenPhotoCore

struct SearchView: View {
    @Bindable var state: AppState
    @State private var debounceTask: Task<Void, Never>?

    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        VStack(spacing: 0) {
            if case .unavailable = (state.mlStatus[.semanticSearch] ?? .unknown) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Semantic (text-description) search is unavailable on this Mac — keyword and filters still work.")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .help(state.mlUnavailable.first(where: { $0.capability == .semanticSearch })?.reason ?? "")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red)
            }
            toolbar
            Divider().overlay(Theme.hairline)
            if state.searchMode == .pro {
                ProFilterBar(state: state)
            } else {
                SimpleFilterBar(state: state)
                if state.proOnlyFilterCount > 0 { proFiltersHint }
            }
            Divider().overlay(Theme.hairline)
            resultGrid
        }
    }

    /// Shown in Simple mode when the active filters include things Simple can't display
    /// (exclusions, ≥2 of a facet, has-text, people-presence). Tapping flips to Pro.
    private var proFiltersHint: some View {
        HStack(spacing: 6) {
            Button {
                state.searchMode = .pro
            } label: {
                Text("+\(state.proOnlyFilterCount) Pro filters active")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: — Toolbar (text box + result count)

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
                .font(.system(size: 14))

            TextField("Describe a photo, or find text in it…", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { state.runSearch() }
                .onChange(of: state.searchQuery) { debounce() }

            if state.searching {
                ProgressView().controlSize(.small)
            }

            Picker("", selection: $state.searchMode) {
                Text("Simple").tag(AppState.SearchMode.simple)
                Text("Pro").tag(AppState.SearchMode.pro)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            if !state.searchQuery.isEmpty || !state.searchFilters.isEmpty {
                Text(resultCountLabel)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)

                Button {
                    state.searchQuery = ""
                    state.searchFilters = SearchFilters()
                    state.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private var resultCountLabel: String {
        let n = state.searchResults.count
        if state.searching { return "Searching…" }
        return n == 1 ? "1 result" : "\(n) results"
    }

    // MARK: — Result grid

    @ViewBuilder
    private var resultGrid: some View {
        if state.searchQuery.isEmpty && state.searchFilters.isEmpty {
            emptyState("magnifyingglass", "Search your library",
                       "Type to match how a photo looks or text in it — and use filters for people, places, dates, and folders.")
        } else if state.searchResults.isEmpty && !state.searching {
            emptyState("photo.on.rectangle.angled", "No matches",
                       "Try different keywords or adjust the filters.")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: state.gridMinSize), spacing: Theme.gridGap)],
                    spacing: Theme.gridGap
                ) {
                    ForEach(state.searchResults, id: \.hash) { item in   // search is deduped by content
                        MediaTile(
                            id: item.hash,
                            selectMode: false,
                            selected: false,
                            rubberBandSpace: nil,
                            thumbnail: ThumbnailImage(
                                timelineItem: item,
                                library: state.library!,
                                targetPixel: thumbPixels
                            ),
                            badges: {
                                TimelineTileBadges(
                                    item: item,
                                    backedUp: state.isBackedUpOnCanonical(item)
                                )
                            },
                            onTap: {
                                state.openViewer(item, within: state.searchResults)
                            }
                        )
                    }
                }
                .padding(Theme.gridGap)
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: — Debounce helper

    private func debounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run { state.runSearch() }
        }
    }
}
