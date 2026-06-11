import SwiftUI
import CoreGraphics
import OpenPhotoCore

// MARK: - Top-level People view

struct PeopleView: View {
    @Bindable var state: AppState
    /// nil = overview; non-nil = detail for a named person
    @State private var selectedPerson: PersonRow?

    var body: some View {
        if let person = selectedPerson {
            PersonDetailView(state: state, person: person,
                             onBack: { selectedPerson = nil })
        } else {
            PeopleOverviewView(state: state,
                               onSelectPerson: { selectedPerson = $0 })
        }
    }
}

// MARK: - Overview: named cards + suggested clusters

struct PeopleOverviewView: View {
    @Bindable var state: AppState
    var onSelectPerson: (PersonRow) -> Void

    // Merge-selection state (select two named people to merge).
    @State private var mergeSelection: Set<Int64> = []
    @State private var showMergeAlert = false

    private let cardSize: CGFloat = 120
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            if state.facesLoading {
                Spacer()
                ProgressView("Analyzing faces…").foregroundStyle(Theme.textDim)
                Spacer()
            } else if state.people.isEmpty && state.suggestedClusters.isEmpty {
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
                    }
                    .padding(16)
                }
            }
        }
        .onAppear {
            if state.people.isEmpty && state.suggestedClusters.isEmpty {
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
            if !mergeSelection.isEmpty {
                Button("Cancel") { mergeSelection = [] }
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
                Button("Select to merge…") { mergeSelection = [] }
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
                        inMergeMode: !mergeSelection.isEmpty,
                        mergeSelected: mergeSelection.contains(person.id),
                        onTap: {
                            if !mergeSelection.isEmpty {
                                if mergeSelection.contains(person.id) {
                                    mergeSelection.remove(person.id)
                                } else if mergeSelection.count < 2 {
                                    mergeSelection.insert(person.id)
                                }
                            } else {
                                onSelectPerson(person)
                            }
                        },
                        onRemove: { state.removePerson(person.id) }
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
            Text("Name a group to add it to People.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .padding(.bottom, 2)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(state.suggestedClusters) { cluster in
                    ClusterCard(state: state, cluster: cluster)
                }
            }
        }
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
                mergeSelection = []
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
            Button(role: .destructive) { onRemove() } label: {
                Label("Remove person", systemImage: "person.badge.minus")
            }
        }
    }
}

// MARK: - Suggested cluster card

struct ClusterCard: View {
    @Bindable var state: AppState
    let cluster: FaceCluster
    @State private var nameField = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                FaceCropView(
                    state: state,
                    faceID: cluster.representativeFaceID,
                    hash: nil,
                    size: 90
                )
                .frame(width: 90, height: 90)
                .clipShape(Circle())
                // Show count badge if > 1 face
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
            TextField("Name…", text: $nameField)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)
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

// MARK: - Person detail view (faces/photos grid)

struct PersonDetailView: View {
    @Bindable var state: AppState
    let person: PersonRow
    var onBack: () -> Void

    @State private var faces: [FaceRow] = []
    @State private var selectedFaces: Set<Int64> = []
    @State private var allPeople: [PersonRow] = []
    @State private var splitName = ""
    @State private var showSplitField = false

    private let gridColumns = [GridItem(.adaptive(minimum: 88), spacing: Theme.gridGap)]

    var body: some View {
        VStack(spacing: 0) {
            detailToolbar
            Divider().overlay(Theme.hairline)
            if !selectedFaces.isEmpty {
                selectionBar
                Divider().overlay(Theme.hairline)
            }
            if faces.isEmpty {
                emptyFaces
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: Theme.gridGap) {
                        ForEach(faces, id: \.id) { face in
                            FaceCell(
                                state: state,
                                face: face,
                                allPeople: allPeople,
                                selected: face.id.map { selectedFaces.contains($0) } ?? false,
                                onToggleSelect: {
                                    guard let id = face.id else { return }
                                    if selectedFaces.contains(id) {
                                        selectedFaces.remove(id)
                                    } else {
                                        selectedFaces.insert(id)
                                    }
                                },
                                onReassign: { targetPerson in
                                    guard let id = face.id else { return }
                                    state.reassignFace(id, to: targetPerson?.id,
                                                       fromPerson: person.id)
                                    reloadFaces()
                                },
                                onUnassign: {
                                    guard let id = face.id else { return }
                                    state.reassignFace(id, to: nil, fromPerson: person.id)
                                    reloadFaces()
                                }
                            )
                        }
                    }
                    .padding(Theme.gridGap)
                }
            }
        }
        .onAppear { reloadFaces(); loadAllPeople() }
    }

    // MARK: Detail toolbar

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
            Text(person.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("\(faces.count) \(faces.count == 1 ? "face" : "faces")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            if !selectedFaces.isEmpty {
                Text("\(selectedFaces.count) selected")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    // MARK: Selection action bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button("Clear") { selectedFaces = [] }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Remove from person") {
                for id in selectedFaces {
                    state.reassignFace(id, to: nil, fromPerson: person.id)
                }
                selectedFaces = []
                reloadFaces()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.accent)

            if showSplitField {
                TextField("New person name…", text: $splitName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 160)
                    .onSubmit {
                        let name = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { showSplitField = false; return }
                        state.splitFaces(Array(selectedFaces), fromPerson: person.id,
                                         toNewPerson: name)
                        selectedFaces = []; splitName = ""; showSplitField = false
                        reloadFaces()
                    }
                Button("Cancel") { showSplitField = false; splitName = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            } else {
                Button("Split to new person…") { showSplitField = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.bg2)
    }

    private var emptyFaces: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "face.smiling")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text("No faces")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reloadFaces() {
        faces = (try? state.library?.catalog.faces(forPerson: person.id)) ?? []
    }

    private func loadAllPeople() {
        allPeople = (try? state.library?.catalog.people()) ?? []
    }
}

// MARK: - Individual face cell (in person detail)

struct FaceCell: View {
    @Bindable var state: AppState
    let face: FaceRow
    let allPeople: [PersonRow]
    var selected: Bool
    var onToggleSelect: () -> Void
    var onReassign: (PersonRow?) -> Void
    var onUnassign: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FaceCropView(
                state: state,
                faceID: face.id,
                hash: face.hash,
                rect: face.rect,
                size: 88
            )
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.cellRadius)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                }
            }
            // Confidence label (bottom-left overlay)
            Text("\(Int(face.confidence * 100))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelect() }
        .contextMenu {
            Button {
                onToggleSelect()
            } label: {
                Label(selected ? "Deselect" : "Select", systemImage: selected ? "checkmark.circle" : "circle")
            }
            Divider()
            // Move to another person
            if !allPeople.isEmpty {
                Menu("Move to person…") {
                    ForEach(allPeople.filter { $0.id != face.personID }, id: \.id) { p in
                        Button(p.name) { onReassign(p) }
                    }
                }
            }
            Button(role: .destructive) { onUnassign() } label: {
                Label("Remove from person", systemImage: "person.badge.minus")
            }
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

    @State private var croppedImage: CGImage?

    private var cacheID: String {
        if let faceID { return "face-\(faceID)@\(Int(size))" }
        if let hash { return "face-hash-\(hash)@\(Int(size))" }
        return "face-unknown@\(Int(size))"
    }

    var body: some View {
        ZStack {
            Theme.tile
            if let img = croppedImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .frame(width: size, height: size)
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
        } else if faceID != nil {
            // faceID is present but hash is nil — we need Catalog.face(forID:) to resolve.
            // TODO(4.3): add Catalog.face(forID:) for direct faceID→hash lookup so representative
            // faces on PersonCards can be cropped without passing hash separately.
            resolvedHash = nil
            resolvedRect = .zero
        } else {
            resolvedHash = nil
            resolvedRect = .zero
        }

        guard let assetHash = resolvedHash, !assetHash.isEmpty else { return }

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
