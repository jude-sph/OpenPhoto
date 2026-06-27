import SwiftUI
import CoreGraphics
import OpenPhotoCore

// MARK: - Top-level People view

struct PeopleView: View {
    @Bindable var state: AppState
    /// nil = overview; non-nil = drill into an unnamed cluster to see its photos before naming it.
    @State private var selectedCluster: FaceCluster?

    var body: some View {
        if case .unavailable = (state.mlStatus[.faceRecognition] ?? .unknown) {
            ContentUnavailableView {
                Label("Face recognition unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("The face model couldn't be loaded on this Mac, so people can't be detected or grouped here.")
            }
        } else {
            if let cluster = selectedCluster {
                ClusterDetailView(state: state, cluster: cluster,
                                  onBack: { selectedCluster = nil })
            } else if state.browsingOtherFaces {
                OtherFacesDetailView(state: state, onBack: { state.browsingOtherFaces = false })
            } else if let person = state.openedPerson {
                // Person-detail navigation lives on AppState so the inspector can deep-link here.
                PersonDetailView(state: state, person: person,
                                 onBack: { state.openedPerson = nil })
            } else {
                PeopleOverviewView(state: state,
                                   onSelectPerson: { state.openedPerson = $0 },
                                   onOpenCluster: { selectedCluster = $0 },
                                   onBrowseOther: { state.browsingOtherFaces = true })
            }
        }
    }
}

// MARK: - Overview: named cards + suggested clusters

struct PeopleOverviewView: View {
    @Bindable var state: AppState
    var onSelectPerson: (PersonRow) -> Void
    var onOpenCluster: (FaceCluster) -> Void
    var onBrowseOther: () -> Void

    // Merge-selection state (select two named people to merge).
    @State private var mergeSelection: Set<Int64> = []
    @State private var mergeMode = false   // entered via "Select to merge…"; can hold 0 selections
    @State private var showMergeAlert = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            if state.facesLoading && state.people.isEmpty
                && state.suggestedClusters.isEmpty && state.otherFaceIDs.isEmpty {
                // Full-screen spinner only on the very first load — progressive reloads (during
                // re-derivation) keep the existing content visible instead of flickering to a spinner.
                Spacer()
                ProgressView("Analyzing faces…").foregroundStyle(Theme.textDim)
                Spacer()
            } else if state.people.isEmpty && state.suggestedClusters.isEmpty && state.otherFaceIDs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !state.people.isEmpty {
                            namedSection
                        }
                        if !state.suggestedClusters.isEmpty {
                            suggestedSection
                        }
                        if !state.otherFaceIDs.isEmpty {
                            otherFacesSection
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear {
            if state.people.isEmpty && state.suggestedClusters.isEmpty && state.otherFaceIDs.isEmpty {
                state.loadPeople()
            }
        }
        .alert("Merge People", isPresented: $showMergeAlert,
               actions: mergeAlertActions, message: mergeAlertMessage)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("People")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            if !state.people.isEmpty {
                Text("\(state.people.count) \(state.people.count == 1 ? "person" : "people")")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            if mergeMode {
                Text("Pick two people")
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                Button("Cancel") { mergeMode = false; mergeSelection = [] }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                if mergeSelection.count == 2 {
                    Button("Merge") { showMergeAlert = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            } else if state.people.count >= 2 {
                Button("Select to merge…") { mergeMode = true; mergeSelection = [] }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
            if state.facesLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    // MARK: Named people section

    private var namedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("People", count: state.people.count)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(state.people, id: \.id) { person in
                    PersonCard(
                        state: state,
                        person: person,
                        inMergeMode: mergeMode,
                        mergeSelected: mergeSelection.contains(person.id),
                        onTap: {
                            if mergeMode {
                                if mergeSelection.contains(person.id) {
                                    mergeSelection.remove(person.id)
                                } else if mergeSelection.count < 2 {
                                    mergeSelection.insert(person.id)
                                }
                            } else {
                                onSelectPerson(person)
                            }
                        },
                        onRemove: { state.removePerson(person.id) },
                        onRename: { state.renamePerson(person.id, to: $0) }
                    )
                }
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: Suggested clusters section

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Suggested", count: state.suggestedClusters.count)
            Text("Open a group to see its photos, then name it to add it to People.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .padding(.bottom, 2)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(state.suggestedClusters) { cluster in
                    ClusterCard(state: state, cluster: cluster,
                                onOpen: { onOpenCluster(cluster) })
                }
            }
        }
    }

    // MARK: Other faces (unclustered, unmatched — the bucket)

    private var otherFacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Other faces", count: state.otherFaceIDs.count)
            Text("Faces that didn't fall into a group. Open to select faces and add them to someone.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.bottom, 2)
            Button(action: onBrowseOther) {
                HStack(spacing: 12) {
                    if let first = state.otherFaceIDs.first {
                        FaceCropView(state: state, faceID: first, hash: nil, size: 64, fill: false)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.tile).frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other faces").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("\(state.otherFaceIDs.count) face\(state.otherFaceIDs.count == 1 ? "" : "s") to sort")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
                .padding(10)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 24)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textFaint)
            Text("No People Yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Once face analysis finishes, look-alike faces will\nappear here for you to name.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: Merge alert

    @ViewBuilder private func mergeAlertActions() -> some View {
        let ids = Array(mergeSelection)
        if ids.count == 2 {
            let src = ids[0], dst = ids[1]
            let srcName = state.people.first { $0.id == src }?.name ?? "Person"
            let dstName = state.people.first { $0.id == dst }?.name ?? "Person"
            Button("Merge \(srcName) into \(dstName)", role: .destructive) {
                state.mergePeople(src, into: dst)
                mergeSelection = []; mergeMode = false
            }
        }
        Button("Cancel", role: .cancel) { mergeSelection = [] }
    }

    @ViewBuilder private func mergeAlertMessage() -> some View {
        let ids = Array(mergeSelection)
        if ids.count == 2 {
            let dstName = state.people.first { $0.id == ids[1] }?.name ?? "Person"
            Text("All faces will be merged under \"\(dstName)\". This cannot be undone.")
        }
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.44)
                .foregroundStyle(Theme.textFaint)
            Text("(\(count))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
        }
    }
}

// MARK: - Named person card

struct PersonCard: View {
    @Bindable var state: AppState
    let person: PersonRow
    var inMergeMode: Bool
    var mergeSelected: Bool
    var onTap: () -> Void
    var onRemove: () -> Void
    var onRename: (String) -> Void
    @State private var renaming = false
    @State private var nameField = ""

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    FaceCropView(
                        state: state,
                        faceID: person.representativeFaceID,
                        hash: nil,
                        size: 90
                    )
                    .frame(width: 90, height: 90)
                    .clipShape(Circle())
                    if let n = state.suggestedAdditions[person.id]?.count, n > 0, !mergeSelected {
                        Text("+\(n)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                            .frame(width: 90, height: 90, alignment: .topTrailing)
                            .help("\(n) suggested face\(n == 1 ? "" : "s") — open to review")
                    }
                    if mergeSelected {
                        Circle()
                            .strokeBorder(Theme.accent, lineWidth: 3)
                            .frame(width: 90, height: 90)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .frame(width: 90, height: 90)
                            .padding(2)
                    }
                }
                Text(person.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(person.faceCount) \(person.faceCount == 1 ? "face" : "faces")")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            .padding(8)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { nameField = person.name; renaming = true } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            Button(role: .destructive) { onRemove() } label: {
                Label("Remove person", systemImage: "person.badge.minus")
            }
        }
        .alert("Rename person", isPresented: $renaming) {
            TextField("Name", text: $nameField)
            Button("Rename") {
                let n = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty, n != person.name { onRename(n) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Suggested cluster card

struct ClusterCard: View {
    @Bindable var state: AppState
    let cluster: FaceCluster
    var onOpen: () -> Void
    @State private var nameField = ""

    var body: some View {
        VStack(spacing: 6) {
            // Tap the face to open the group and review every photo before naming it.
            Button(action: onOpen) {
                ZStack(alignment: .bottomTrailing) {
                    FaceCropView(
                        state: state,
                        faceID: cluster.representativeFaceID,
                        hash: nil,
                        size: 90
                    )
                    .frame(width: 90, height: 90)
                    .clipShape(Circle())
                    if cluster.count > 1 {
                        Text("\(cluster.count)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.textDim.opacity(0.8), in: Capsule())
                            .padding(4)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open this group to see its photos")
            TextField("Name…", text: $nameField)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit {
                    let name = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    state.nameCluster(cluster.faceIDs, as: name)
                    nameField = ""
                }
        }
        .padding(8)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

// MARK: - Person detail view (photos this person appears in)

struct PersonDetailView: View {
    @Bindable var state: AppState
    let person: PersonRow
    var onBack: () -> Void

    @State private var pairs: [FacePhoto] = []
    @State private var allPeople: [PersonRow] = []
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var splitName = ""
    @State private var showSplitField = false
    @State private var showFaces = true
    @State private var renaming = false
    @State private var renameField = ""
    // Photo-action selection state (parity with Timeline/Folders).
    @State private var showEvict = false
    @State private var showForceEvict = false
    @State private var showDelete = false
    @State private var showSend = false
    @State private var sendChooser = false
    @State private var chosenSendDevice: ConnectedDevice?

    private let gridColumns = [GridItem(.adaptive(minimum: 108), spacing: Theme.gridGap)]
    private let space = "persongrid"
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: 120) }
    private var photos: [TimelineItem] { pairs.map(\.item) }
    private var orderedSelectable: [SelectableItem] {
        pairs.map { SelectableItem(id: $0.id) }
    }
    private var selectedFaceIDs: [Int64] { selection.selected.compactMap(Int64.init) }
    /// Selected photos (deduped by content hash) for the photo actions (send/share/album/delete/evict).
    private var selectedItems: [TimelineItem] {
        var seen = Set<String>(); var out: [TimelineItem] = []
        for pair in pairs where selection.contains(pair.id) {
            if seen.insert(pair.item.hash).inserted { out.append(pair.item) }
        }
        return out
    }
    private var evictableItems: [TimelineItem] { selectedItems.filter { $0.driveRelPath == nil } }
    private var rehydratableItems: [TimelineItem] { state.rehydratableItems(selectedItems) }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { detailToolbar }
            Divider().overlay(Theme.hairline)
            if !selectMode { suggestionStrip }
            if pairs.isEmpty {
                emptyFaces
            } else {
                grid
            }
        }
        .onAppear { reload() }
        .onChange(of: state.people) { reload() }   // refresh after suggestions are added/dismissed
        .alert("Move \(evictableItems.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let items = evictableItems
                Task { await state.evict(items); endSelect(); reload() }
            }
        } message: {
            Text(evictAlertMessage(total: evictableItems.count, onlyCopy: state.onlyCopyCount(evictableItems)))
        }
        .alert("Delete \(evictableItems.count) photo\(evictableItems.count == 1 ? "" : "s")?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let items = evictableItems
                Task { await state.deletePhotos(items); endSelect(); reload() }
            }
        } message: {
            Text("They move to the bin (restore anytime). On connected drives, their copies are then queued for removal — review under the drive before anything is deleted there.")
        }
        .alert("Split to new person", isPresented: $showSplitField) {
            TextField("Name", text: $splitName)
            Button("Create") {
                let name = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = selectedFaceIDs
                if !name.isEmpty, !ids.isEmpty { state.splitFaces(ids, fromPerson: person.id, toNewPerson: name) }
                splitName = ""; afterFaceAction()
            }
            Button("Cancel", role: .cancel) { splitName = "" }
        }
        .sheet(isPresented: $showSend, onDismiss: { chosenSendDevice = nil }) {
            if let target = chosenSendDevice ?? state.connectedSendTarget() {
                SendSheet(state: state, items: selectedItems, device: target) { endSelect() }
            }
        }
        .confirmationDialog("Send to which device?", isPresented: $sendChooser, titleVisibility: .visible) {
            ForEach(state.connectedSendTargets(), id: \.id) { dev in
                Button(dev.name) { chosenSendDevice = dev; showSend = true }
            }
        }
        .sheet(isPresented: $showForceEvict) {
            ForceEvictSheet(count: evictableItems.count) {
                let items = evictableItems
                Task { _ = await state.evict(items, mode: .forced); endSelect() }
            }
        }
    }

    private func endSelect() { selection.clear(); selectMode = false; showSplitField = false }
    private func afterFaceAction() { selection.clear(); reload() }

    /// Faces matched to this person's centroid, offered for one-tap confirmation. Tapping a face adds
    /// just it; "Add all" confirms the lot; "Dismiss" drops them to the Other-faces bucket.
    @ViewBuilder private var suggestionStrip: some View {
        if let ids = state.suggestedAdditions[person.id], !ids.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(ids.count) face\(ids.count == 1 ? "" : "s") might be \(person.name)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button("Add all") { state.moveFaces(ids, toPerson: person.id, fromPerson: nil) }
                        .controlSize(.small)
                    Button("Dismiss all") { state.dismissSuggestions(forPerson: person.id) }
                        .controlSize(.small)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ids, id: \.self) { fid in suggestionTile(fid) }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.bg2.opacity(0.4))
            Divider().overlay(Theme.hairline)
        }
    }

    /// One suggested-face tile: a larger face/photo thumbnail (honouring the Faces/Photos toggle)
    /// with an explicit ✓ accept and ✕ dismiss beneath it, so each suggestion can be judged on its own.
    private func suggestionTile(_ fid: Int64) -> some View {
        let s: CGFloat = 84
        return VStack(spacing: 6) {
            FaceCropView(state: state, faceID: fid, hash: nil, size: s, fill: false, cropToFace: showFaces)
                .frame(width: s, height: s)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Button { state.dismissSuggestion(faceID: fid, forPerson: person.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 19))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.textFaint)
                }.buttonStyle(.plain).help("Not \(person.name)")
                Button { state.moveFaces([fid], toPerson: person.id, fromPerson: nil) } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 19))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.green)
                }.buttonStyle(.plain).help("Add to \(person.name)")
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: Theme.gridGap) {
                ForEach(pairs) { pair in
                    FacePhotoTile(
                        state: state,
                        face: pair.face,
                        item: pair.item,
                        allPeople: allPeople,
                        selectMode: selectMode,
                        selected: selection.contains(pair.id),
                        space: space,
                        thumbPixels: thumbPixels,
                        showFace: showFaces,
                        onTap: { tap(pair) },
                        onReassign: { target in
                            guard let id = pair.face.id else { return }
                            state.reassignFace(id, to: target?.id, fromPerson: person.id)
                            reload()
                        },
                        onUseAsThumbnail: {
                            if let id = pair.face.id {
                                state.setPersonCover(personID: person.id, faceID: id)
                            }
                        }
                    )
                }
            }
            .padding(Theme.gridGap)
        }
        .coordinateSpace(name: space)
        .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                     space: space, enabled: selectMode))
    }

    private func tap(_ pair: FacePhoto) {
        if selectMode {
            if let idx = orderedSelectable.firstIndex(where: { $0.id == pair.id }) {
                selection.tap(index: idx, items: orderedSelectable,
                              extendingRange: NSEvent.modifierFlags.contains(.shift))
            }
        } else {
            state.openViewer(pair.item, within: photos)
        }
    }

    // MARK: Toolbars

    private var detailToolbar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("People")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Divider().frame(height: 16)
            if renaming {
                TextField("Name", text: $renameField)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 200)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = false }
            } else {
                Text(person.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .onTapGesture(count: 2) { beginRename() }
                    .help("Double-click to rename")
                Button { beginRename() } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Rename")
            }
            Text("\(pairs.count) \(pairs.count == 1 ? "photo" : "photos")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            if !pairs.isEmpty {
                Picker("", selection: $showFaces) {
                    Text("Faces").tag(true)
                    Text("Photos").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Select") { selectMode = true }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private func beginRename() { renameField = person.name; renaming = true }
    private func commitRename() {
        let n = renameField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, n != person.name { state.renamePerson(person.id, to: n) }
        renaming = false
    }

    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            moveControls: AnyView(personActions),
            sendTargetName: {
                let t = state.connectedSendTargets()
                return t.count > 1 ? "device\u{2026}" : t.first?.name
            }(),
            onSend: {
                let t = state.connectedSendTargets()
                if t.count <= 1 { showSend = true } else { sendChooser = true }
            },
            onDelete: { if !evictableItems.isEmpty { showDelete = true } },
            onEvict: { if !evictableItems.isEmpty { showEvict = true } },
            onForceEvict: { if !evictableItems.isEmpty { showForceEvict = true } },
            showRehydrate: !rehydratableItems.isEmpty,
            onRehydrate: { let items = rehydratableItems
                           Task { _ = await state.rehydrate(items); endSelect() } },
            tagControls: AnyView(TagPersonMenu(
                state: state, hashes: selectedItems.map(\.hash), onDone: { endSelect() })),
            albumControls: AnyView(AddToAlbumMenu(
                state: state, hashes: selectedItems.map(\.hash), onDone: { endSelect() })),
            shareControls: AnyView(
                ShareLink(items: state.localFileURLs(for: selectedItems)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }.controlSize(.small)),
            onDeselect: { selection.clear() },
            onDone: { endSelect() })
    }

    /// People-specific face actions, injected into the shared bar's leading slot beside the photo
    /// actions. These keep the selection (so you can manage several in a row); photo actions exit.
    @ViewBuilder private var personActions: some View {
        HStack(spacing: 6) {
            Menu("Move to person\u{2026}") {
                let others = allPeople.filter { $0.id != person.id }
                if others.isEmpty { Text("No other people yet") }
                else {
                    ForEach(others, id: \.id) { p in
                        Button(p.name) {
                            state.moveFaces(selectedFaceIDs, toPerson: p.id, fromPerson: person.id)
                            afterFaceAction()
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small).disabled(selection.count == 0)
            Button("Split\u{2026}") { showSplitField = true }.controlSize(.small).disabled(selection.count == 0)
            Button("Remove") {
                for id in selectedFaceIDs { state.reassignFace(id, to: nil, fromPerson: person.id) }
                afterFaceAction()
            }
            .controlSize(.small).disabled(selection.count == 0)
            .help("Remove the selected faces from \(person.name)")
        }
    }

    private var emptyFaces: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "face.smiling")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text("No photos")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        let faces = (try? state.library?.catalog.faces(forPerson: person.id)) ?? []
        pairs = state.facePhotos(for: faces)
        allPeople = (try? state.library?.catalog.people()) ?? []
        // Drop selection entries whose face no longer belongs to this person.
        if pairs.isEmpty { selection.clear() }
    }
}

// MARK: - Cluster detail view (drill into an unnamed group to name it)

struct ClusterDetailView: View {
    @Bindable var state: AppState
    let cluster: FaceCluster
    var onBack: () -> Void

    @State private var pairs: [FacePhoto] = []
    @State private var allPeople: [PersonRow] = []
    @State private var nameField = ""
    @State private var showFaces = true
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var splitName = ""
    @State private var showSplitField = false
    @State private var showDelete = false

    private let gridColumns = [GridItem(.adaptive(minimum: 108), spacing: Theme.gridGap)]
    private let space = "clustergrid"
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: 120) }
    private var photos: [TimelineItem] { pairs.map(\.item) }
    private var orderedSelectable: [SelectableItem] { pairs.map { SelectableItem(id: $0.id) } }
    private var selectedFaceIDs: [Int64] { Array(selection.selected).compactMap(Int64.init) }
    private var deletableItems: [TimelineItem] {
        pairs.filter { selection.contains($0.id) }.map(\.item).filter { $0.driveRelPath == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            if pairs.isEmpty { empty } else { grid }
        }
        .onAppear { reload() }
        .alert("Delete \(deletableItems.count) photo\(deletableItems.count == 1 ? "" : "s")?",
               isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let items = deletableItems; let ids = selectedFaceIDs
                Task { await state.deletePhotos(items) }
                afterAction(ids)
            }
        } message: {
            Text("They move to the Bin (restore anytime). This deletes the whole photo, not just the face.")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: Theme.gridGap) {
                ForEach(pairs) { pair in
                    FacePhotoTile(
                        state: state, face: pair.face, item: pair.item, allPeople: [],
                        selectMode: selectMode, selected: selection.contains(pair.id),
                        space: space, thumbPixels: thumbPixels, showFace: showFaces,
                        onTap: { tap(pair) }, onReassign: nil)
                }
            }
            .padding(Theme.gridGap)
        }
        .coordinateSpace(name: space)
        .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                     space: space, enabled: selectMode))
    }

    private func tap(_ pair: FacePhoto) {
        if selectMode {
            if let idx = orderedSelectable.firstIndex(where: { $0.id == pair.id }) {
                selection.tap(index: idx, items: orderedSelectable,
                              extendingRange: NSEvent.modifierFlags.contains(.shift))
            }
        } else {
            state.openViewer(pair.item, within: photos)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("People").font(.system(size: 13))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Divider().frame(height: 16)
            Text("Unnamed group")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("\(pairs.count) \(pairs.count == 1 ? "photo" : "photos")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Picker("", selection: $showFaces) {
                Text("Faces").tag(true)
                Text("Photos").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if !pairs.isEmpty { Button("Select") { selectMode = true }.controlSize(.small) }
            TextField("Name this person…", text: $nameField)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 150)
                .onSubmit(name)
            Button("Name", action: name)
                .controlSize(.small)
                .disabled(nameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    /// Selection mode: move the chosen photos to an existing person, split them into a new person,
    /// or delete them — the same moves a named group offers.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            Button("Deselect") { selection.clear() }.controlSize(.small).disabled(selection.count == 0)
            Button("Delete") { if !deletableItems.isEmpty { showDelete = true } }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.red)
                .disabled(deletableItems.isEmpty)
            Menu("Add to person\u{2026}") {
                if allPeople.isEmpty { Text("No people yet") }
                else {
                    ForEach(allPeople, id: \.id) { p in
                        Button(p.name) {
                            let ids = selectedFaceIDs
                            state.moveFaces(ids, toPerson: p.id, fromPerson: nil)
                            afterAction(ids)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .disabled(allPeople.isEmpty || selection.count == 0)
            if showSplitField {
                TextField("New person name\u{2026}", text: $splitName)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 150)
                    .onSubmit(commitSplit)
                Button("Create", action: commitSplit).controlSize(.small)
            } else {
                Button("New person\u{2026}") { showSplitField = true; splitName = "" }
                    .controlSize(.small).disabled(selection.count == 0)
            }
            Button("Done") { selection.clear(); selectMode = false; showSplitField = false }.controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text("No photos").font(.system(size: 14)).foregroundStyle(Theme.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func name() {
        let n = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        state.nameCluster(cluster.faceIDs, as: n)
        nameField = ""
        onBack()   // the group becomes a named person; return to the overview.
    }

    private func commitSplit() {
        let n = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !selectedFaceIDs.isEmpty else { showSplitField = false; return }
        let ids = selectedFaceIDs
        state.nameCluster(ids, as: n)     // a subset becomes its own new named person
        splitName = ""; showSplitField = false
        afterAction(ids)
    }

    /// Optimistically drop handled faces from this view; pop back if the group is now empty.
    private func afterAction(_ faceIDs: [Int64]) {
        let drop = Set(faceIDs)
        pairs.removeAll { drop.contains($0.face.id ?? -1) }
        selection.clear()
        if pairs.isEmpty { onBack() }
    }

    private func reload() {
        let faces: [FaceRow] = cluster.faceIDs.compactMap { id in
            (try? state.library?.catalog.face(forID: id)) ?? nil
        }
        pairs = state.facePhotos(for: faces)
        allPeople = (try? state.library?.catalog.people()) ?? []
    }
}

// MARK: - One photo tile in a person/cluster grid (full photo, opens the viewer on tap)

struct FacePhotoTile: View {
    @Bindable var state: AppState
    let face: FaceRow
    let item: TimelineItem
    let allPeople: [PersonRow]
    var selectMode: Bool
    var selected: Bool
    var space: String
    var thumbPixels: Int
    /// true → show the cropped face the cluster claims; false → the whole photo.
    var showFace: Bool = false
    var onTap: () -> Void
    /// nil → no per-face management menu (cluster grid). non-nil(person) reassigns, non-nil(nil) unassigns.
    var onReassign: ((PersonRow?) -> Void)?
    var onUseAsThumbnail: (() -> Void)?

    private var tileID: String { face.id.map(String.init) ?? face.hash }

    @ViewBuilder private var tileImage: some View {
        if showFace {
            FaceCropView(state: state, faceID: face.id, hash: face.hash,
                         rect: face.rect, size: 120, fill: true)
        } else {
            ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: thumbPixels)
        }
    }

    var body: some View {
        MediaTile(
            id: tileID,
            selectMode: selectMode,
            selected: selected,
            rubberBandSpace: space,
            thumbnail: tileImage,
            badges: { confidenceBadge },
            onTap: onTap
        )
        .modifier(FaceTileMenu(face: face, allPeople: allPeople,
                               onReassign: onReassign, onUseAsThumbnail: onUseAsThumbnail))
    }

    // Face *quality* (capture clarity/frontality), 0–100%. Replaces the old detection-confidence
    // badge, which the v2 landmark detector reports as ~100% for every accepted face (uninformative).
    // Hidden for gated (quality 0) and manual (no-face) tags, where a "0%" badge would be meaningless.
    @ViewBuilder private var confidenceBadge: some View {
        if face.quality > 0 {
            Text("\(Int(face.quality * 100))%")
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

/// Adds the per-face management context menu only in the person grid (onReassign set).
private struct FaceTileMenu: ViewModifier {
    let face: FaceRow
    let allPeople: [PersonRow]
    let onReassign: ((PersonRow?) -> Void)?
    let onUseAsThumbnail: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let onReassign {
            content.contextMenu {
                if let onUseAsThumbnail {
                    Button { onUseAsThumbnail() } label: {
                        Label("Use as Thumbnail", systemImage: "person.crop.circle")
                    }
                    Divider()
                }
                if !allPeople.isEmpty {
                    Menu("Move to person…") {
                        ForEach(allPeople.filter { $0.id != face.personID }, id: \.id) { p in
                            Button(p.name) { onReassign(p) }
                        }
                    }
                }
                Button(role: .destructive) { onReassign(nil) } label: {
                    Label("Remove from person", systemImage: "person.badge.minus")
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Face crop view

/// Shows a cropped face from the thumbnail cache. Approach: loads the full asset thumbnail
/// (from ThumbnailStore via ThumbnailImage), then crops the Vision-frame rect in a GeometryReader
/// offset. If the crop geometry can't be resolved (no rect / no thumbnail), shows the full
/// thumbnail with a rect outline.
///
/// Implementation note: we use the thumbnail store to load the full 512px thumbnail, then clip
/// the inner CGImage to the Vision bounding-box rect. The face rect is Vision-frame (bottom-left
/// origin). In display space (top-left origin, y flipped), the crop box is:
///   displayY = 1 - rect.maxY   (flip the bottom-left y to top-left)
///   pixelX = displayX * width, pixelY = displayY * height
struct FaceCropView: View {
    @Bindable var state: AppState
    /// Stable cache key: face id when available, else hash.
    let faceID: Int64?
    /// The asset hash; if nil we load by faceID from the catalog.
    let hash: String?
    /// Vision normalized bounding-box rect (bottom-left origin). If nil, shows the whole thumbnail.
    var rect: CGRect = .zero
    let size: CGFloat
    /// When true, fill the container instead of a fixed `size`×`size` box (for use inside a grid
    /// tile whose parent already constrains the frame). `size` still drives the cache key + crop.
    var fill: Bool = false
    /// When false, show the whole photo instead of the cropped face — lets a Faces/Photos toggle
    /// flip the view without changing layout.
    var cropToFace: Bool = true

    @State private var croppedImage: CGImage?
    @State private var rotation = 0   // the asset's display rotation, applied so the crop matches the photo

    private var cacheID: String {
        let m = cropToFace ? "" : "-full"   // distinct key so toggling face/photo re-resolves
        if let faceID { return "face-\(faceID)@\(Int(size))\(m)" }
        if let hash { return "face-hash-\(hash)@\(Int(size))\(m)" }
        return "face-unknown@\(Int(size))\(m)"
    }

    var body: some View {
        ZStack {
            Theme.tile
            if let img = croppedImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .rotationEffect(.degrees(Double(rotation)))   // match the photo's display rotation
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .modifier(FaceCropFrame(size: size, fill: fill))
        .task(id: cacheID) { await loadCrop() }
    }

    @MainActor
    private func loadCrop() async {
        guard let lib = state.library else { return }
        // Resolve hash + rect from the face row if not provided.
        let (resolvedHash, resolvedRect): (String?, CGRect)
        if let hash {
            resolvedHash = hash
            resolvedRect = rect
        } else if let faceID {
            // Resolve faceID → FaceRow (hash + rect) via Catalog.face(forID:).
            let faceRow = try? lib.catalog.face(forID: faceID)
            resolvedHash = faceRow?.hash
            resolvedRect = faceRow?.rect ?? .zero
        } else {
            resolvedHash = nil
            resolvedRect = .zero
        }

        guard let assetHash = resolvedHash, !assetHash.isEmpty else { return }
        rotation = (try? lib.catalog.rotation(forHash: assetHash)) ?? 0

        // Load the thumbnail from cache or source.
        let contentHash = ContentHash(stringValue: assetHash)
        let thumbPixel = ThumbnailStore.maxPixel

        let thumbnail: CGImage? = await Task.detached(priority: .userInitiated) {
            // Try cached first (no I/O).
            if let cached = await lib.thumbnails.cachedDisplayImage(
                for: contentHash, maxPixel: thumbPixel) {
                return cached
            }
            // Try to generate from the source file.
            let instances = try? lib.catalog.instances(forHash: assetHash)
            for inst in instances ?? [] {
                guard let vault = lib.vault(id: inst.vaultID) else { continue }
                let url = vault.absoluteURL(forRelativePath: inst.relPath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let kind = MediaKind.photo
                if let img = try? await lib.thumbnails.displayImage(
                    for: contentHash, sourceURL: url, kind: kind, maxPixel: thumbPixel) {
                    return img
                }
            }
            return nil
        }.value

        guard let thumb = thumbnail else { return }

        if !cropToFace { croppedImage = thumb; return }   // Photos mode: show the whole photo

        // Crop the Vision rect out of the thumbnail.
        // Vision rect: bottom-left origin. Convert to display (top-left) pixel coords.
        let tw = CGFloat(thumb.width)
        let th = CGFloat(thumb.height)
        let cropRect: CGRect
        if resolvedRect == .zero || (resolvedRect.width == 0 && resolvedRect.height == 0) {
            // No rect: show the whole thumbnail.
            croppedImage = thumb
            return
        }
        // Flip y: Vision y is from the bottom; CGImage y is from the top.
        let displayMinY = 1.0 - resolvedRect.maxY
        cropRect = CGRect(
            x: resolvedRect.minX * tw,
            y: displayMinY * th,
            width: resolvedRect.width * tw,
            height: resolvedRect.height * th
        ).intersection(CGRect(x: 0, y: 0, width: tw, height: th))

        if let cropped = cropRect.isEmpty ? nil : thumb.cropping(to: cropRect) {
            croppedImage = cropped
        } else {
            croppedImage = thumb
        }
    }
}

/// Fixed `size`×`size` by default; fills its container when `fill` (so a grid tile can size it).
private struct FaceCropFrame: ViewModifier {
    let size: CGFloat
    let fill: Bool
    func body(content: Content) -> some View {
        if fill { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
        else { content.frame(width: size, height: size) }
    }
}
