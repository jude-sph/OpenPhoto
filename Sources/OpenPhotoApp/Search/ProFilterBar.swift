import SwiftUI
import OpenPhotoCore

/// The Pro filter bar: leading facet menus that ADD values to include sets, a row of tri-state
/// include/exclude chips (tap to flip, ✕ to remove), and a More menu for the non-negatable controls
/// (rating / favourites / kind / people-presence / has-text / recursive). Every mutation calls
/// `state.runSearch()`.
struct ProFilterBar: View {
    @Bindable var state: AppState

    @State private var cameras: [String] = []
    @State private var allTags: [String] = []
    @State private var allPeople: [PersonRow] = []
    @State private var allPlaces: [PlaceFacet] = []

    private var filters: SearchFilters { state.searchFilters }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                peopleMenu
                foldersMenu
                placesMenu
                camerasMenu
                tagsMenu
                dateMenu
                moreMenu

                if hasAnyChip {
                    Divider().frame(height: 20)
                    chips
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 44)
        .task {
            cameras = (try? state.library?.catalog.distinctCameras()) ?? []
            allTags = (try? state.library?.catalog.distinctTags()) ?? []
            allPeople = (try? state.library?.catalog.people()) ?? []
            allPlaces = (try? state.library?.catalog.distinctPlaces()) ?? []
        }
    }

    // MARK: — Leading "add" menus

    @ViewBuilder
    private var peopleMenu: some View {
        if !allPeople.isEmpty {
            Menu {
                ForEach(allPeople, id: \.id) { person in
                    Button(person.name) { addPerson(person.id) }
                }
            } label: { menuChip("People") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    @ViewBuilder
    private var foldersMenu: some View {
        let paths = folderPaths(state.folderTree)
        if !paths.isEmpty {
            Menu {
                ForEach(paths, id: \.self) { path in
                    Button(folderLabel(path)) { addFolder(path) }
                }
            } label: { menuChip("Folders") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    @ViewBuilder
    private var placesMenu: some View {
        if !allPlaces.isEmpty {
            let countries = allPlaces.filter { $0.city.isEmpty }
            let cities = allPlaces.filter { !$0.city.isEmpty }
            Menu {
                ForEach(countries, id: \.self) { facet in
                    Button("\(facet.country) (\(facet.count))") {
                        addPlace(.country(facet.countryCode))
                    }
                }
                if !countries.isEmpty && !cities.isEmpty { Divider() }
                ForEach(cities, id: \.self) { facet in
                    Button("\(facet.city), \(facet.country) (\(facet.count))") {
                        addPlace(.city(countryCode: facet.countryCode, city: facet.city))
                    }
                }
            } label: { menuChip("Places") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    @ViewBuilder
    private var camerasMenu: some View {
        if !cameras.isEmpty {
            Menu {
                ForEach(cameras, id: \.self) { cam in
                    Button(cam) { addCamera(cam) }
                }
            } label: { menuChip("Cameras") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    @ViewBuilder
    private var tagsMenu: some View {
        if !allTags.isEmpty {
            Menu {
                ForEach(allTags, id: \.self) { tag in
                    Button(tag) { addTag(tag) }
                }
            } label: { menuChip("Tags") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var dateMenu: some View {
        Menu {
            Button("Any date") {
                state.searchFilters.dateRange = nil
                state.runSearch()
            }
            Divider()
            ForEach(DatePreset.relative, id: \.self) { preset in
                Button(preset.label) { setDate(preset) }
            }
            Divider()
            ForEach(DatePreset.recentYears(asOf: Date()), id: \.self) { preset in
                Button(preset.label) { setDate(preset) }
            }
        } label: {
            menuChip("Date", active: filters.dateRange != nil)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: — More menu (non-negatable controls)

    private var moreMenu: some View {
        Menu {
            Menu("Rating") {
                Button("Any rating") { state.searchFilters.minRating = nil; state.runSearch() }
                Divider()
                ForEach([1, 2, 3, 4, 5], id: \.self) { r in
                    Button("\(r)+ stars") { state.searchFilters.minRating = r; state.runSearch() }
                }
            }
            Toggle("Favourites only", isOn: Binding(
                get: { filters.favoritesOnly },
                set: { state.searchFilters.favoritesOnly = $0; state.runSearch() }))
            Menu("Kind") {
                Button("Any kind") { state.searchFilters.kind = nil; state.runSearch() }
                Divider()
                Button("Photos") { state.searchFilters.kind = .photo; state.runSearch() }
                Button("Videos") { state.searchFilters.kind = .video; state.runSearch() }
                Button("Live") { state.searchFilters.kind = .live; state.runSearch() }
            }
            Menu("People") {
                Button("Any") { state.searchFilters.peoplePresence = nil; state.runSearch() }
                Divider()
                Button("Has people") { state.searchFilters.peoplePresence = .has; state.runSearch() }
                Button("Without people") { state.searchFilters.peoplePresence = .without; state.runSearch() }
            }
            Toggle("Has text", isOn: Binding(
                get: { filters.hasText },
                set: { state.searchFilters.hasText = $0; state.runSearch() }))
            Toggle("Recursive folders", isOn: Binding(
                get: { filters.foldersRecursive },
                set: { state.searchFilters.foldersRecursive = $0; state.runSearch() }))
        } label: {
            menuChip("More", active: hasMoreActive)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var hasMoreActive: Bool {
        filters.minRating != nil || filters.favoritesOnly || filters.kind != nil
            || filters.peoplePresence != nil || filters.hasText
    }

    // MARK: — Active chips

    private var hasAnyChip: Bool {
        !filters.includePeople.isEmpty || !filters.excludePeople.isEmpty
            || !filters.includeFolders.isEmpty || !filters.excludeFolders.isEmpty
            || !filters.includePlaces.isEmpty || !filters.excludePlaces.isEmpty
            || !filters.includeCameras.isEmpty || !filters.excludeCameras.isEmpty
            || !filters.includeTags.isEmpty || !filters.excludeTags.isEmpty
    }

    @ViewBuilder
    private var chips: some View {
        // People
        ForEach(filters.includePeople + filters.excludePeople, id: \.self) { pid in
            FilterChip(label: personName(pid), symbol: "person",
                       state: filters.includePeople.contains(pid) ? .included : .excluded,
                       onToggle: { togglePerson(pid) },
                       onRemove: { removePerson(pid) })
        }
        // Folders
        ForEach(filters.includeFolders + filters.excludeFolders, id: \.self) { path in
            FilterChip(label: folderLabel(path), symbol: "folder",
                       state: filters.includeFolders.contains(path) ? .included : .excluded,
                       onToggle: { toggleFolder(path) },
                       onRemove: { removeFolder(path) })
        }
        // Places
        ForEach(filters.includePlaces + filters.excludePlaces, id: \.self) { place in
            FilterChip(label: placeLabel(place), symbol: "mappin.and.ellipse",
                       state: filters.includePlaces.contains(place) ? .included : .excluded,
                       onToggle: { togglePlace(place) },
                       onRemove: { removePlace(place) })
        }
        // Cameras
        ForEach(filters.includeCameras + filters.excludeCameras, id: \.self) { cam in
            FilterChip(label: cam, symbol: "camera",
                       state: filters.includeCameras.contains(cam) ? .included : .excluded,
                       onToggle: { toggleCamera(cam) },
                       onRemove: { removeCamera(cam) })
        }
        // Tags
        ForEach(filters.includeTags + filters.excludeTags, id: \.self) { tag in
            FilterChip(label: tag,
                       state: filters.includeTags.contains(tag) ? .included : .excluded,
                       onToggle: { toggleTag(tag) },
                       onRemove: { removeTag(tag) })
        }
    }

    // MARK: — Add (dedupe across both sets)

    private func addPerson(_ id: Int64) {
        guard !filters.includePeople.contains(id), !filters.excludePeople.contains(id) else { return }
        state.searchFilters.includePeople.append(id); state.runSearch()
    }
    private func addFolder(_ path: String) {
        guard !filters.includeFolders.contains(path), !filters.excludeFolders.contains(path) else { return }
        state.searchFilters.includeFolders.append(path); state.runSearch()
    }
    private func addPlace(_ place: PlaceFilter) {
        guard !filters.includePlaces.contains(place), !filters.excludePlaces.contains(place) else { return }
        state.searchFilters.includePlaces.append(place); state.runSearch()
    }
    private func addCamera(_ cam: String) {
        guard !filters.includeCameras.contains(cam), !filters.excludeCameras.contains(cam) else { return }
        state.searchFilters.includeCameras.append(cam); state.runSearch()
    }
    private func addTag(_ tag: String) {
        guard !filters.includeTags.contains(tag), !filters.excludeTags.contains(tag) else { return }
        state.searchFilters.includeTags.append(tag); state.runSearch()
    }

    private func setDate(_ preset: DatePreset) {
        state.searchFilters.dateRange = preset.range(asOf: Date()); state.runSearch()
    }

    // MARK: — Toggle include ⇆ exclude

    private func togglePerson(_ id: Int64) {
        if let i = filters.includePeople.firstIndex(of: id) {
            state.searchFilters.includePeople.remove(at: i)
            state.searchFilters.excludePeople.append(id)
        } else if let i = filters.excludePeople.firstIndex(of: id) {
            state.searchFilters.excludePeople.remove(at: i)
            state.searchFilters.includePeople.append(id)
        }
        state.runSearch()
    }
    private func toggleFolder(_ path: String) {
        if let i = filters.includeFolders.firstIndex(of: path) {
            state.searchFilters.includeFolders.remove(at: i)
            state.searchFilters.excludeFolders.append(path)
        } else if let i = filters.excludeFolders.firstIndex(of: path) {
            state.searchFilters.excludeFolders.remove(at: i)
            state.searchFilters.includeFolders.append(path)
        }
        state.runSearch()
    }
    private func togglePlace(_ place: PlaceFilter) {
        if let i = filters.includePlaces.firstIndex(of: place) {
            state.searchFilters.includePlaces.remove(at: i)
            state.searchFilters.excludePlaces.append(place)
        } else if let i = filters.excludePlaces.firstIndex(of: place) {
            state.searchFilters.excludePlaces.remove(at: i)
            state.searchFilters.includePlaces.append(place)
        }
        state.runSearch()
    }
    private func toggleCamera(_ cam: String) {
        if let i = filters.includeCameras.firstIndex(of: cam) {
            state.searchFilters.includeCameras.remove(at: i)
            state.searchFilters.excludeCameras.append(cam)
        } else if let i = filters.excludeCameras.firstIndex(of: cam) {
            state.searchFilters.excludeCameras.remove(at: i)
            state.searchFilters.includeCameras.append(cam)
        }
        state.runSearch()
    }
    private func toggleTag(_ tag: String) {
        if let i = filters.includeTags.firstIndex(of: tag) {
            state.searchFilters.includeTags.remove(at: i)
            state.searchFilters.excludeTags.append(tag)
        } else if let i = filters.excludeTags.firstIndex(of: tag) {
            state.searchFilters.excludeTags.remove(at: i)
            state.searchFilters.includeTags.append(tag)
        }
        state.runSearch()
    }

    // MARK: — Remove (drop from both sets)

    private func removePerson(_ id: Int64) {
        state.searchFilters.includePeople.removeAll { $0 == id }
        state.searchFilters.excludePeople.removeAll { $0 == id }
        state.runSearch()
    }
    private func removeFolder(_ path: String) {
        state.searchFilters.includeFolders.removeAll { $0 == path }
        state.searchFilters.excludeFolders.removeAll { $0 == path }
        state.runSearch()
    }
    private func removePlace(_ place: PlaceFilter) {
        state.searchFilters.includePlaces.removeAll { $0 == place }
        state.searchFilters.excludePlaces.removeAll { $0 == place }
        state.runSearch()
    }
    private func removeCamera(_ cam: String) {
        state.searchFilters.includeCameras.removeAll { $0 == cam }
        state.searchFilters.excludeCameras.removeAll { $0 == cam }
        state.runSearch()
    }
    private func removeTag(_ tag: String) {
        state.searchFilters.includeTags.removeAll { $0 == tag }
        state.searchFilters.excludeTags.removeAll { $0 == tag }
        state.runSearch()
    }

    // MARK: — Labels / helpers

    private func personName(_ id: Int64) -> String {
        allPeople.first { $0.id == id }?.name ?? "Person \(id)"
    }

    private func placeLabel(_ place: PlaceFilter) -> String {
        switch place {
        case .country(let cc):
            return allPlaces.first { $0.countryCode == cc && $0.city.isEmpty }?.country ?? cc
        case .city(let cc, let city):
            if let f = allPlaces.first(where: { $0.countryCode == cc && $0.city == city }) {
                return "\(f.city), \(f.country)"
            }
            return city
        }
    }

    private func folderPaths(_ nodes: [FolderNode]) -> [String] {
        nodes.flatMap { [$0.path] + folderPaths($0.children) }.sorted()
    }

    private func folderLabel(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    @ViewBuilder
    private func menuChip(_ label: String, active: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 12))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(active ? Theme.accentDim : Theme.elevated,
                    in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(active ? Theme.accent : Theme.textDim)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(active ? Theme.accent.opacity(0.4) : Theme.hairline, lineWidth: 1))
    }
}
