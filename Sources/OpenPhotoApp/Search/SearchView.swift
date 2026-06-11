import SwiftUI
import OpenPhotoCore

struct SearchView: View {
    @Bindable var state: AppState
    @State private var cameras: [String] = []
    @State private var allTags: [String] = []
    @State private var allPeople: [PersonRow] = []
    @State private var debounceTask: Task<Void, Never>?

    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            filterBar
            Divider().overlay(Theme.hairline)
            resultGrid
        }
        .task {
            cameras = (try? state.library?.catalog.distinctCameras()) ?? []
            allTags = (try? state.library?.catalog.distinctTags()) ?? []
            allPeople = (try? state.library?.catalog.people()) ?? []
        }
    }

    // MARK: — Toolbar (text box + result count)

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textDim)
                .font(.system(size: 14))

            TextField("Search photos…", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { state.runSearch() }
                .onChange(of: state.searchQuery) { debounce() }

            if state.searching {
                ProgressView().controlSize(.small)
            }

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

    // MARK: — Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Camera picker
                if !cameras.isEmpty {
                    Menu {
                        Button("Any camera") {
                            state.searchFilters.camera = nil
                            state.runSearch()
                        }
                        Divider()
                        ForEach(cameras, id: \.self) { cam in
                            Button(cam) {
                                state.searchFilters.camera = cam
                                state.runSearch()
                            }
                        }
                    } label: {
                        filterChip(
                            label: state.searchFilters.camera ?? "Camera",
                            active: state.searchFilters.camera != nil,
                            symbol: "camera"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // Rating picker
                Menu {
                    Button("Any rating") {
                        state.searchFilters.minRating = nil
                        state.runSearch()
                    }
                    Divider()
                    ForEach([1, 2, 3, 4, 5], id: \.self) { r in
                        Button("\(r)+ stars") {
                            state.searchFilters.minRating = r
                            state.runSearch()
                        }
                    }
                } label: {
                    let minR = state.searchFilters.minRating
                    filterChip(
                        label: minR.map { "\($0)+ stars" } ?? "Rating",
                        active: minR != nil,
                        symbol: "star"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Favorites toggle
                filterToggle(label: "Favorites", symbol: "heart",
                             active: state.searchFilters.favoritesOnly) {
                    state.searchFilters.favoritesOnly.toggle()
                    state.runSearch()
                }

                // Video only toggle
                filterToggle(label: "Videos", symbol: "video",
                             active: state.searchFilters.videoOnly) {
                    state.searchFilters.videoOnly.toggle()
                    state.runSearch()
                }

                // Tag chips
                if !allTags.isEmpty {
                    Divider().frame(height: 20)
                    ForEach(allTags, id: \.self) { tag in
                        let active = state.searchFilters.tags.contains(tag)
                        Button {
                            if active {
                                state.searchFilters.tags.removeAll { $0 == tag }
                            } else {
                                state.searchFilters.tags.append(tag)
                            }
                            state.runSearch()
                        } label: {
                            filterChip(label: tag, active: active, symbol: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Person picker (only when there are named people in the catalog)
                if !allPeople.isEmpty {
                    Divider().frame(height: 20)
                    let activePerson = allPeople.first { $0.id == state.searchFilters.person }
                    Menu {
                        Button("Any person") {
                            state.searchFilters.person = nil
                            state.runSearch()
                        }
                        Divider()
                        ForEach(allPeople, id: \.id) { person in
                            Button(person.name) {
                                state.searchFilters.person = person.id
                                state.runSearch()
                            }
                        }
                    } label: {
                        filterChip(
                            label: activePerson?.name ?? "Person",
                            active: state.searchFilters.person != nil,
                            symbol: "person"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func filterChip(label: String, active: Bool, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
            }
            Text(label)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(active ? Theme.accentDim : Theme.elevated,
                    in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(active ? Theme.accent : Theme.textDim)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(active ? Theme.accent.opacity(0.4) : Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func filterToggle(label: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            filterChip(label: label, active: active, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    // MARK: — Result grid

    @ViewBuilder
    private var resultGrid: some View {
        if state.searchQuery.isEmpty && state.searchFilters.isEmpty {
            emptyState("magnifyingglass", "Type to search\u{2026}",
                       "Enter text or select filters to find photos.")
        } else if state.searchResults.isEmpty && !state.searching {
            emptyState("photo.on.rectangle.angled", "No matches",
                       "Try different keywords or adjust the filters.")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: state.gridMinSize), spacing: Theme.gridGap)],
                    spacing: Theme.gridGap
                ) {
                    ForEach(state.searchResults, id: \.instanceID) { item in
                        MediaTile(
                            id: item.instanceID,
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
