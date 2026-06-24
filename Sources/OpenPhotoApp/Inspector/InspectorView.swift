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
    @State private var imageFaces: [FaceRow] = []
    @State private var instances: [InstanceRecord] = []   // all files of this content (multi-folder)
    @State private var memberAlbumIDs: Set<String> = []   // albums this photo belongs to
    @State private var peopleByID: [Int64: PersonRow] = [:]
    @State private var assignNewName = ""
    @State private var showAssignNew = false
    @State private var pendingAssignFaceID: Int64?
    /// Which inspector text field is focused — drives state.isEditingText so the viewer's key
    /// shortcuts yield while you type.
    private enum EditField: Hashable { case caption, tag }
    @FocusState private var editField: EditField?
    /// Bound camera so the location map re-centres when you navigate to a different photo
    /// (initialPosition is applied only once, so the reused Map kept the prior photo's region).
    @State private var mapCamera: MapCameraPosition = .automatic
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
                        .focused($editField, equals: .caption)
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

                section("Rotate") {
                    HStack(spacing: 16) {
                        Button { state.rotate(item, by: -90) } label: {
                            Image(systemName: "rotate.left")
                        }.buttonStyle(.plain).help("Rotate left (non-destructive)")
                        Button { state.rotate(item, by: 90) } label: {
                            Image(systemName: "rotate.right")
                        }.buttonStyle(.plain).help("Rotate right (non-destructive)")
                        Spacer()
                    }
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textDim)
                }
                .disabled(state.isDriveOnly(item))

                section("Tags") {
                    FlowLayoutLite(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Button {
                                    state.searchQuery = ""
                                    state.searchFilters = SearchFilters(includeTags: [tag])
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
                            .focused($editField, equals: .tag)
                            .onSubmit {
                                let t = newTag.trimmingCharacters(in: .whitespaces)
                                // "Favourite" is reserved for the heart toggle, not a normal tag.
                                if !t.isEmpty, !tags.contains(t),
                                   t.caseInsensitiveCompare(FinderTags.favoriteTagName) != .orderedSame {
                                    tags.append(t); save()
                                }
                                newTag = ""
                            }
                    }
                }
                .disabled(state.isDriveOnly(item))

                section("Albums") {
                    VStack(alignment: .leading, spacing: 6) {
                        let containing = state.albums.filter { memberAlbumIDs.contains($0.id) }
                        if !containing.isEmpty {
                            FlowLayoutLite(spacing: 6) {
                                ForEach(containing) { album in
                                    Button {
                                        state.selection = .albums
                                        state.selectedAlbumID = album.id
                                        state.openedItem = nil
                                    } label: { Text(album.name).font(.system(size: 12)) }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.accentDim, in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        AddToAlbumMenu(state: state, hashes: [item.hash],
                                       onDone: { loadAlbumMembership() })
                    }
                }

                inThisImageSection

                Divider().overlay(Theme.hairline)

                section(item.cameraModel ?? "Details") {
                    exifGrid
                }

                if let lat = item.latitude, let lon = item.longitude {
                    section("Location") {
                        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        // Interactive: scroll to zoom, drag to pan (no rotate/pitch — keep it flat).
                        // Bound position (reset per-item in load()) so it follows the current photo.
                        Map(position: $mapCamera, interactionModes: [.pan, .zoom]) {
                            Marker("", coordinate: coord).tint(Theme.accent)
                        }
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    // Every folder this image lives in (a duplicate spans several), each tagged Mac vs
                    // drive-only — so an evicted copy reads honestly instead of a blanket "This Mac".
                    let folders = state.folderPresences(for: item)
                    ForEach(folders) { folderPresenceRow($0) }
                    // Drives it's backed up on / devices it was sent to. The per-hash "This Mac" row is
                    // replaced by the per-folder rows above, so drop it here.
                    let devices = state.locations(for: item).filter {
                        if case .thisMac = $0.place { return false }; return true
                    }
                    ForEach(devices) { locationRow($0) }
                    if folders.isEmpty && devices.isEmpty {
                        Text("Only on this Mac")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
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
                                        // Records the undo + refreshes; alerts its own failures.
                                        await state.rename(item, to: name)
                                        if let lib = state.library,
                                           let updated = try? lib.item(hash: item.hash) {
                                            state.openedItem = updated
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

                // This content also lives in other folders (same sha256, different file). The timeline
                // shows it once; here are its other locations.
                if instances.count > 1 {
                    let others = instances.filter { !($0.vaultID == item.vaultID && $0.relPath == item.relPath) }
                    section("Also in \(others.count) other folder\(others.count == 1 ? "" : "s")") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(others, id: \.relPath) { inst in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        let folder = (inst.relPath as NSString).deletingLastPathComponent
                                        Text(folder.isEmpty ? "(library root)" : folder)
                                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                                        Text((inst.relPath as NSString).lastPathComponent)
                                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                                    }
                                    Spacer()
                                    Button("Reveal") { revealInstance(inst) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }

                deleteEvictActions
            }
            .padding(16)
        }
        .background(Theme.bg2)
        .task(id: item.hash) { load(); loadFaces(); loadInstances(); loadAlbumMembership() }
        .task(id: state.refreshToken) { loadAlbumMembership() }   // reflect adds/removes elsewhere
        // Tell the viewer to yield its key shortcuts while a caption/tag field is focused.
        .onChange(of: editField) { state.isEditingText = editField != nil }
        .onDisappear { state.isEditingText = false }
        .alert("Delete this photo?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                state.removeOpenedItem { await state.deletePhotos($0) }   // advance to next; delete the photo everywhere
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

    /// Faces detected in this photo, as chips: a circular crop + the person's name. Named faces are
    /// tappable (jump to that person in People); unconfirmed faces read "Unknown".
    private var inThisImageSection: some View {
        section("In this image") {
            VStack(alignment: .leading, spacing: 8) {
                if !imageFaces.isEmpty {
                    FlowLayoutLite(spacing: 8) {
                        ForEach(imageFaces, id: \.id) { face in faceChip(face) }
                    }
                }
                // Manually tag someone present even when no face was detected (obscured faces).
                TagPersonMenu(state: state, hashes: [item.hash], label: "Tag someone\u{2026}")
            }
            .onChange(of: state.refreshToken) { loadFaces() }   // reflect tag/assignment changes
        }
        .alert("Assign face to a new person", isPresented: $showAssignNew) {
            TextField("Name", text: $assignNewName)
            Button("Create") {
                let n = assignNewName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let fid = pendingAssignFaceID, !n.isEmpty { state.nameCluster([fid], as: n) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// One face/person chip. A named face or manual tag offers "Open" + "Remove"; an Unknown detected
    /// face offers a person picker to assign THAT face. Removing a detected face unassigns it (back to
    /// the Other bucket); removing a manual tag deletes it (the catalog drops manual tags on unassign,
    /// so no stray unassigned face is left behind).
    @ViewBuilder private func faceChip(_ face: FaceRow) -> some View {
        let person = face.personID.flatMap { peopleByID[$0] }
        let isManualTag = face.source == "manual"
        // Render the circular avatar OUTSIDE the Menu — a borderless Menu label doesn't honour a
        // .frame on a resizable image (it rendered at the crop's natural, varying size). Only the
        // name is the menu trigger; its label is plain text, which the menu sizes correctly.
        HStack(spacing: 6) {
            FaceCropView(state: state, faceID: face.id, hash: face.hash, rect: face.rect, size: 30)
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            Menu {
                if let person {
                    Button("Open \(person.name)") { state.openPerson(person) }
                    Button(role: .destructive) {
                        state.reassignFace(face.id ?? -1, to: nil, fromPerson: face.personID)
                    } label: { Text(isManualTag ? "Remove tag" : "Remove from photo") }
                } else if state.people.isEmpty {
                    Text("No people yet — use \u{201C}Tag someone\u{2026}\u{201D}")
                } else {
                    ForEach(state.people, id: \.id) { p in
                        Button(p.name) { state.reassignFace(face.id ?? -1, to: p.id, fromPerson: nil) }
                    }
                    Divider()
                    Button("New person\u{2026}") {
                        assignNewName = ""; pendingAssignFaceID = face.id; showAssignNew = true
                    }
                }
            } label: {
                Text(person?.name ?? "Unknown")
                    .font(.system(size: 12, weight: person != nil ? .medium : .regular))
                    .foregroundStyle(person != nil ? Theme.accent : Theme.textDim)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(person != nil ? "Open or remove" : "Assign this face to someone")
        }
        .padding(.leading, 3).padding(.trailing, 9).padding(.vertical, 3)
        .background(person != nil ? Theme.accentDim : Theme.elevated, in: Capsule())
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

    @ViewBuilder private func folderPresenceRow(_ fp: AppState.FolderPresence) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fp.onMac ? "laptopcomputer" : "sdcard")
                .foregroundStyle(Theme.textDim).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(fp.folder.isEmpty ? "(root)" : fp.folder)
                    .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Text(fp.onMac ? "On this Mac" : "On the drive only")
                    .font(.system(size: 10.5))
                    .foregroundStyle(fp.onMac ? Theme.textFaint : Theme.amber)
            }
            Spacer()
            if fp.onMac { Image(systemName: "checkmark").foregroundStyle(Theme.green) }
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
        case .stale:
            Text("removed").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.amber)
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
        // Re-centre the location map on THIS photo (load() runs on .task(id: item.hash)).
        if let lat = item.latitude, let lon = item.longitude {
            mapCamera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
    }

    /// Load the faces detected in this photo + a person lookup, newest-named first then by confidence.
    private func loadFaces() {
        let faces = (try? state.library?.catalog.faces(forHash: item.hash)) ?? []
        let ppl = (try? state.library?.catalog.people()) ?? []
        peopleByID = Dictionary(uniqueKeysWithValues: ppl.map { ($0.id, $0) })
        imageFaces = faces.sorted {
            let an = $0.personID != nil, bn = $1.personID != nil
            if an != bn { return an }                 // named chips first
            return $0.confidence > $1.confidence
        }
    }

    private func loadInstances() {
        instances = (try? state.library?.catalog.visibleInstances(forHash: item.hash)) ?? []
    }

    private func loadAlbumMembership() {
        memberAlbumIDs = (try? state.library?.catalog.albumIDsContaining(hash: item.hash)) ?? []
    }

    private func revealInstance(_ inst: InstanceRecord) {
        if let url = state.library?.vault(id: inst.vaultID)?.absoluteURL(forRelativePath: inst.relPath),
           FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func save() {
        guard let lib = state.library else { return }
        let reconciled = state.reconcileForSave(item: item, tags: tags, favorite: favorite)
        try? lib.updateMetadata(for: item,
                                rating: rating, favorite: reconciled.favorite,
                                caption: caption.isEmpty ? nil : caption,
                                tags: reconciled.tags)
        favorite = reconciled.favorite   // reflect a Finder-driven favourite back into the heart
        tags = reconciled.tags
        try? state.refreshQueries()
        // Refresh BOTH the opened item AND the array the viewer pages through, so navigating away
        // and back doesn't re-load a stale pre-edit snapshot (the heart was vanishing on return).
        if let updated = try? lib.item(hash: item.hash) {
            state.openedItem = updated
            for i in state.viewerItems.indices where state.viewerItems[i].hash == updated.hash {
                state.viewerItems[i] = updated
            }
        }
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
