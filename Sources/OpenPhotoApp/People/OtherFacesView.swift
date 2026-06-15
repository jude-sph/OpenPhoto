import SwiftUI
import OpenPhotoCore

/// The "Other faces" bucket — every unassigned face that matched no person and formed no cluster
/// (the DBSCAN noise that was previously invisible). Always in selection mode: pick faces and assign
/// them to an existing person or a new one, so no detected face is unreachable.
struct OtherFacesDetailView: View {
    @Bindable var state: AppState
    var onBack: () -> Void

    @State private var pairs: [FacePhoto] = []
    @State private var selection = SelectionModel()
    @State private var showFaces = true
    @State private var newName = ""
    @State private var showNewField = false
    @State private var loading = false
    @State private var showingHidden = false
    @State private var showDelete = false

    /// Cap how many faces we resolve+render at once so a huge bucket stays responsive.
    private let displayCap = 500
    private let gridColumns = [GridItem(.adaptive(minimum: 108), spacing: Theme.gridGap)]
    private let space = "otherfaces"
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: 120) }
    private var photos: [TimelineItem] { pairs.map(\.item) }
    private var orderedSelectable: [SelectableItem] { pairs.map { SelectableItem(id: $0.id) } }
    private var selectedFaceIDs: [Int64] { Array(selection.selected).compactMap(Int64.init) }
    /// Local photos for the selected faces (drive-only assets can't be evicted).
    private var deletableItems: [TimelineItem] {
        pairs.filter { selection.contains($0.id) }.map(\.item).filter { $0.driveRelPath == nil }
    }
    private var sourceIDs: [Int64] { showingHidden ? state.hiddenFaceIDs : state.otherFaceIDs }
    private var truncated: Bool { sourceIDs.count > displayCap }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            if pairs.isEmpty {
                if loading { loadingState } else { empty }
            } else {
                grid
                if selection.count > 0 {
                    Divider().overlay(Theme.hairline)
                    actionBar
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: state.otherFaceIDs) { reload() }
        .onChange(of: state.hiddenFaceIDs) { reload() }
        .alert("Delete \(deletableItems.count) photo\(deletableItems.count == 1 ? "" : "s")?",
               isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let items = deletableItems
                Task { await state.deletePhotos(items); selection.clear() }
            }
        } message: {
            Text("They move to the Bin (restore anytime). This deletes the whole photo, not just the face — use Hide to remove only the face from this list.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("People").font(.system(size: 13))
                }.foregroundStyle(Theme.accent)
            }.buttonStyle(.plain)
            Divider().frame(height: 16)
            Text(showingHidden ? "Hidden faces" : "Other faces")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(truncated ? "showing \(pairs.count) of \(sourceIDs.count)" : "\(sourceIDs.count)")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            if !showingHidden && !state.otherFaceIDs.isEmpty {
                Button("Shuffle") { state.otherFaceIDs.shuffle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Button(showingHidden ? "Show unsorted" : "Show hidden") {
                if showingHidden {
                    showingHidden = false
                    selection.clear()
                    reload()
                } else {
                    state.loadHiddenFaces()
                    showingHidden = true
                    selection.clear()
                    reload()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textDim)
            if !pairs.isEmpty {
                Divider().frame(height: 16)
                Picker("", selection: $showFaces) {
                    Text("Faces").tag(true); Text("Photos").tag(false)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Button(selection.count == pairs.count ? "Deselect all" : "Select all") {
                    if selection.count == pairs.count { selection.clear() }
                    else { for s in orderedSelectable { selection.add(s) } }
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: Theme.gridGap) {
                ForEach(pairs) { pair in
                    FacePhotoTile(
                        state: state, face: pair.face, item: pair.item, allPeople: [],
                        selectMode: true, selected: selection.contains(pair.id),
                        space: space, thumbPixels: thumbPixels, showFace: showFaces,
                        onTap: { tap(pair) }, onReassign: nil)
                }
            }
            .padding(Theme.gridGap)
        }
        .coordinateSpace(name: space)
        .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                     space: space, enabled: true))
    }

    private func tap(_ pair: FacePhoto) {
        guard let idx = orderedSelectable.firstIndex(where: { $0.id == pair.id }) else { return }
        selection.tap(index: idx, items: orderedSelectable,
                      extendingRange: NSEvent.modifierFlags.contains(.shift))
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Deselect") { selection.clear() }.controlSize(.small)
            Button("Delete") { if !deletableItems.isEmpty { showDelete = true } }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.red)
                .disabled(deletableItems.isEmpty)
                .help("Move the selected photos to the Bin")
            if showingHidden {
                Button("Restore") {
                    state.unhideFaces(selectedFaceIDs)
                    selection.clear()
                }.controlSize(.small)
            } else {
                Button("Hide") {
                    state.hideFaces(selectedFaceIDs)
                    selection.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                Menu("Add to person\u{2026}") {
                    if state.people.isEmpty { Text("No people yet") }
                    else {
                        ForEach(state.people, id: \.id) { p in
                            Button(p.name) {
                                state.moveFaces(selectedFaceIDs, toPerson: p.id, fromPerson: nil)
                                selection.clear()
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .disabled(state.people.isEmpty)
                if showNewField {
                    TextField("New person name\u{2026}", text: $newName)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                        .frame(width: 160)
                        .onSubmit { commitNew() }
                    Button("Create") { commitNew() }.controlSize(.small)
                } else {
                    Button("New Person\u{2026}") { showNewField = true; newName = "" }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    private func commitNew() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        state.nameCluster(selectedFaceIDs, as: n)
        selection.clear(); newName = ""; showNewField = false
    }

    // MARK: Empty / loading

    private var loadingState: some View {
        VStack { Spacer(); ProgressView().controlSize(.regular); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: showingHidden ? "eye.slash" : "checkmark.circle")
                .font(.system(size: 36)).foregroundStyle(Theme.textFaint)
            Text(showingHidden ? "No hidden faces" : "No other faces")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(showingHidden
                 ? "You haven't hidden any faces yet."
                 : "Every detected face is in a group or assigned to someone.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            Button("Back to People", action: onBack).controlSize(.small).padding(.top, 4)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    // MARK: Load (off-main — the bucket can be large)

    private func reload() {
        guard let lib = state.library else { pairs = []; return }
        let ids = Array(sourceIDs.prefix(displayCap))
        guard !ids.isEmpty else { pairs = []; return }
        loading = true
        Task {
            let resolved: [FacePhoto] = await Task.detached(priority: .userInitiated) {
                ids.compactMap { id -> FacePhoto? in
                    guard let face = (try? lib.catalog.face(forID: id)) ?? nil,
                          let item = (try? lib.item(hash: face.hash)) ?? nil else { return nil }
                    return FacePhoto(face: face, item: item)
                }
            }.value
            pairs = resolved
            loading = false
        }
    }
}
