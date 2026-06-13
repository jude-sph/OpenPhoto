import SwiftUI
import OpenPhotoCore

/// "Tidy Up" — review redundant photos in groups (camera bursts, or perceptual-hash duplicates),
/// keep the suggested best frame, and recoverably bin the rest. One shared SelectionModel spans
/// every group's tiles, keyed by `instanceID` (a hash can recur across duplicate groups, so a
/// hash-keyed selection would wrongly couple identical photos in different folders). Each group is
/// a row: the suggested keeper is ringed and never pre-selected; every other tile starts selected
/// for deletion iff its hash is in that group's `suggestedEvict`.
struct CleanupView: View {
    @Bindable var state: AppState
    @State private var selection = SelectionModel()
    @State private var showDelete = false
    @State private var showApplyAll = false

    private let space = "tidygrid"
    private let cellMin: CGFloat = 120
    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: cellMin) }

    /// Every tile across every group, in display order — the universe the shared selection ranges over.
    private var allItems: [TimelineItem] { state.cullGroups.flatMap(\.items) }
    private var orderedSelectable: [SelectableItem] {
        allItems.map { SelectableItem(id: $0.instanceID) }
    }
    private var selectedItems: [TimelineItem] {
        allItems.filter { selection.contains($0.instanceID) }
    }
    /// Every tile any group suggests evicting (the union the "Apply all suggestions" action acts on).
    private var allSuggested: [TimelineItem] {
        state.cullGroups.flatMap { g in g.items.filter { g.suggestedEvict.contains($0.hash) } }
    }
    /// Changes whenever the group set is (re)loaded, so the shared selection can be re-seeded.
    private var groupsSignature: [String] {
        state.cullGroups.map { $0.keep + "#\($0.items.count)" }
    }

    /// Pre-select every group's suggested rejects (keyed by instanceID — keepers stay unselected).
    private func seedSelection() {
        var sel = SelectionModel()
        for group in state.cullGroups {
            for item in group.items where group.suggestedEvict.contains(item.hash) {
                sel.add(SelectableItem(id: item.instanceID))
            }
        }
        selection = sel
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            content
            if selection.count > 0 {
                Divider().overlay(Theme.hairline)
                actionBar
            }
        }
        .onAppear { state.loadCullGroups() }
        .onChange(of: groupsSignature) { seedSelection() }
        .alert("Delete \(selection.count) photo\(selection.count == 1 ? "" : "s")?",
               isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await deleteSelected() } }
        } message: {
            Text(deleteMessage)
        }
        .alert("Apply all suggestions?", isPresented: $showApplyAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(allSuggested.count)", role: .destructive) {
                Task { await applyAllSuggestions() }
            }
        } message: {
            Text("Deletes the suggested rejects in every group (\(allSuggested.count) photo\(allSuggested.count == 1 ? "" : "s")), keeping each group's best frame. They move to the bin — restore anytime.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Tidy Up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Picker("Mode", selection: $state.cullMode) {
                Text("Bursts").tag(CullMode.bursts)
                Text("Duplicates").tag(CullMode.duplicates)
                Text("Similar").tag(CullMode.similar)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: state.cullMode) { selection.clear(); state.loadCullGroups() }
            if !state.cullGroups.isEmpty {
                Text("\(state.cullGroups.count) group\(state.cullGroups.count == 1 ? "" : "s")")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            if state.cullLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if !state.cullLoading && state.cullGroups.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(state.cullGroups) { group in
                        groupRow(group)
                    }
                }
                .padding(16)
            }
            .coordinateSpace(name: space)
            .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                         space: space, enabled: true))
        }
    }

    private func groupRow(_ group: AppState.CullGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(group.items.count) \(state.cullMode == .duplicates ? "duplicates" : "similar") · keeping the \(state.cullMode == .bursts ? "sharpest" : "highest-res")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.gridGap) {
                    ForEach(group.items, id: \.instanceID) { item in
                        tile(item, isKeeper: item.hash == group.keep)
                            .frame(width: cellMin, height: cellMin)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func tile(_ item: TimelineItem, isKeeper: Bool) -> some View {
        MediaTile(
            id: item.instanceID,
            selectMode: true,
            selected: selection.contains(item.instanceID),
            rubberBandSpace: space,
            thumbnail: ThumbnailImage(timelineItem: item, library: state.library!,
                                      targetPixel: thumbPixels),
            badges: { keeperBadge(isKeeper) },
            onTap: { tap(item) }
        )
    }

    @ViewBuilder private func keeperBadge(_ isKeeper: Bool) -> some View {
        if isKeeper {
            RoundedRectangle(cornerRadius: Theme.cellRadius)
                .strokeBorder(Theme.green, lineWidth: 3)
            Text("Keep")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.green, in: Capsule())
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func tap(_ item: TimelineItem) {
        guard let idx = orderedSelectable.firstIndex(where: { $0.id == item.instanceID }) else { return }
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
            Button("Deselect") { selection.clear() }
                .controlSize(.small)
            if !allSuggested.isEmpty {
                Button("Apply all suggestions") { showApplyAll = true }
                    .controlSize(.small)
                    .help("Delete every group's suggested rejects, keeping each best frame.")
            }
            Button(role: .destructive) { showDelete = true } label: {
                Label("Delete \(selection.count)", systemImage: "trash")
            }
            .controlSize(.small)
            .help("Move the selected photos to the bin — restore anytime.")
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    private var deleteMessage: String {
        "They move to the bin (restore anytime). On connected drives, their copies are then queued for removal — review under the drive before anything is deleted there."
    }

    // MARK: Actions

    private func deleteSelected() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        await state.delete(items)
        selection.clear()
        state.loadCullGroups()
    }

    private func applyAllSuggestions() async {
        let items = allSuggested
        guard !items.isEmpty else { return }
        await state.delete(items)
        selection.clear()
        state.loadCullGroups()
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to tidy up", systemImage: "sparkles")
        } description: {
            Text("No \(state.cullMode == .bursts ? "bursts" : "duplicates") found.\nAnalysis may still be running — bursts need photo embeddings, duplicates need the perceptual-hash backfill.")
        }
        .frame(maxHeight: .infinity)
    }
}
