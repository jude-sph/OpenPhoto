import SwiftUI
import OpenPhotoCore

/// The single-value filter bar (Simple mode). Mirrors the original SearchView bar — one value per
/// facet — extended with Folder and Date pickers and a Kind menu (which replaces the old Videos
/// toggle). Every control writes `state.searchFilters` then calls `state.runSearch()`. Simple never
/// writes exclude sets or more than one value into an include set.
struct SimpleFilterBar: View {
    @Bindable var state: AppState

    @State private var cameras: [String] = []
    @State private var allTags: [String] = []
    @State private var allPeople: [PersonRow] = []

    private var filters: SearchFilters { state.searchFilters }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                personMenu
                folderMenu
                cameraMenu
                dateMenu
                ratingMenu

                // Favorites toggle
                filterToggle(label: "Favorites", symbol: "heart",
                             active: filters.favoritesOnly) {
                    state.searchFilters.favoritesOnly.toggle()
                    state.runSearch()
                }

                kindMenu
                tagChips
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 44)
        .task {
            cameras = (try? state.library?.catalog.distinctCameras()) ?? []
            allTags = (try? state.library?.catalog.distinctTags()) ?? []
            allPeople = (try? state.library?.catalog.people()) ?? []
        }
    }

    // MARK: — Person

    @ViewBuilder
    private var personMenu: some View {
        if !allPeople.isEmpty {
            let activePerson = allPeople.first { $0.id == filters.includePeople.first }
            Menu {
                Button("Any person") {
                    state.searchFilters.includePeople = []
                    state.runSearch()
                }
                Divider()
                ForEach(allPeople, id: \.id) { person in
                    Button(person.name) {
                        state.searchFilters.includePeople = [person.id]
                        state.runSearch()
                    }
                }
            } label: {
                filterChip(label: activePerson?.name ?? "Person",
                           active: filters.includePeople.first != nil, symbol: "person")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: — Folder

    @ViewBuilder
    private var folderMenu: some View {
        let paths = folderPaths(state.folderTree)
        if !paths.isEmpty {
            let active = filters.includeFolders.first
            Menu {
                Button("Any folder") {
                    state.searchFilters.includeFolders = []
                    state.runSearch()
                }
                Divider()
                ForEach(paths, id: \.self) { path in
                    Button(folderLabel(path)) {
                        state.searchFilters.includeFolders = [path]
                        state.runSearch()
                    }
                }
            } label: {
                filterChip(label: active.map(folderLabel) ?? "Folder",
                           active: active != nil, symbol: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Recursive toggle (include the whole subtree of the chosen folder).
            filterToggle(label: "Recursive", symbol: "arrow.turn.down.right",
                         active: filters.foldersRecursive) {
                state.searchFilters.foldersRecursive.toggle()
                state.runSearch()
            }
        }
    }

    // MARK: — Camera

    @ViewBuilder
    private var cameraMenu: some View {
        if !cameras.isEmpty {
            Menu {
                Button("Any camera") {
                    state.searchFilters.includeCameras = []
                    state.runSearch()
                }
                Divider()
                ForEach(cameras, id: \.self) { cam in
                    Button(cam) {
                        state.searchFilters.includeCameras = [cam]
                        state.runSearch()
                    }
                }
            } label: {
                filterChip(label: filters.includeCameras.first ?? "Camera",
                           active: filters.includeCameras.first != nil, symbol: "camera")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: — Date

    private var dateMenu: some View {
        Menu {
            Button("Any date") {
                state.searchFilters.dateRange = nil
                state.runSearch()
            }
            Divider()
            ForEach(DatePreset.relative, id: \.self) { preset in
                Button(preset.label) {
                    state.searchFilters.dateRange = preset.range(asOf: Date())
                    state.runSearch()
                }
            }
            Divider()
            ForEach(DatePreset.recentYears(asOf: Date()), id: \.self) { preset in
                Button(preset.label) {
                    state.searchFilters.dateRange = preset.range(asOf: Date())
                    state.runSearch()
                }
            }
        } label: {
            filterChip(label: "Date", active: filters.dateRange != nil, symbol: "calendar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: — Rating

    private var ratingMenu: some View {
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
            let minR = filters.minRating
            filterChip(label: minR.map { "\($0)+ stars" } ?? "Rating",
                       active: minR != nil, symbol: "star")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: — Kind

    private var kindMenu: some View {
        Menu {
            Button("Any kind") {
                state.searchFilters.kind = nil
                state.runSearch()
            }
            Divider()
            Button("Photos") { setKind(.photo) }
            Button("Videos") { setKind(.video) }
            Button("Live") { setKind(.live) }
        } label: {
            filterChip(label: kindLabel(filters.kind), active: filters.kind != nil, symbol: "photo")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setKind(_ k: KindFilter) {
        state.searchFilters.kind = k
        state.runSearch()
    }

    private func kindLabel(_ k: KindFilter?) -> String {
        switch k {
        case .photo: return "Photos"
        case .video: return "Videos"
        case .live:  return "Live"
        case nil:    return "Kind"
        }
    }

    // MARK: — Tags

    @ViewBuilder
    private var tagChips: some View {
        if !allTags.isEmpty {
            Divider().frame(height: 20)
            ForEach(allTags, id: \.self) { tag in
                let active = filters.includeTags.contains(tag)
                Button {
                    if active {
                        state.searchFilters.includeTags.removeAll { $0 == tag }
                    } else {
                        state.searchFilters.includeTags.append(tag)
                    }
                    state.runSearch()
                } label: {
                    filterChip(label: tag, active: active, symbol: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: — Helpers

    /// Flatten the folder tree to a sorted list of dir paths.
    private func folderPaths(_ nodes: [FolderNode]) -> [String] {
        nodes.flatMap { [$0.path] + folderPaths($0.children) }.sorted()
    }

    /// Last path component for display (full path used as the filter value).
    private func folderLabel(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    @ViewBuilder
    private func filterChip(label: String, active: Bool, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10))
            }
            Text(label).font(.system(size: 12))
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
    private func filterToggle(label: String, symbol: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            filterChip(label: label, active: active, symbol: symbol)
        }
        .buttonStyle(.plain)
    }
}
