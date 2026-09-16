import SwiftUI
import OpenPhotoCore

/// Edit the focused trip. Every control writes straight through an AppState mutation (saved
/// automatically); reset links fall back to the derived value. The layout mirrors the mockup.
struct TravelInspector: View {
    @Bindable var state: AppState
    let trip: TravelSummary

    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var derived: TravelStats?        // what the photos themselves say
    @State private var items: [TimelineItem] = []   // the cover grid's page, never the whole trip
    @State private var itemCount = 0
    @State private var nameTripID: String?          // the trip `name` was typed for
    @State private var showAddFolder = false
    @FocusState private var field: TravelTextField?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nameSection
                    foldersSection
                    datesSection
                    placesSection
                    coverSection
                }
                .padding(.horizontal, 14)
            }
            Divider().overlay(Theme.hairline)
            footer
        }
        .background(Theme.bg2)
        .task(id: trip.id) { loadTrip() }
        .task(id: trip.folders) { loadItems() }
        .task(id: state.refreshToken) { refresh() }
        // "Done" doesn't necessarily move focus, so an in-flight name edit has to be committed on
        // the way out; a field can also still hold the keyboard here, and the ring would then never
        // get its shortcuts back.
        .onDisappear { commitName(); state.isEditingText = false }
        .onChange(of: field) { old, new in
            state.isEditingText = new != nil
            if old == .name && new != .name { commitName() }
        }
        .sheet(isPresented: $showAddFolder) {
            FolderPickerSheet(state: state, mode: .addFolder(exclude: trip.folders)) { p, _ in
                state.addTravelFolder(id: trip.id, p)
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Text("Edit trip").font(.system(size: 13, weight: .semibold))
            Text(trip.definition.isDiscovered ? "From Travels folder" : "Added by hand")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Spacer()
            Button("Done") { state.travelEditing = false }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Remove from Travels", role: .destructive) {
                state.removeTravel(id: trip.id)
                state.travelEditing = false
            }
            Spacer()
            Text("Saved automatically").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .controlSize(.small).padding(12)
    }

    // MARK: - Sections

    private var nameSection: some View {
        section("Name", reset: trip.definition.record?.name != nil ? ("Use folder name", { state.setTravelName(id: trip.id, nil) }) : nil) {
            TextField("Trip name", text: $name)
                .textFieldStyle(.roundedBorder).font(.system(size: 15, weight: .semibold))
                .focused($field, equals: .name)
                .onSubmit { field = nil }
        }
    }

    private var foldersSection: some View {
        section("Folders", reset: nil) {
            VStack(spacing: 4) {
                ForEach(trip.folders, id: \.self) { f in
                    let st = state.travelStatsForFolder(f)
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Theme.textDim)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f).font(.system(size: 12.5)).lineLimit(1).truncationMode(.head).help(f)
                            Text("\(st.count.formatted()) photos")
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Button { state.removeTravelFolder(id: trip.id, f) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                            .help("Remove folder from this trip")
                    }
                    .padding(8).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                }
            }
            Button { showAddFolder = true } label: { Label("Add folder…", systemImage: "plus") }
                .controlSize(.small).padding(.top, 6)
            Text("Subfolders are always included. Removing a folder here only changes the trip; nothing on disk is touched.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).padding(.top, 6)
        }
    }

    private var datesSection: some View {
        section("Dates", reset: trip.datesOverridden ? ("Use photo dates", { state.setTravelDates(id: trip.id, start: nil, end: nil) }) : nil) {
            HStack(spacing: 6) {
                // Committing from the binding's SETTER, not `onChange`: `load()` writes `start`/`end`
                // directly, so populating the pickers can never be mistaken for the user picking a
                // date (which would otherwise stamp an override on an undated trip).
                DatePicker("", selection: Binding(get: { start }, set: { d in start = d; commitDates(d, end) }),
                           displayedComponents: .date).labelsHidden()
                Text("–").foregroundStyle(Theme.textFaint)
                DatePicker("", selection: Binding(get: { end }, set: { d in end = d; commitDates(start, d) }),
                           displayedComponents: .date).labelsHidden()
            }
            Text(detectedDatesLine)
                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textFaint).padding(.top, 6)
        }
    }

    private var placesSection: some View {
        section("Places", reset: trip.placesOverridden ? ("Use detected", { state.setTravelPlaces(id: trip.id, nil) }) : nil) {
            PlaceChipsField(state: state, places: trip.places, overridden: trip.placesOverridden, focus: $field) {
                state.setTravelPlaces(id: trip.id, $0)
            }
            Text("Detected from photo locations. Type a place and press Return; suggestions are real map places.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).padding(.top, 6)
        }
    }

    private var coverSection: some View {
        section("Cover", reset: trip.coverOverridden ? ("Automatic", { state.setTravelCover(id: trip.id, nil) }) : nil) {
            if let lib = state.library {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(items, id: \.instanceID) { item in
                        let on = item.hash == trip.coverHash
                        Button { state.setTravelCover(id: trip.id, item.hash) } label: {
                            ThumbnailImage(timelineItem: item, library: lib, targetPixel: 160)
                                .aspectRatio(3 / 4, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) {
                                    if on {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.accent).padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if itemCount > 48 {
                    Text("Showing the first 48 photos.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Data

    /// A different trip is in front (another card clicked, or `mutateTravel` materialised this one
    /// under a fresh id). Unsaved text in the field belongs to the trip it was typed for, so it goes
    /// there first — never to the trip that just arrived.
    private func loadTrip() {
        if field == .name, let old = nameTripID, old != trip.id { write(name, to: old) }
        name = trip.name
        nameTripID = trip.id
        loadDates()
        derived = stats()
    }

    /// The only path that fetches photos, keyed on the folders rather than `refreshToken`: this is
    /// the trip's whole item list, and every date step, chip and cover click bumps that token. The
    /// folders change on a trip switch too (no two trips share a folder), so the grid still follows.
    private func loadItems() {
        let all = state.travelItems(trip)
        itemCount = all.count
        items = Array(all.prefix(48))
    }

    /// Something changed under the same trip (an edit here, or a background rescan). Cheap reads
    /// only — no `travelItems` fetch, which would materialise every row of the trip on every bump.
    private func refresh() {
        // Never clobber what the user is typing.
        if field != .name { name = trip.name; nameTripID = trip.id }
        loadDates()
        derived = stats()
    }

    private func loadDates() {
        start = trip.startDate.flatMap(TravelFormat.date) ?? Date()
        end = trip.endDate.flatMap(TravelFormat.date) ?? start
    }

    private func stats() -> TravelStats? {
        try? state.library?.catalog.travelStats(dirPaths: trip.folders)
    }

    private func commitName() {
        guard let id = nameTripID, id == trip.id else { return }
        write(name, to: id)
    }

    /// Only a real change writes: focusing and leaving the field must not materialise a record (nor
    /// pin a name that is still just the folder's). A trip that has since gone writes nothing.
    private func write(_ text: String, to id: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = state.travels.first(where: { $0.id == id })?.name, t != current else { return }
        state.setTravelName(id: id, t)
    }

    private func commitDates(_ s: Date, _ e: Date) {
        let ns = Self.dateString(s), ne = Self.dateString(e)
        guard ns != trip.startDate || ne != trip.endDate else { return }
        state.setTravelDates(id: trip.id, start: ns, end: ne)
    }

    private static func dateString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// What the photos say, next to whatever the user set — the ring already carries the amber dot.
    private var detectedDatesLine: String {
        guard let a = derived?.minTakenAtMs, let b = derived?.maxTakenAtMs else { return "No dates in these photos" }
        let f = Date.FormatStyle().month(.abbreviated).day().year()
        let da = Date(timeIntervalSince1970: Double(a) / 1000)
        let db = Date(timeIntervalSince1970: Double(b) / 1000)
        return "Photos say \(da.formatted(f)) – \(db.formatted(f))" + (trip.datesOverridden ? " · overridden" : "")
    }

    @ViewBuilder private func section<C: View>(_ title: String, reset: (String, () -> Void)?,
                                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.66)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if let (label, action) = reset {
                    Button(label, action: action).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        Divider().overlay(Theme.hairline)
    }
}
