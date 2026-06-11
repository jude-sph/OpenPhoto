import SwiftUI
import MapKit
import OpenPhotoCore

struct InspectorView: View {
    @Bindable var state: AppState
    let item: TimelineItem

    @State private var caption = ""
    @State private var rating = 0
    @State private var favorite = false
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var filenameHovered = false
    @State private var showDelete = false
    @State private var showEvict = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
                    .formatted(date: .complete, time: .shortened))
                    .font(.system(size: 13, weight: .semibold))

                if state.isDriveOnly(item) {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 11))
                        Text("On drive — view only")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.textFaint)
                }

                section("Caption") {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(8).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { save() }
                }
                .disabled(state.isDriveOnly(item))

                section("Rating") {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { i in
                            Button {
                                rating = (rating == i) ? 0 : i
                                save()
                            } label: {
                                Image(systemName: i <= rating ? "star.fill" : "star")
                                    .foregroundStyle(i <= rating ? Theme.amber : Theme.textFaint)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Button {
                            favorite.toggle(); save()
                        } label: {
                            Image(systemName: favorite ? "heart.fill" : "heart")
                                .foregroundStyle(favorite ? Theme.accent : Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                }
                .disabled(state.isDriveOnly(item))

                section("Tags") {
                    FlowLayoutLite(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Button {
                                    state.searchQuery = ""
                                    state.searchFilters = SearchFilters(tags: [tag])
                                    state.selection = .search
                                    state.openedItem = nil
                                    state.runSearch()
                                } label: {
                                    Text(tag).font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                Button {
                                    tags.removeAll { $0 == tag }; save()
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accentDim, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(Theme.accent)
                        }
                        TextField("Add tag", text: $newTag)
                            .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 70)
                            .onSubmit {
                                let t = newTag.trimmingCharacters(in: .whitespaces)
                                if !t.isEmpty, !tags.contains(t) { tags.append(t); save() }
                                newTag = ""
                            }
                    }
                }
                .disabled(state.isDriveOnly(item))

                Divider().overlay(Theme.hairline)

                section(item.cameraModel ?? "Details") {
                    exifGrid
                }

                if let lat = item.latitude, let lon = item.longitude {
                    section("Location") {
                        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))) {
                            Marker("", coordinate: coord).tint(Theme.accent)
                        }
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                        Text(String(format: "%.4f, %.4f", lat, lon))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                        if let place = try? state.library?.catalog.geocode(forHash: item.hash) {
                            Button {
                                state.searchInPlace(place)
                            } label: {
                                Label(placeLabel(place), systemImage: "mappin.and.ellipse")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }

                Divider().overlay(Theme.hairline)

                section("Locations") {
                    let locations = state.locations(for: item)
                    if locations.isEmpty {
                        Text("Only on this Mac")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    } else {
                        ForEach(locations) { loc in
                            locationRow(loc)
                        }
                    }
                    // At-a-glance "not backed up": flag absence from the canonical drive.
                    if !state.durableVaults.isEmpty && !state.isBackedUpOnCanonical(item) {
                        notOnCanonicalRow()
                    }
                }

                section("File") {
                    VStack(alignment: .leading, spacing: 2) {
                        // Folder path (everything up to last "/")
                        let nsPath = item.relPath as NSString
                        let folder = nsPath.deletingLastPathComponent
                        let filename = nsPath.lastPathComponent
                        if !folder.isEmpty {
                            Text(folder)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                        }
                        // Filename — clickable to rename
                        if renaming {
                            TextField("Filename", text: $newName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .focused($renameFocused)
                                .onSubmit {
                                    let name = newName.trimmingCharacters(in: .whitespaces)
                                    guard !name.isEmpty else { renaming = false; return }
                                    Task {
                                        if let lib = state.library {
                                            try? await lib.rename(item, to: name)
                                            try? state.refreshQueries()
                                            if let updated = try? lib.item(hash: item.hash) {
                                                state.openedItem = updated
                                            }
                                        }
                                        renaming = false
                                    }
                                }
                                .onExitCommand { renaming = false }
                        } else {
                            Text(filename)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .underline(filenameHovered && !state.isDriveOnly(item))
                                .onHover { filenameHovered = $0 }
                                // System-managed cursor — auto-balanced, so it can
                                // never get stuck (the manual NSCursor.push/pop did
                                // when the label was swapped for the editor mid-hover).
                                .pointerStyle(state.isDriveOnly(item) ? .default : .horizontalText)
                                .onTapGesture {
                                    guard !state.isDriveOnly(item) else { return }
                                    newName = filename
                                    renaming = true
                                    renameFocused = true
                                }
                        }
                    }
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: item.size,
                                                       countStyle: .file))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Reveal in Finder") {
                            if let url = state.fullResURL(for: item) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        .controlSize(.small)
                        .disabled(state.fullResURL(for: item) == nil)  // unreachable (drive ejected / missing)
                    }
                }
                deleteEvictActions
            }
            .padding(16)
        }
        .background(Theme.bg2)
        .task(id: item.hash) { load() }
        .alert("Delete this photo?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                state.removeOpenedItem { await state.delete($0) }   // advance to next, like the keyboard
            }
        } message: {
            Text("It moves to the bin (restore anytime). On connected drives, its copy is then queued for removal — review under the drive before anything is deleted there.")
        }
        .alert("Evict this photo?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Evict", role: .destructive) {
                state.removeOpenedItem { await state.evict($0) }     // advance to next, then evict
            }
        } message: {
            Text(evictAlertMessage(total: 1, onlyCopy: state.onlyCopyCount([item])))
        }
    }

    /// Delete / Evict for the photo on screen. Hidden for drive-only assets (view-only —
    /// there’s no local copy to bin; deleting a drive-only photo arrives in Slice 4).
    @ViewBuilder private var deleteEvictActions: some View {
        if !state.isDriveOnly(item) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                Button(role: .destructive) { showDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Move to the bin and queue removal from drives (review before it propagates).")
                Button { showEvict = true } label: {
                    Label("Evict", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .help("Free local space — keep the copy on the drive. Doesn’t delete anywhere.")
                Spacer()
            }
        } else if state.rehydratableItems([item]).count == 1 {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                Button { Task { _ = await state.rehydrate([item]) } } label: {
                    Label("Rehydrate", systemImage: "arrow.down.circle.dotted")
                }.controlSize(.small)
                Spacer()
            }
        }
    }

    private var exifGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            if let w = item.pixelWidth, let h = item.pixelHeight {
                GridRow { gLabel("Dimensions"); gValue("\(w) × \(h)") }
            }
            if let lens = item.lensModel { GridRow { gLabel("Lens"); gValue(lens) } }
            if let d = item.durationSeconds {
                GridRow { gLabel("Duration"); gValue(String(format: "%.1fs", d)) }
            }
            GridRow { gLabel("Kind"); gValue(item.livePairHash != nil ? "Live Photo" : item.kind) }
        }
    }

    @ViewBuilder private func locationRow(_ loc: Location) -> some View {
        HStack(spacing: 8) {
            Image(systemName: locationSymbol(loc.place))
                .foregroundStyle(Theme.textDim).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(locationName(loc.place)).font(.system(size: 12.5))
                if !loc.detail.isEmpty {
                    Text(loc.detail).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            confidenceBadge(loc.confidence)
        }
    }

    @ViewBuilder private func notOnCanonicalRow() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .foregroundStyle(.orange).frame(width: 16)
            Text("Not on the canonical drive")
                .font(.system(size: 12.5)).foregroundStyle(.orange)
            Spacer()
        }
    }

    private func locationSymbol(_ place: Location.Place) -> String {
        switch place {
        case .thisMac: return "laptopcomputer"
        case .device(_, _, let kind): return kind == .phone ? "iphone" : "sdcard"
        }
    }
    private func locationName(_ place: Location.Place) -> String {
        switch place {
        case .thisMac: return "This Mac"
        case .device(_, let name, _): return name
        }
    }
    @ViewBuilder private func confidenceBadge(_ c: Location.Confidence) -> some View {
        switch c {
        case .confirmed:
            Image(systemName: "checkmark").foregroundStyle(Theme.green)
        case .believed:
            Text("sent").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.blue)
        case .historical:
            Text("was here").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func gLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Theme.textFaint)
    }
    private func gValue(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold).monospacedDigit())
    }

    private func placeLabel(_ place: GeocodeRow) -> String {
        var parts: [String] = []
        if !place.city.isEmpty { parts.append(place.city) }
        // Include region only when it differs from the city (avoids "Tokyo, Tokyo, Japan").
        if !place.region.isEmpty && place.region != place.city { parts.append(place.region) }
        if !place.country.isEmpty { parts.append(place.country) }
        return parts.joined(separator: ", ")
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.4)
                .foregroundStyle(Theme.textFaint)
            content()
        }
    }

    private func load() {
        caption = item.caption ?? ""
        rating = item.rating
        favorite = item.favorite
        tags = (try? JSONDecoder().decode([String].self,
                                          from: Data(item.tagsJSON.utf8))) ?? []
    }

    private func save() {
        guard let lib = state.library else { return }
        try? lib.updateMetadata(for: item,
                                rating: rating, favorite: favorite,
                                caption: caption.isEmpty ? nil : caption, tags: tags)
        try? state.refreshQueries()
        if let updated = try? lib.item(hash: item.hash) { state.openedItem = updated }
    }
}

/// Minimal wrapping layout for tag chips.
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
