import SwiftUI
import OpenPhotoCore

/// Open trip: hero cover, facts, then every photo grouped by day (with the day's place when the
/// day's photos were geocoded). Tapping a photo opens the normal viewer over the whole trip.
struct TravelDetailView: View {
    @Bindable var state: AppState
    let trip: TravelSummary
    @State private var days: [(title: String, place: String?, items: [TimelineItem])] = []
    @State private var all: [TimelineItem] = []
    @FocusState private var pageFocused: Bool
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                HStack(spacing: 28) {
                    fact("Photos", trip.count.formatted())
                    fact("Places", trip.places.isEmpty ? "—" : "\(trip.places.count)" + (trip.country.map { " in \($0)" } ?? ""))
                    fact("Days", "\(TravelFormat.days(trip))")
                    fact("Folders", "\(trip.folders.count)")
                }.padding(.horizontal, 28).padding(.vertical, 16)
                Divider().overlay(Theme.hairline)
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: .sectionHeaders) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize), spacing: Theme.gridGap)], spacing: Theme.gridGap) {
                                ForEach(day.items, id: \.instanceID) { item in tile(item) }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Text(day.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textDim)
                                if let p = day.place { Text(p).font(.system(size: 12.5)).foregroundStyle(Theme.textFaint) }
                                Text("\(day.items.count) photos").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.textFaint)
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).background(Theme.windowBG)
                        }
                    }
                }.padding(.horizontal, 28).padding(.vertical, 8)
            }
        }
        .background(Theme.windowBG)
        .focusable()
        .focusEffectDisabled()
        .focused($pageFocused)
        .onAppear { pageFocused = true }
        // Keyed on the folders, like the inspector's item fetch: this is the trip's whole item list
        // plus a geocode query, and every cover click / background rescan bumps `refreshToken`. No
        // two trips share a folder, so the page still follows a trip switch; the hero and the facts
        // read `trip`, which AppState has already re-derived by then.
        .task(id: trip.folders) { load() }
        .onKeyPress(.escape) { if state.isEditingText { return .ignored }; state.openedTravelID = nil; return .handled }
        .transition(.opacity)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if let lib = state.library { TravelRingView.coverThumbnail(for: trip, library: lib, targetPixel: 1600).frame(height: 300).clipped() }
            LinearGradient(colors: [Theme.windowBG, .clear], startPoint: .bottom, endPoint: .init(x: 0.5, y: 0.4))
            VStack(alignment: .leading, spacing: 6) {
                Text(trip.name).font(.system(size: 34, weight: .semibold)).kerning(-0.8)
                Text(heroLine).font(.system(size: 14)).foregroundStyle(Theme.textDim)
            }.padding(.horizontal, 28).padding(.bottom, 18)
        }
        .frame(height: 300)
        .overlay(alignment: .top) {
            HStack {
                Button { state.openedTravelID = nil } label: { Label("Travels", systemImage: "chevron.left") }
                Spacer()
                Button("Edit trip") { state.openedTravelID = nil; state.travelEditing = true }
            }.controlSize(.small).padding(14)
        }
    }

    /// Span and places, whichever of the two exists — a trip with no places must not trail a " · ".
    private var heroLine: String {
        [TravelFormat.span(trip), trip.places.map(\.name).joined(separator: " · ")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.66).foregroundStyle(Theme.textFaint)
            Text(value).font(.system(size: 13.5).monospacedDigit())
        }
    }

    @ViewBuilder private func tile(_ item: TimelineItem) -> some View {
        if let lib = state.library {
            MediaTile(id: item.instanceID,
                      thumbnail: ThumbnailImage(timelineItem: item, library: lib, targetPixel: thumbPixels),
                      badges: { TimelineTileBadges(item: item, backedUp: state.isBackedUpOnCanonical(item)) },
                      onTap: { state.openViewer(item, within: all) })
                .contextMenu { Button("Set as Trip Cover", systemImage: "photo") { state.setTravelCover(id: trip.id, item.hash) } }
        }
    }

    /// Group by local calendar day (oldest first) and pick the day's most common geocoded city.
    private func load() {
        all = state.travelItems(trip)
        let cal = Calendar.current
        var groups: [(Date, [TimelineItem])] = []
        for it in all {
            let d = cal.startOfDay(for: Date(timeIntervalSince1970: Double(it.takenAtMs) / 1000))
            if let last = groups.last, last.0 == d { groups[groups.count - 1].1.append(it) } else { groups.append((d, [it])) }
        }
        // One query for the whole trip, not one per photo: a 4 000-photo trip used to run 4 000
        // statements (capped at 200 a day) just to label the day headers.
        var cities: [String: String] = [:]
        if let cat = state.library?.catalog {
            cities = (try? cat.geocodeCities(forHashes: all.map(\.hash))) ?? [:]
        }
        let f = Date.FormatStyle().weekday(.wide).month(.wide).day()
        days = groups.map { day, items in
            var counts: [String: Int] = [:]
            for it in items { if let c = cities[it.hash] { counts[c, default: 0] += 1 } }
            let place = counts.max { $0.value < $1.value }?.key
            return (day.formatted(f), place, items)
        }
    }
}
