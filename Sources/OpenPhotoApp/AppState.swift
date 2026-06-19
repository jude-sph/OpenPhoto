import SwiftUI
import OpenPhotoCore

typealias Scanner = OpenPhotoCore.Scanner   // Foundation.Scanner collision

enum SidebarItem: String, Hashable, CaseIterable {
    case timeline, folders, albums, people, map, search, drives, tidyUp, bin
    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .folders: "Folders"
        case .albums: "Albums"
        case .people: "People"
        case .map: "Map"
        case .search: "Search"
        case .drives: "Drives"
        case .tidyUp: "Tidy Up"
        case .bin: "Bin"
        }
    }
    var symbol: String {
        switch self {   // SF Symbol map from the UI-Design README
        case .timeline: "photo.on.rectangle.angled"
        case .folders: "folder"
        case .albums: "rectangle.stack"
        case .people: "person.2"
        case .map: "map"
        case .search: "magnifyingglass"
        case .drives: "externaldrive"
        case .tidyUp: "square.on.square"
        case .bin: "trash"
        }
    }
}

/// A suggested group of look-alike faces produced by FaceClusterer — not yet named as a Person.
/// Used by the People view to show unnamed clusters the user can confirm / name.
struct FaceCluster: Identifiable, Sendable {
    let faceIDs: [Int64]
    let representativeFaceID: Int64
    let count: Int
    var id: Int64 { representativeFaceID }
}

/// One face paired with the photo it appears in, for the person/cluster photo grids. `id` keys both
/// the grid (ForEach) and rubber-band selection, so it matches `FacePhotoTile`'s tile id.
struct FacePhoto: Identifiable, Sendable {
    let face: FaceRow
    let item: TimelineItem
    var id: String { face.id.map(String.init) ?? face.hash }
}

@Observable @MainActor
final class AppState {
    static let rootsDefaultsKey = "libraryRootPaths"

    var library: LibraryService?
    var selection: SidebarItem = .timeline
    var selectedFolder: String?              // dirPath in Folders view
    var openedItem: TimelineItem?            // non-nil → Viewer is presented
    var viewerItems: [TimelineItem] = []     // the set the viewer navigates (timeline or one folder)
    var inspectorShown = true
    /// True while a text field in the Inspector (caption / tag) is focused — the Viewer's key
    /// shortcuts (i, arrows, Delete) check this and yield, so typing doesn't navigate/delete/toggle.
    var isEditingText = false
    // One shared grid-size value across Timeline + Folders, persisted across launches.
    var gridMinSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "gridMinSize")
        return v >= 48 ? CGFloat(v) : 132
    }() {
        didSet { UserDefaults.standard.set(Double(gridMinSize), forKey: "gridMinSize") }
    }
    var sections: [TimelineSection] = []
    var flatItems: [TimelineItem] = []
    var folderTree: [FolderNode] = []
    var expandedFolders: Set<String> = []
    var binEntries: [LibraryService.BinEntry] = []
    var deviceWatcher = DeviceWatcher()
    var openedDevice: ConnectedDevice?      // non-nil → ImportView is shown
    /// Non-nil while a Quick View peek is open. Ephemeral — its tempDir is deleted on teardown.
    var peekContext: PeekContext?
    var scanProgress: Scanner.Progress?
    /// Background OCR/derivation progress (done, total) while the runner is active; nil when idle.
    var derivationProgress: (done: Int, total: Int)?
    /// Human-readable name of the analysis stage currently running ("faces", "text", …) — the
    /// sidebar shows it so the user knows what the on-device analysis is doing right now.
    var derivationStageName: String?
    var scanning = false
    /// Set when `rescan()` is asked to run while a scan is already in flight (e.g. a watcher event
    /// from the tail of a large Finder copy or import). The in-flight scan re-runs once it finishes,
    /// so the final filesystem state is always picked up — without this, a dropped trailing event
    /// leaves the folder counts stuck at whatever was present when the scan began.
    private var rescanRequested = false
    /// Held while a folder/photo reorg is mutating the manifest/catalog so a background scan can't
    /// run concurrently and revert it (S03). `beginReorg()`/`endReorg()` gate it; scans and reorgs
    /// take turns through `libraryMutationWaiters` (continuation-based, no busy-spin).
    private var reorganizing = false
    private var libraryMutationWaiters: [CheckedContinuation<Void, Never>] = []
    var refreshToken = 0
    /// Bumped after a per-photo move so the folder grid clears its (now-stale) selection.
    var photoMoveToken = 0
    /// Per-capability ML availability on this Mac, mirrored from `MLAvailability` (Core). Drives the
    /// loud unavailable banner + the People/Search unavailable states. Empty until the first model
    /// load is attempted.
    var mlStatus: [MLCapability: MLStatus] = [:]
    /// Capabilities that are present-but-broken on this machine (the loud cases only — never `.absent`).
    var mlUnavailable: [(capability: MLCapability, reason: String)] {
        MLCapability.allCases.compactMap { cap in
            if case .unavailable(let reason) = (mlStatus[cap] ?? .unknown) { return (cap, reason) }
            return nil
        }
    }
    /// The main window's native UndoManager (captured by RootView). ⌘Z registrations go here so
    /// focused text fields keep their own field-editor undo. See AppState+Undo.swift.
    weak var windowUndoManager: UndoManager?
    /// True while applyUndo replays an inverse op — suppresses re-recording (no redo by design).
    var isApplyingUndo = false
    var grouping: TimelineGrouping = {
        let raw = UserDefaults.standard.string(forKey: "timelineGrouping") ?? ""
        return TimelineGrouping(rawValue: raw) ?? .day
    }() {
        didSet {
            UserDefaults.standard.set(grouping.rawValue, forKey: "timelineGrouping")
        }
    }
    var videoOnly: Bool = UserDefaults.standard.bool(forKey: "videoOnly") {
        didSet {
            UserDefaults.standard.set(videoOnly, forKey: "videoOnly")
            try? refreshQueries()   // rebuild timeline + folder-tree counts so they match the filter
        }
    }

    // MARK: — Locked Folders (Touch ID)

    /// Touch-ID-locked folder dirPaths (source of truth; persisted via LockedFolderStore).
    var lockedFolders: [String] = []
    /// True once the user has passed Touch ID this session (locked folders then appear everywhere).
    var lockedRevealed = false

    // MARK: — Albums (manual virtual collections)

    /// Album summaries for the sidebar (rebuilt from the sovereign `.openphoto/albums/` files via the
    /// catalog mirror). Source of truth is the JSON files; see `AppState+Albums`.
    var albums: [AlbumSummary] = []
    /// The album currently open in the Albums detail view (its `id`/UUID), or nil for the empty state.
    var selectedAlbumID: String?
    /// Folder view: include photos from every descendant folder (the whole subtree), not just the
    /// selected folder.
    var foldersRecursive: Bool = UserDefaults.standard.bool(forKey: "foldersRecursive") {
        didSet { UserDefaults.standard.set(foldersRecursive, forKey: "foldersRecursive") }
    }

    // MARK: — Metadata interop

    var finderTagSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "finderTagSync") {
        didSet {
            UserDefaults.standard.set(finderTagSyncEnabled, forKey: "finderTagSync")
            if finderTagSyncEnabled { syncFinderTagsNow() }   // push existing tags + pull Finder edits
        }
    }

    /// Reconcile a save (tags + favourite) with Finder when sync is on, returning the merged values to
    /// persist. The reserved "Favourite" tag is always stripped from regular tags (it's driven by the
    /// favourite flag, never typed as a tag) — even when sync is off.
    func reconcileForSave(item: TimelineItem, tags: [String], favorite: Bool) -> (tags: [String], favorite: Bool) {
        let regular = tags.filter { $0.caseInsensitiveCompare(FinderTags.favoriteTagName) != .orderedSame }
        guard finderTagSyncEnabled, let lib = library else { return (tags: regular, favorite: favorite) }
        return (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: regular, favorite: favorite))
            ?? (tags: regular, favorite: favorite)
    }

    /// Apply `tag` to every photo in `dir` (and its subfolders when `recursive`) in one pass, reusing
    /// the per-photo write path (sidecar + catalog, and a Finder reconcile when sync is on). Photos
    /// that already carry the tag are skipped. Runs off-main; grids refresh when it finishes.
    func tagAllInFolder(_ dir: String, tag: String, recursive: Bool = true) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lib = library, !tag.isEmpty,
              tag.caseInsensitiveCompare(FinderTags.favoriteTagName) != .orderedSame else { return }
        let syncFinder = finderTagSyncEnabled
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = (try? lib.items(inDir: dir, recursive: recursive)) ?? []
            for item in items {
                let existing = (try? JSONDecoder().decode([String].self, from: Data(item.tagsJSON.utf8))) ?? []
                // Skip if the photo already has the tag — case-insensitively, so "Vacation" isn't
                // double-tagged by "vacation" (matches untagAllInFolder's case-insensitive match).
                guard !existing.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                var newTags = existing + [tag]
                var fav = item.favorite
                if syncFinder {
                    let r = (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: newTags,
                                                          favorite: item.favorite))
                        ?? (tags: newTags, favorite: item.favorite)
                    newTags = r.tags; fav = r.favorite
                }
                try? lib.updateMetadata(for: item, rating: item.rating, favorite: fav,
                                        caption: item.caption, tags: newTags)
            }
            await MainActor.run { [weak self] in
                try? self?.refreshQueries()
                self?.refreshToken &+= 1
            }
        }
    }

    /// Inverse of tagAllInFolder: remove `tag` from every photo in `dir` (and subfolders when
    /// recursive) that has it. Case-insensitive match. Reuses the per-photo write path (sidecar +
    /// catalog, and a Finder reconcile when sync is on). Runs off-main; grids refresh when done.
    func untagAllInFolder(_ dir: String, tag: String, recursive: Bool = true) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lib = library, !tag.isEmpty,
              tag.caseInsensitiveCompare(FinderTags.favoriteTagName) != .orderedSame else { return }
        let syncFinder = finderTagSyncEnabled
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = (try? lib.items(inDir: dir, recursive: recursive)) ?? []
            for item in items {
                let existing = (try? JSONDecoder().decode([String].self, from: Data(item.tagsJSON.utf8))) ?? []
                guard existing.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                var newTags = existing.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
                var fav = item.favorite
                if syncFinder {
                    let r = (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: newTags,
                                                          favorite: item.favorite))
                        ?? (tags: newTags, favorite: item.favorite)
                    newTags = r.tags; fav = r.favorite
                }
                try? lib.updateMetadata(for: item, rating: item.rating, favorite: fav,
                                        caption: item.caption, tags: newTags)
            }
            await MainActor.run { [weak self] in
                try? self?.refreshQueries()
                self?.refreshToken &+= 1
            }
        }
    }

    /// Full reconcile pass over every asset (off-main). Picks up Finder-side edits and pushes
    /// OpenPhoto tags to Finder; persists the merged set to the sidecar + catalog when it changed.
    /// No-op when the toggle is off.
    func syncFinderTagsNow() {
        guard finderTagSyncEnabled, let lib = library else { return }
        Task.detached(priority: .utility) {
            let items = (try? lib.catalog.timelineItems()) ?? []
            var seen = Set<String>()
            for item in items where seen.insert(item.hash).inserted {
                let current = (try? JSONDecoder().decode([String].self, from: Data(item.tagsJSON.utf8))) ?? []
                let r = (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: current,
                                                      favorite: item.favorite))
                    ?? (tags: current, favorite: item.favorite)
                if Set(r.tags) != Set(current) || r.favorite != item.favorite {
                    try? lib.updateMetadata(for: item, rating: item.rating, favorite: r.favorite,
                                            caption: item.caption, tags: r.tags)
                }
            }
            await MainActor.run { [weak self] in try? self?.refreshQueries() }
        }
    }

    /// Export human-metadata sidecars to a user-chosen folder (a portable XMP snapshot).
    func exportSidecars() {
        guard let lib = library else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported .xmp metadata sidecars."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            let n = await Task.detached(priority: .userInitiated) {
                (try? SidecarExporter.export(library: lib, to: dest)) ?? 0
            }.value
            let alert = NSAlert()
            alert.messageText = "Exported \(n) sidecar\(n == 1 ? "" : "s")"
            alert.informativeText = "Standard .xmp metadata files were written to the chosen folder."
            alert.runModal()
        }
    }

    // MARK: — Search state
    enum SearchMode: String { case simple, pro }
    var searchMode: SearchMode =
        SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "") ?? .simple {
        didSet { UserDefaults.standard.set(searchMode.rawValue, forKey: "searchMode") }
    }

    /// Count of currently-active filters that the Simple editor can't represent (≥2 of an OR/AND
    /// facet, any exclusion, has-text, or a people-presence constraint). Drives the
    /// "+N Pro filters active" hint shown in Simple mode.
    var proOnlyFilterCount: Int {
        let f = searchFilters
        return max(0, f.includePeople.count - 1) + f.excludePeople.count
            + max(0, f.includeFolders.count - 1) + f.excludeFolders.count
            + max(0, f.includePlaces.count - 1) + f.excludePlaces.count
            + max(0, f.includeCameras.count - 1) + f.excludeCameras.count
            + f.excludeTags.count
            + (f.hasText ? 1 : 0)
            + (f.peoplePresence != nil ? 1 : 0)
    }

    var searchQuery: String = ""
    var searchFilters = SearchFilters()
    var searchResults: [TimelineItem] = []
    var searching = false
    private var semanticIndex: SemanticIndex?
    private var semanticIndexDirty = true     // set true after an embed drain

    // MARK: — People state
    var people: [PersonRow] = []
    var suggestedClusters: [FaceCluster] = []
    /// personID → unassigned faceIDs that match this person's centroid (suggested additions to confirm).
    var suggestedAdditions: [Int64: [Int64]] = [:]
    /// Unassigned faces that matched no person and formed no cluster — the "Other faces" bucket, so
    /// every detected face is reachable (DBSCAN noise was previously invisible).
    var otherFaceIDs: [Int64] = []
    /// Non-nil → the People view shows this person's detail grid. Lifted out of the view so the
    /// inspector's "In this image" section can deep-link straight to a person.
    var openedPerson: PersonRow?
    /// True → the People view shows the "Other faces" bucket grid.
    var browsingOtherFaces = false
    var facesLoading = false
    /// Hidden auto-face IDs (user-dismissed faces that should not appear in the Other bucket).
    var hiddenFaceIDs: [Int64] = []
    private var facesDirty = true
    private var geocodeDirty = true
    /// Grouping sensitivity (0 = Strict … 1 = Loose), persisted. Drives the DBSCAN / centroid-match
    /// params. Releasing the slider re-groups instantly over the already-embedded faces (see
    /// `reclusterForSensitivity`) — it never reassigns confirmed faces, so named people stay intact.
    /// Default 0.5 reproduces the original constants. (Re-embedding faces the gate skipped still needs
    /// a Rescan Faces.)
    var faceSensitivity: Double = UserDefaults.standard.object(forKey: "faceSensitivity") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(faceSensitivity, forKey: "faceSensitivity") }
    }
    private var faceClusterParams: FaceClusterParams { .forSensitivity(faceSensitivity) }
    private var faceClusterEps: Double { faceClusterParams.eps }
    private var faceClusterMinPts: Int { faceClusterParams.minPts }
    private var faceMatchThreshold: Double { faceClusterParams.matchThreshold }

    /// Recompute the People screen off the main actor: named people, suggested ADDITIONS to existing
    /// people (faces near a person's centroid), suggested NEW clusters (DBSCAN over the rest), and the
    /// "Other faces" bucket (everything left). Every unassigned face lands in exactly one of the three.
    func loadPeople() {
        guard let lib = library else { return }
        facesLoading = true
        let eps = faceClusterEps, minPts = faceClusterMinPts, matchThreshold = faceMatchThreshold
        Task {
            let result: (people: [PersonRow], clusters: [FaceCluster],
                         additions: [Int64: [Int64]], other: [Int64]) =
                await Task.detached(priority: .userInitiated) {
                    let ppl = (try? lib.catalog.people()) ?? []
                    let unassigned = (try? lib.catalog.unassignedFacesWithEmbeddings()) ?? []

                    // Per-person centroids from current-model confirmed vectors.
                    var byPerson: [Int64: [[Float]]] = [:]
                    for a in (try? lib.catalog.assignedFacesWithEmbeddings()) ?? [] {
                        byPerson[a.personID, default: []].append(a.vector)
                    }
                    let centroids: [(personID: Int64, vector: [Float])] = byPerson.compactMap { pid, vecs in
                        FaceMatcher.centroid(vecs).map { (pid, $0) }
                    }

                    // Match unassigned → nearest person (suggestions); cluster the rest; bucket the noise.
                    let (rawMatched, unmatched) = FaceMatcher.match(
                        faces: unassigned, centroids: centroids, threshold: matchThreshold)
                    // Drop faces the user dismissed for a person ("not this person") — they fall through
                    // to the Other bucket rather than being re-suggested to that same person.
                    let dismissed = (try? lib.catalog.dismissedSuggestions()) ?? [:]
                    let matched = rawMatched.compactMap { m -> (personID: Int64, faceIDs: [Int64])? in
                        let kept = m.faceIDs.filter { !(dismissed[m.personID]?.contains($0) ?? false) }
                        return kept.isEmpty ? nil : (personID: m.personID, faceIDs: kept)
                    }
                    let additions = Dictionary(uniqueKeysWithValues: matched.map { ($0.personID, $0.faceIDs) })
                    let groups = DBSCAN.groups(unmatched, eps: eps, minPts: minPts)
                    let conf = groups.map { FaceCluster(faceIDs: $0, representativeFaceID: $0.first ?? 0,
                                                        count: $0.count) }
                    // Other faces = EVERY unassigned face (incl. gated ones with no embedding, which
                    // clustering/matching never see) that isn't a suggested addition or in a cluster —
                    // so no detected face is unreachable. Ordered best-quality-first by the query.
                    let matchedIDs = Set(matched.flatMap { $0.faceIDs })
                    let clusteredIDs = Set(groups.flatMap { $0 })
                    let allUnassigned = (try? lib.catalog.unassignedAutoFaceIDs()) ?? []
                    let other = allUnassigned.filter { !matchedIDs.contains($0) && !clusteredIDs.contains($0) }
                    return (ppl, conf, additions, other)
                }.value
            self.people = result.people
            self.suggestedClusters = result.clusters
            self.suggestedAdditions = result.additions
            self.otherFaceIDs = preservingOtherOrder(result.other)
            self.facesLoading = false
            self.facesDirty = false
        }
    }

    /// Preserve the current display order of the Other-faces bucket across a re-fetch: faces still
    /// present keep their position (so a Shuffle — or any manual ordering — survives assigning or
    /// hiding faces), removed faces drop out, and genuinely new faces are appended. Without this, the
    /// fast re-match after each assignment reset the bucket to the catalog's default order, silently
    /// undoing a shuffle (you'd snap back to the default first-500).
    private func preservingOtherOrder(_ fresh: [Int64]) -> [Int64] {
        let freshSet = Set(fresh)
        let kept = otherFaceIDs.filter { freshSet.contains($0) }
        let keptSet = Set(kept)
        return kept + fresh.filter { !keptSet.contains($0) }
    }

    /// FAST re-match used after assigning faces (confirming suggestions / adding to a person). Only
    /// re-runs the cheap centroid match — NOT the O(n²) DBSCAN clustering, and NOT face re-derivation —
    /// so confirming a suggestion immediately surfaces the next batch the sharpened centroid now
    /// matches, with no "Rescan Faces" needed. Existing clusters are pruned of now-assigned faces.
    func refreshSuggestions() {
        guard let lib = library else { return }
        let matchThreshold = faceMatchThreshold, minPts = faceClusterMinPts
        let existingClusters = suggestedClusters
        Task {
            let result: (people: [PersonRow], clusters: [FaceCluster],
                         additions: [Int64: [Int64]], other: [Int64]) =
                await Task.detached(priority: .userInitiated) {
                    let ppl = (try? lib.catalog.people()) ?? []
                    let unassigned = (try? lib.catalog.unassignedFacesWithEmbeddings()) ?? []
                    let unassignedIDs = Set(unassigned.map(\.id))

                    var byPerson: [Int64: [[Float]]] = [:]
                    for a in (try? lib.catalog.assignedFacesWithEmbeddings()) ?? [] {
                        byPerson[a.personID, default: []].append(a.vector)
                    }
                    let centroids = byPerson.compactMap { pid, vecs in
                        FaceMatcher.centroid(vecs).map { (pid, $0) }
                    }
                    let (rawMatched, _) = FaceMatcher.match(
                        faces: unassigned, centroids: centroids, threshold: matchThreshold)
                    // Honour user dismissals ("not this person") — never re-suggest a dismissed pair.
                    let dismissed = (try? lib.catalog.dismissedSuggestions()) ?? [:]
                    let matched = rawMatched.compactMap { m -> (personID: Int64, faceIDs: [Int64])? in
                        let kept = m.faceIDs.filter { !(dismissed[m.personID]?.contains($0) ?? false) }
                        return kept.isEmpty ? nil : (personID: m.personID, faceIDs: kept)
                    }
                    let additions = Dictionary(uniqueKeysWithValues: matched.map { ($0.personID, $0.faceIDs) })
                    let matchedIDs = Set(matched.flatMap { $0.faceIDs })

                    // Keep the prior clusters but drop faces now assigned or matched; cheap, no re-DBSCAN.
                    let clusters: [FaceCluster] = existingClusters.compactMap { c in
                        let ids = c.faceIDs.filter { unassignedIDs.contains($0) && !matchedIDs.contains($0) }
                        guard ids.count >= minPts else { return nil }
                        return FaceCluster(faceIDs: ids, representativeFaceID: ids.first ?? 0, count: ids.count)
                    }
                    let clusteredIDs = Set(clusters.flatMap { $0.faceIDs })
                    let allUnassigned = (try? lib.catalog.unassignedAutoFaceIDs()) ?? []
                    let other = allUnassigned.filter { !matchedIDs.contains($0) && !clusteredIDs.contains($0) }
                    return (ppl, clusters, additions, other)
                }.value
            self.people = result.people
            self.suggestedClusters = result.clusters
            self.suggestedAdditions = result.additions
            self.otherFaceIDs = preservingOtherOrder(result.other)
        }
    }

    /// Hide the given faces from the Other bucket (reversible "ignore"); they also stop being suggested.
    func hideFaces(_ ids: [Int64]) {
        guard let lib = library, !ids.isEmpty else { return }
        Task {
            let lists = await Task.detached(priority: .userInitiated) {
                try? lib.catalog.setFacesHidden(ids, hidden: true)
                return ((try? lib.catalog.unassignedAutoFaceIDs()) ?? [],
                        (try? lib.catalog.hiddenAutoFaceIDs()) ?? [])
            }.value
            self.otherFaceIDs = preservingOtherOrder(lists.0)
            self.hiddenFaceIDs = lists.1
        }
    }

    /// Restore (un-hide) the given faces back into the Other bucket.
    func unhideFaces(_ ids: [Int64]) {
        guard let lib = library, !ids.isEmpty else { return }
        Task {
            let lists = await Task.detached(priority: .userInitiated) {
                try? lib.catalog.setFacesHidden(ids, hidden: false)
                return ((try? lib.catalog.unassignedAutoFaceIDs()) ?? [],
                        (try? lib.catalog.hiddenAutoFaceIDs()) ?? [])
            }.value
            self.otherFaceIDs = preservingOtherOrder(lists.0)
            self.hiddenFaceIDs = lists.1
        }
    }

    /// Load the hidden-faces list (for the "Show hidden" view).
    func loadHiddenFaces() {
        guard let lib = library else { return }
        Task {
            let ids = await Task.detached(priority: .userInitiated) {
                (try? lib.catalog.hiddenAutoFaceIDs()) ?? []
            }.value
            self.hiddenFaceIDs = ids
        }
    }

    /// Dismiss a person's suggested additions: the faces drop to the Other-faces bucket and are
    /// remembered (persisted) as "not this person", so they're never re-suggested for this person.
    func dismissSuggestions(forPerson personID: Int64) {
        let ids = suggestedAdditions[personID] ?? []
        otherFaceIDs.append(contentsOf: ids)
        suggestedAdditions[personID] = nil
        persistDismissals(ids, forPerson: personID)
    }

    /// Dismiss ONE suggested face for a person (the per-tile ✕): drop it to the Other bucket AND
    /// remember it so it is never re-suggested for this person again (persisted in the catalog).
    func dismissSuggestion(faceID: Int64, forPerson personID: Int64) {
        if var ids = suggestedAdditions[personID] {
            ids.removeAll { $0 == faceID }
            suggestedAdditions[personID] = ids.isEmpty ? nil : ids
        }
        if !otherFaceIDs.contains(faceID) { otherFaceIDs.append(faceID) }
        persistDismissals([faceID], forPerson: personID)
    }

    /// Persist "not this person" dismissals off-main. `loadPeople`/`refreshSuggestions` read these
    /// back and exclude the pairs from suggested additions.
    private func persistDismissals(_ faceIDs: [Int64], forPerson personID: Int64) {
        guard let lib = library, !faceIDs.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            try? lib.catalog.dismissSuggestions(faceIDs, forPerson: personID)
        }
    }

    /// Optimistic UI: immediately remove these faces from every in-memory suggestion bucket so an
    /// accept/move/name feels instant. The catalog + sidecar writes (and a reconciling
    /// refreshSuggestions) follow in the background. Never touches confirmed assignments.
    private func removeFromSuggestionBuckets(_ faceIDs: [Int64]) {
        let drop = Set(faceIDs)
        otherFaceIDs.removeAll { drop.contains($0) }
        for (pid, ids) in suggestedAdditions {
            let kept = ids.filter { !drop.contains($0) }
            suggestedAdditions[pid] = kept.isEmpty ? nil : kept
        }
        suggestedClusters = suggestedClusters.compactMap { c in
            let kept = c.faceIDs.filter { !drop.contains($0) }
            guard !kept.isEmpty else { return nil }
            let rep = kept.contains(c.representativeFaceID) ? c.representativeFaceID : (kept.first ?? c.representativeFaceID)
            return FaceCluster(faceIDs: kept, representativeFaceID: rep, count: kept.count)
        }
    }

    /// Manually tag a person as present in the given photos WITHOUT a detected face (for obscured
    /// faces). The photos appear in the person's grid for VIEWING, but the tag carries no embedding, so
    /// it never informs clustering or the person's centroid. Sidecars are rewritten so the tag is
    /// sovereign and survives a catalog rebuild.
    func tagPerson(_ personID: Int64, inPhotos hashes: [String]) {
        guard let lib = library, !hashes.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            for h in hashes { _ = try? lib.catalog.addManualPersonTag(hash: h, personID: personID) }
            self?.writeSidecarRegions(forPersonID: personID, lib: lib)
            await MainActor.run { [weak self] in
                self?.facesDirty = true; self?.refreshSuggestions(); self?.refreshToken &+= 1
            }
        }
    }

    /// Create a new person and manually tag them into the given photos (no detected face required).
    func tagNewPerson(named name: String, inPhotos hashes: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lib = library, !trimmed.isEmpty, !hashes.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let pid = try? lib.catalog.createPerson(name: trimmed) else { return }
            for h in hashes { _ = try? lib.catalog.addManualPersonTag(hash: h, personID: pid) }
            self?.writeSidecarRegions(forPersonID: pid, lib: lib)
            await MainActor.run { [weak self] in
                self?.facesDirty = true; self?.refreshSuggestions(); self?.refreshToken &+= 1
            }
        }
    }

    /// Manual "Rescan Faces" (Settings → Library): re-run detection + embedding across the library with
    /// the current model. Named people are kept (confirmed faces survive + their identity lives in the
    /// XMP sidecar). We do NOT delete the existing auto faces up front — that would make every
    /// unassigned face vanish until the (slow, whole-library) re-derivation rebuilds them. Instead we
    /// just re-pend the face jobs; `replaceFaces` swaps each photo's faces in place as it is
    /// re-processed, so the People screen stays populated and updates progressively.
    /// Re-group over the faces that are ALREADY embedded, using the current sensitivity — cheap, no
    /// re-derivation. Confirmed people are never touched. Called when the sensitivity slider is
    /// released. To (re)embed faces the size gate previously skipped, use `rescanFaces()`.
    func reclusterForSensitivity() { loadPeople() }

    func rescanFaces() {
        guard let lib = library else { return }
        Task {
            await Task.detached(priority: .userInitiated) {
                try? lib.catalog.clearDerivationJobs(stage: FaceStage.id)
                try? lib.catalog.clearDismissedSuggestions()   // faceIDs change on re-derive
            }.value
            loadPeople()        // refresh from current state (faces still present)
            pokeDerivation()    // re-detect + re-embed in the background; drain refreshes People
        }
    }

    // MARK: — Tidy Up (cull)

    struct CullGroup: Identifiable {
        let id: String                  // stable group id = the keeper's instanceID
        let items: [TimelineItem]
        let keepInstanceID: String      // the tile to keep; every other tile is pre-selected for deletion
        let suggestedEvict: Set<String> // instanceIDs pre-selected for deletion
    }
    /// Scope for the exact-content Duplicates finder: same-folder redundant copies, or anywhere.
    enum CullDuplicateScope: Sendable, Hashable { case withinFolder, anywhere }
    var cullMode: CullMode = .bursts
    var cullDuplicateScope: CullDuplicateScope = .withinFolder
    var cullGroups: [CullGroup] = []
    var cullLoading = false
    private var cullLoadToken = 0   // bumped per load; a stale detached result is dropped if a newer switch superseded it

    /// Compute redundant-photo groups off-main (the loadPeople pattern). Bursts reuse `embeddings`;
    /// Duplicates use the `phash` table. Sharpness (bursts) is measured on-demand from cached thumbs.
    func loadCullGroups() {
        guard let lib = library else { return }
        let mode = cullMode
        let dupScope: Catalog.DuplicateScope = cullDuplicateScope == .anywhere ? .anywhere : .withinFolder
        cullLoadToken &+= 1
        let token = cullLoadToken
        cullGroups = []          // drop the previous mode's groups now — don't show them stale under the new label
        cullLoading = true
        Task {
            let groups: [CullGroup] = await Task.detached(priority: .userInitiated) {
                var out: [CullGroup] = []
                switch mode {
                case .duplicates:
                    // Exact same-content files (same sha256), as instanceID groups, scoped. Identical
                    // content, so keep one deterministically (shortest path) and evict the other files.
                    for ids in (try? lib.catalog.duplicateInstanceGroups(scope: dupScope)) ?? [] {
                        let items = (try? lib.catalog.items(instanceIDs: ids)) ?? []
                        guard items.count >= 2 else { continue }
                        let ordered = items.sorted {
                            $0.relPath.count != $1.relPath.count
                                ? $0.relPath.count < $1.relPath.count
                                : $0.instanceID < $1.instanceID
                        }
                        let keep = ordered[0].instanceID
                        out.append(CullGroup(id: keep, items: items, keepInstanceID: keep,
                                             suggestedEvict: Set(ordered.dropFirst().map(\.instanceID))))
                    }
                case .bursts, .similar:
                    // Perceptual grouping of DISTINCT photos (different hashes). Keeper picked by
                    // KeeperSelector (sharpest/highest-res), mapped to its tile's instanceID.
                    let raw: [[String]]
                    if mode == .bursts {
                        let emb = (try? lib.catalog.embeddingsWithTakenAt(model: EmbedStage().modelID)) ?? []
                        raw = BurstGrouper.group(emb, windowMs: 60_000, cosineThreshold: 0.93)
                    } else {
                        let rows = (try? lib.catalog.phashRowsWithDirPath()) ?? []
                        raw = DuplicateGrouper.group(rows, hammingThreshold: 6)
                    }
                    for g in raw {
                        let items = (try? lib.catalog.items(forHashes: g, preservingOrder: true)) ?? []
                        guard items.count >= 2 else { continue }
                        var cands: [KeeperSelector.Candidate] = []
                        for it in items {
                            var sharp: Double? = nil
                            if mode == .bursts,
                               let img = await lib.thumbnails.cachedDisplayImage(
                                   for: ContentHash(stringValue: it.hash), maxPixel: ThumbnailStore.maxPixel) {
                                sharp = FocusMeasure.varianceOfLaplacian(img)
                            }
                            cands.append(.init(hash: it.hash,
                                               pixelCount: (it.pixelWidth ?? 0) * (it.pixelHeight ?? 0),
                                               fileSize: it.size, favorite: it.favorite,
                                               rating: it.rating, sharpness: sharp))
                        }
                        let s = KeeperSelector.suggestion(cands, mode: mode)
                        let keepID = items.first { $0.hash == s.keep }?.instanceID ?? items[0].instanceID
                        let evictIDs = Set(items.filter { s.evict.contains($0.hash) }.map(\.instanceID))
                        out.append(CullGroup(id: keepID, items: items, keepInstanceID: keepID,
                                             suggestedEvict: evictIDs))
                    }
                }
                return out
            }.value
            guard token == self.cullLoadToken else { return }   // a newer mode switch superseded this load
            self.cullGroups = groups
            self.cullLoading = false
        }
    }

    // MARK: — People management (catalog + sidecar paired writes)

    /// Confirm a cluster as a new person: create the person in the catalog, assign all faces
    /// (flipping them to 'confirmed'), then write each asset's confirmed regions to its XMP sidecar.
    /// Called off the main actor via Task.detached; loadPeople() is re-called on main after.
    func nameCluster(_ faceIDs: [Int64], as name: String) {
        guard let lib = library else { return }
        removeFromSuggestionBuckets(faceIDs)   // optimistic: the named faces leave the suggestion UI now
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let personID = try lib.catalog.createPerson(name: name)
                try lib.catalog.assignFaces(faceIDs, to: personID)
                self?.rewriteSidecars(forFaceIDs: faceIDs, lib: lib)   // only the affected photos
            } catch { NSLog("nameCluster failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
                self?.refreshToken &+= 1      // reflect the new assignment in the Inspector
            }
        }
    }

    /// Merge `src` person into `dst`: catalog merge + rewrite dst's sidecars with the dst name.
    func mergePeople(_ src: Int64, into dst: Int64) {
        guard let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try lib.catalog.mergePerson(src, into: dst)
                self?.writeSidecarRegions(forPersonID: dst, lib: lib)
                // Remove any sidecar regions that were under src (now moved to dst, already rewritten).
            } catch { NSLog("mergePeople failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
            }
        }
    }

    /// Move selected faces to a new person (split). Creates the person, reassigns each face,
    /// rewrites sidecars for both the old person (losing those faces) and the new person.
    func splitFaces(_ faceIDs: [Int64], fromPerson sourcePerson: Int64, toNewPerson name: String) {
        guard let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let newID = try lib.catalog.createPerson(name: name)
                for id in faceIDs { try lib.catalog.reassignFace(id, to: newID) }
                // Only the moved photos changed (region name old→new); rewrite just those — the
                // source person's other photos are untouched.
                self?.rewriteSidecars(forFaceIDs: faceIDs, lib: lib)
            } catch { NSLog("splitFaces failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
            }
        }
    }

    /// Rename a person: update the catalog, then rewrite the person's photos' sidecars so the
    /// on-disk MWG region name matches (writeSidecarRegions reads the new name from the catalog).
    func renamePerson(_ personID: Int64, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try lib.catalog.renamePerson(personID, to: trimmed)
                self?.writeSidecarRegions(forPersonID: personID, lib: lib)
            } catch { NSLog("renamePerson failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
            }
        }
    }

    /// Move selected faces to an EXISTING person. Mirrors splitFaces but assigns to a chosen person
    /// instead of creating one. Rewrites sidecars for the destination (gains regions) and the source
    /// (loses them); both pull current catalog state per affected hash, so stale names drop.
    func moveFaces(_ faceIDs: [Int64], toPerson personID: Int64, fromPerson old: Int64?) {
        guard !faceIDs.isEmpty, let lib = library else { return }
        removeFromSuggestionBuckets(faceIDs)   // optimistic: the tiles leave the suggestion UI now
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try lib.catalog.assignFaces(faceIDs, to: personID)
                // Rewrite ONLY the affected photos' sidecars (not the person's whole back-catalogue).
                self?.rewriteSidecars(forFaceIDs: faceIDs, lib: lib)
            } catch { NSLog("moveFaces failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
            }
        }
    }

    /// Reassign one face to another person (or nil → unassign). Updates sidecars accordingly.
    func reassignFace(_ id: Int64, to personID: Int64?, fromPerson oldPersonID: Int64?) {
        guard let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            // Resolve the affected photo BEFORE the reassign (unassigning a manual tag deletes the row).
            let hash = ((try? lib.catalog.face(forID: id)) ?? nil)?.hash
            do { try lib.catalog.reassignFace(id, to: personID) }
            catch { NSLog("reassignFace failed: \(error)") }
            // Only the one affected photo's sidecar changes — rewrite it from current confirmed state
            // (drops the region if now unassigned, updates the name if moved to a different person).
            if let hash { self?.rewriteSidecarForHash(hash, lib: lib) }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
                self?.refreshToken &+= 1      // reflect the change in the Inspector's "In this image"
            }
        }
    }

    /// Set a person's People-screen cover to one of their confirmed faces.
    func setPersonCover(personID: Int64, faceID: Int64) {
        guard let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            try? lib.catalog.setPersonCover(personID: personID, faceID: faceID)
            await MainActor.run { [weak self] in
                self?.refreshSuggestions()   // reloads people (new cover) + preserves Other order
            }
        }
    }

    /// Delete a person (faces revert to unassigned). Clears their regions from sidecars.
    func removePerson(_ personID: Int64) {
        guard let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Collect all face hashes before deleting so we can clear their regions.
                let faceRows = (try? lib.catalog.faces(forPerson: personID)) ?? []
                try lib.catalog.deletePerson(personID)
                // After deletion the faces are unassigned — remove this person's named regions.
                // Group by hash and rewrite each sidecar minus the now-deleted person's faces.
                let hashes = Set(faceRows.map(\.hash))
                for hash in hashes {
                    self?.rewriteSidecarForHash(hash, lib: lib)
                }
            } catch { NSLog("removePerson failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.refreshSuggestions()   // fast re-match; surfaces the next batch without a rescan
            }
        }
    }

    /// Rotate a photo/video by 90° (delta ±90), display-only. Writes the rotation to the sidecar +
    /// catalog (originals untouched), then refreshes the opened item + grids so every surface re-renders.
    func rotate(_ item: TimelineItem, by delta: Int) {
        guard let lib = library else { return }
        let target = item.rotation + delta
        Task.detached(priority: .userInitiated) { [weak self] in
            let norm = (try? lib.setRotation(for: item, rotation: target))
                       ?? (((target % 360) + 360) % 360)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Rotation lives per-asset in the catalog, but every TimelineItem snapshot caches it.
                // refreshQueries() rebuilds the timeline/folder queries — but NOT `viewerItems` (the
                // array the open viewer navigates) or the already-bound `openedItem`. Update those in
                // place too, or the rotation reverts the moment you navigate or re-open the photo.
                if self.openedItem?.hash == item.hash { self.openedItem?.rotation = norm }
                for i in self.viewerItems.indices where self.viewerItems[i].hash == item.hash {
                    self.viewerItems[i].rotation = norm
                }
                try? self.refreshQueries()
                self.refreshToken &+= 1   // folder grids + face thumbnails re-read the new rotation
            }
        }
    }

    // MARK: — Private sidecar helpers (nonisolated — run off main actor only)

    /// Write (or rewrite) MWG face regions into the sidecars of every asset that has a confirmed
    /// face for `personID`. Groups faces by hash, reads the existing sidecar (preserving other
    /// fields), merges all confirmed regions for that asset, and writes atomically.
    /// Called off the main actor; best-effort (a failed write is logged, not fatal).
    nonisolated private func writeSidecarRegions(forPersonID personID: Int64, lib: LibraryService) {
        let faceRows: [FaceRow]
        do { faceRows = try lib.catalog.faces(forPerson: personID) } catch { return }
        guard !faceRows.isEmpty else { return }
        // Fetch the person's name once.
        let personName: String
        do {
            personName = (try lib.catalog.people()).first { $0.id == personID }?.name ?? ""
        } catch { return }
        guard !personName.isEmpty else { return }
        // Group face rows by asset hash.
        let byHash = Dictionary(grouping: faceRows, by: { $0.hash })
        for (hash, faces) in byHash {
            rewriteSidecarForHash(hash, lib: lib,
                                  addRegions: faces.map {
                                      FaceRegion(name: personName, visionRect: $0.rect)
                                  })
        }
    }

    /// Rewrite ONLY the sidecars of the photos that contain `faceIDs` (the assets actually changed by
    /// a move/assign/split/name), pulling current confirmed catalog state per hash. O(affected photos)
    /// — unlike writeSidecarRegions(forPersonID:), which rewrites a person's ENTIRE back-catalogue and
    /// is only needed when a name changes across all their photos (rename/merge). This is what keeps an
    /// "add to person" instant instead of rewriting thousands of sidecars for a large person.
    nonisolated private func rewriteSidecars(forFaceIDs faceIDs: [Int64], lib: LibraryService) {
        var hashes = Set<String>()
        for id in faceIDs {
            if let row = (try? lib.catalog.face(forID: id)) ?? nil { hashes.insert(row.hash) }
        }
        for h in hashes { rewriteSidecarForHash(h, lib: lib) }
    }

    /// Clear the sidecar region for a single face that has been unassigned (no person).
    /// Resolves the face's asset hash via Catalog.face(forID:), then rewrites the sidecar from
    /// the current confirmed catalog state — the now-unassigned face is source='auto'/personID=nil
    /// so it is excluded, dropping the stale <mwg-rs:Name> region. Best-effort.
    nonisolated private func clearSidecarRegion(forFaceID faceID: Int64, lib: LibraryService) {
        guard let row = try? lib.catalog.face(forID: faceID) else { return }
        rewriteSidecarForHash(row.hash, lib: lib)   // full rewrite from current confirmed state → stale region dropped
    }

    /// Rewrite the sidecar for `hash` so it contains exactly the confirmed face regions that
    /// the catalog currently knows about for that asset. All other sidecar fields are preserved.
    /// If `addRegions` is provided, those are merged in (used when writing a newly-confirmed set).
    nonisolated private func rewriteSidecarForHash(_ hash: String, lib: LibraryService,
                                                   addRegions: [FaceRegion] = []) {
        // Resolve the asset's local instance (prefer a local Mac copy for write).
        guard let instance = (try? lib.catalog.instances(forHash: hash))?.first(where: { inst in
            lib.vault(id: inst.vaultID) != nil
        }), let vault = lib.vault(id: instance.vaultID) else { return }
        let store = SidecarStore(vault: vault)
        do {
            var data = (try? store.read(forMediaRelPath: instance.relPath)) ?? .empty
            // Collect all confirmed faces for this hash from the catalog.
            let confirmedFaces = (try? lib.catalog.faces(forHash: hash))?.filter {
                $0.source == "confirmed" && $0.personID != nil
            } ?? []
            // Build the full region list: confirmed catalog faces + new regions being added.
            var regions: [FaceRegion] = addRegions
            for face in confirmedFaces {
                // Resolve person name.
                if let personID = face.personID,
                   let name = (try? lib.catalog.people())?.first(where: { $0.id == personID })?.name {
                    regions.append(FaceRegion(name: name, visionRect: face.rect))
                }
            }
            // Deduplicate by name+rect (addRegions may overlap with confirmedFaces on a fresh assign).
            var seen = Set<String>()
            regions = regions.filter { r in
                let key = "\(r.name)|\(r.visionRect.minX)|\(r.visionRect.minY)"
                return seen.insert(key).inserted
            }
            data.faces = regions
            try store.write(data, forMediaRelPath: instance.relPath)
        } catch {
            NSLog("rewriteSidecarForHash \(hash) failed: \(error)")
        }
    }

    func runSearch() {
        guard let lib = library else { return }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = searchFilters
        guard !q.isEmpty || !filters.isEmpty else { searchResults = []; return }
        searching = true
        // Capture current index state on the main actor before going off-main.
        let needsRebuild = semanticIndexDirty || semanticIndex == nil
        let currentIndex = semanticIndex
        Task {
            // Run all heavy work (SQL + Accelerate + Core ML) off the main actor.
            let (items, freshIndex): ([TimelineItem], SemanticIndex?) = await Task.detached(priority: .userInitiated) {
                let structured: [String]
                if filters.isEmpty {
                    structured = q.isEmpty ? [] : (try? lib.catalog.allHashesNewestFirst()) ?? []
                } else {
                    structured = (try? lib.catalog.structuredFilter(filters)) ?? []
                }
                guard !q.isEmpty else {
                    let its = (try? lib.catalog.items(forHashes: structured, preservingOrder: true)) ?? []
                    return (its, nil)
                }
                let text = (try? lib.catalog.textMatches(q)) ?? []
                // Rebuild semantic index if dirty.
                let idx: SemanticIndex?
                let builtFresh: SemanticIndex?
                if needsRebuild {
                    builtFresh = try? SemanticIndex(catalog: lib.catalog, model: EmbedStage().modelID)
                    idx = builtFresh
                } else {
                    builtFresh = nil
                    idx = currentIndex
                }
                let semantic: [(hash: String, score: Float)]
                if let idx, let qVec = EmbedStage().embedText(q) {
                    semantic = idx.query(qVec, topN: 300)
                } else {
                    semantic = []
                }
                let ranked = SearchRanker.combine(structured: structured, text: text,
                                                  semantic: semantic, hasText: true)
                let its = (try? lib.catalog.items(forHashes: ranked, preservingOrder: true)) ?? []
                return (its, builtFresh)
            }.value
            // Publish results + store fresh index (if rebuilt) back on the main actor.
            self.searchResults = items
            self.searching = false
            if let freshIndex {
                self.semanticIndex = freshIndex
                self.semanticIndexDirty = false
            }
        }
    }

    /// Deep-link from the inspector's place label into Search, filtered to that place (city or country).
    func searchInPlace(_ place: GeocodeRow) {
        searchQuery = ""
        searchFilters = SearchFilters()
        // Set the place dimension: prefer city when available, else country.
        searchFilters.includePlaces = [place.city.isEmpty
            ? .country(place.countryCode)
            : .city(countryCode: place.countryCode, city: place.city)]
        selection = .search
        openedItem = nil
        runSearch()
    }

    /// Viewer: whether the bottom gallery (filmstrip) is expanded. Defaults to shown.
    var viewerGalleryShown: Bool = UserDefaults.standard.object(forKey: "viewerGalleryShown") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "viewerGalleryShown") {
        didSet { UserDefaults.standard.set(viewerGalleryShown, forKey: "viewerGalleryShown") }
    }
    var sidebarShown: Bool = UserDefaults.standard.object(forKey: "sidebarShown") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "sidebarShown") {
        didSet {
            UserDefaults.standard.set(sidebarShown, forKey: "sidebarShown")
        }
    }
    private var _importRegistry: ImportRegistry?
    var importRegistry: ImportRegistry? {
        if _importRegistry == nil, let primary = library?.vaults.first {
            _importRegistry = ImportRegistry(vault: primary)
        }
        return _importRegistry
    }
    private var _sendRegistry: SendRegistry?
    var sendRegistry: SendRegistry? {
        if _sendRegistry == nil, let primary = library?.vaults.first {
            _sendRegistry = SendRegistry(vault: primary)
        }
        return _sendRegistry
    }
    private var _deviceRegistry: DeviceRegistry?
    var deviceRegistry: DeviceRegistry? {
        if _deviceRegistry == nil, let primary = library?.vaults.first {
            _deviceRegistry = DeviceRegistry(vault: primary)
        }
        return _deviceRegistry
    }
    private var watcher: FolderWatcher?

    /// Open the viewer on `item`, navigating within `items` (timeline set or one folder).
    func openViewer(_ item: TimelineItem, within items: [TimelineItem]) {
        viewerItems = items
        openedItem = item
    }

    /// Jump to a person's detail grid in the People view (used by the inspector's "In this image").
    func openPerson(_ person: PersonRow) {
        openedItem = nil
        openedPerson = person
        selection = .people
    }

    /// Resolve the photos a set of faces appear in, paired with each face, preserving the face order
    /// and dropping faces whose asset can't be resolved. Shared by the person + cluster detail grids.
    func facePhotos(for faces: [FaceRow]) -> [FacePhoto] {
        guard let lib = library else { return [] }
        return faces.compactMap { face in
            (try? lib.item(hash: face.hash)).flatMap { $0 }.map { FacePhoto(face: face, item: $0) }
        }
    }

    /// Prompt for a folder and add it as an import source, then open it.
    /// Shared by the sidebar IMPORT button and the File-menu command.
    func addImportSourceViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Source"
        panel.message = "Choose a folder to import photos from."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        deviceWatcher.addImportFolder(url: url)
        if let dev = deviceWatcher.devices.first(where: {
            $0.id == "vol-manual-" + url.path || $0.id == "takeout-manual-" + url.path
                || $0.id == "appleexport-manual-" + url.path
        }) {
            openedDevice = dev
        }
    }

    /// Remove a manually-added folder import source (phones/SD cards are removed by unplugging).
    func removeImportSource(_ device: ConnectedDevice) {
        deviceWatcher.removeManualVolume(id: device.id)
    }

    /// Prompt for a folder/drive and Quick View it (the raw-folder entry point). Shared by the Drives
    /// toolbar button and the File-menu command.
    func quickViewFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Quick View"
        panel.message = "Choose a folder or drive to browse without adding it to your library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await startQuickView(root: url) }
    }

    /// Start an ephemeral, trace-free peek of `root` (a drive or any folder). Loads off-main into a
    /// throwaway temp dir; nothing is written to `root` or persisted on the Mac.
    func startQuickView(root: URL) async {
        endQuickView()   // tear down any prior peek first (single peekContext)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPhotoPeek-" + UUID().uuidString)
        let ctx = await Task.detached(priority: .userInitiated) {
            try? PeekSource.load(root: root, tempDir: tmp)
        }.value
        if let ctx {
            peekContext = ctx
        } else {
            try? FileManager.default.removeItem(at: tmp)
            driveAlert("Couldn\u{2019}t open Quick View",
                       "\u{201c}\(root.lastPathComponent)\u{201d} couldn\u{2019}t be read.")
        }
    }

    /// End the current peek and delete its temp dir (idempotent).
    func endQuickView() {
        guard let ctx = peekContext else { return }
        peekContext = nil
        try? FileManager.default.removeItem(at: ctx.tempDir)
    }

    // All drives that hold the library durably (canonical + its backups). Used for presence,
    // browse, drift, deletion, and as candidate read/verify sources.
    private(set) var durableVaults: [VaultRecord] = []
    // The authoritative canonical (source of truth / preferred read source / migration anchor).
    var canonicalVault: VaultRecord? { durableVaults.first { $0.role == "canonical" } }

    /// Connected durable drives as open Vaults, canonical first — so reads/verifies (rehydrate,
    /// evict, send) prefer the canonical source of truth and fall back to a backup.
    func connectedDrivesCanonicalFirst() -> [Vault] {
        durableVaults.filter { driveIsPresent($0) }
            .sorted { ($0.role == "canonical" ? 0 : 1) < ($1.role == "canonical" ? 0 : 1) }
            .compactMap { openVault(for: $0) }
    }

    /// Hashes the canonical currently holds (from its presence mirror) — for "behind by N".
    private func canonicalHashes() -> Set<String> {
        guard let vr = canonicalVault,
              let hs = try? library?.catalog.vaultPresenceHashes(forVault: vr.id) else { return [] }
        return hs
    }

    /// How many photos a backup is missing relative to the canonical (catalog-only, no I/O).
    func backupBehindCount(_ vr: VaultRecord) -> Int {
        guard let hs = try? library?.catalog.vaultPresenceHashes(forVault: vr.id) else { return 0 }
        return OpenPhotoCore.backupBehindCount(canonicalHashes: canonicalHashes(), backupHashes: hs)
    }

    /// A backup is promotable iff it's connected, the canonical is connected, and their content sets
    /// are exactly equal (cheap presence-set gate; promotion re-verifies via manifests).
    func isPromotable(_ vr: VaultRecord) -> Bool {
        guard let lib = library, vr.role == "backup", driveIsPresent(vr),
              let canon = canonicalVault, driveIsPresent(canon) else { return false }
        let canonHashes = (try? lib.catalog.vaultPresenceHashes(forVault: canon.id)) ?? []
        let backupHashes = (try? lib.catalog.vaultPresenceHashes(forVault: vr.id)) ?? []
        return canonicalAgreement(canonicalHashes: canonHashes, backupHashes: backupHashes)
    }

    /// Promote a backup to canonical (planned): re-verify exact agreement against BOTH manifests, then
    /// atomically flip the catalog roles (new→canonical, old→backup) and rewrite the drives' vault.json
    /// best-effort. Returns false (no change) if the backup is not an exact copy — the caller tells the
    /// user to "Update backup" first.
    @discardableResult
    func promoteToCanonical(_ vr: VaultRecord) async -> Bool {
        guard let lib = library, let oldVR = canonicalVault,
              driveIsPresent(vr), driveIsPresent(oldVR),
              let newVault = openVault(for: vr), let oldVault = openVault(for: oldVR) else { return false }
        let agree = await Task.detached(priority: .userInitiated) { () -> Bool in
            let newHashes = Set((try? Manifest.read(from: newVault.manifestURL))?.map { $0.hash.stringValue } ?? [])
            let oldHashes = Set((try? Manifest.read(from: oldVault.manifestURL))?.map { $0.hash.stringValue } ?? [])
            return canonicalAgreement(canonicalHashes: oldHashes, backupHashes: newHashes)
        }.value
        guard agree else { return false }
        try? lib.catalog.setCanonical(vr.id, demoting: oldVR.id)   // atomic catalog flip
        _ = try? newVault.writingRole(.canonical)                  // best-effort on-disk self-describe
        _ = try? oldVault.writingRole(.backup)
        reloadDrives(); reloadCanonicalPresence(); try? refreshQueries()
        return true
    }

    /// When the registered canonical is NOT connected (lost/failed but not yet forgotten), the
    /// precise data-loss picture of recovering from backup `vr`: how many at-risk photos the Mac can
    /// still supply vs how many are lost. nil if there is no registered canonical (already forgotten).
    func recoveryAcknowledgment(_ vr: VaultRecord) -> RecoveryLoss? {
        guard let lib = library, let lostCanon = canonicalVault, !driveIsPresent(lostCanon) else { return nil }
        let lostHashes = (try? lib.catalog.vaultPresenceHashes(forVault: lostCanon.id)) ?? []
        let backupHashes = (try? lib.catalog.vaultPresenceHashes(forVault: vr.id)) ?? []
        let macLocalHashes = (try? lib.catalog.instanceHashes()) ?? []
        return recoveryLoss(lostCanonicalHashes: lostHashes, backupHashes: backupHashes,
                            macLocalHashes: macLocalHashes)
    }

    /// A connected drive whose on-disk vault.json says it's canonical but which ISN'T the registered
    /// canonical -- a leftover from a recovery (the old drive turned up) or a partial flip. Surfaced to
    /// the user for confirmed resolution; the catalog's registered canonical stays authoritative.
    var conflictingCanonical: VaultRecord? {
        durableVaults.first { vr in
            driveIsPresent(vr) && vr.id != canonicalVault?.id
            && (openVault(for: vr)?.descriptor.role == .canonical)
        }
    }

    /// Resolve a canonical conflict: demote the stray drive to a backup (reconcile catalog + vault.json),
    /// or forget it. Never leaves two canonicals.
    func resolveCanonicalConflict(_ vr: VaultRecord, makeBackup: Bool) {
        guard let lib = library else { return }
        if makeBackup {
            // A plain re-register (not setCanonical) is correct: a conflicting drive is by definition
            // NOT the registered canonical (conflictingCanonical excludes canonicalVault), so there is
            // no second canonical to demote in the same breath — we only need this stray set to backup.
            try? lib.catalog.registerVault(id: vr.id, role: "backup", rootPath: vr.rootPath)
            _ = try? openVault(for: vr)?.writingRole(.backup)
            reloadDrives(); reloadCanonicalPresence(); try? refreshQueries()
        } else {
            forgetDrive(vr)
        }
    }

    /// Recovery: promote backup `vr` to canonical when the old canonical is absent (acknowledged by
    /// the caller). Flip the catalog roles (the absent old → backup in the catalog; its vault.json is
    /// reconciled on reconnect by the conflict detector), then SALVAGE everything the Mac still holds
    /// via the existing one-way Mac→canonical sync.
    func recoverCanonical(_ vr: VaultRecord) async {
        guard let lib = library, let newVault = openVault(for: vr) else { return }
        let lostID = canonicalVault?.id
        try? lib.catalog.setCanonical(vr.id, demoting: lostID)
        _ = try? newVault.writingRole(.canonical)
        await Task.detached(priority: .userInitiated) {
            let engine = SyncEngine(library: lib)
            let plan = (try? engine.plan(sources: lib.vaults, destinationVault: newVault)) ?? SyncPlan()
            _ = await engine.apply(plan, destinationVault: newVault,
                                   volume: FileSystemVolume(rootURL: newVault.rootURL))
        }.value
        try? refreshCanonicalPresence(driveVault: newVault)
        let cat = lib.catalog, thumbs = lib.thumbnails
        await Task.detached(priority: .utility) { try? CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: newVault) }.value
        reloadDrives(); reloadCanonicalPresence(); try? refreshQueries()
    }

    /// Clone the canonical onto `vr` (both must be connected): copy the diff hash-verified, then
    /// mark `vr` a backup in the catalog and refresh its presence. Off-main for the copy.
    @discardableResult
    func cloneToBackup(_ vr: VaultRecord) async -> SyncResult {
        guard let lib = library,
              let canonVR = canonicalVault, driveIsPresent(canonVR),
              let canonical = openVault(for: canonVR),
              driveIsPresent(vr), let target = openVault(for: vr) else { return SyncResult() }
        let engine = SyncEngine(library: lib)
        let result = await Task.detached(priority: .userInitiated) {
            guard let plan = try? engine.planClone(source: canonical, destinationVault: target) else { return SyncResult() }
            return await engine.apply(plan, destinationVault: target,
                                      volume: FileSystemVolume(rootURL: target.rootURL),
                                      event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
        }.value
        // Mark the target a backup (catalog role is authoritative for app behavior) and record what
        // it now holds so badges/presence reflect it.
        try? lib.catalog.registerVault(id: target.descriptor.vaultID, role: "backup",
                                       rootPath: target.rootURL.path)
        _ = try? target.writingRole(.backup)   // self-describe on disk so any Mac identifies it correctly
        try? refreshCanonicalPresence(driveVault: target)
        reloadDrives()
        try? refreshQueries()
        let cat = lib.catalog, thumbs = lib.thumbnails
        await Task.detached(priority: .utility) {
            try? CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: target)
        }.value
        return result
    }

    /// Refresh the observable drive list from the catalog. A computed property that queries the
    /// DB doesn't trigger @Observable invalidation, so the Drives view wouldn't react when a drive
    /// is adopted — this stored property does. Call after adopting a drive and at library-open.
    func reloadDrives() {
        durableVaults = (try? library?.catalog.registeredVaults()
            .filter { $0.role == "canonical" || $0.role == "backup" }) ?? []
    }

    private(set) var canonicalPresence: Set<String> = []

    static let ejectedDefaultsKey = "ejectedDrives"
    /// Drives the user manually "ejected" — treated as not-present even though the folder is still
    /// on disk (folder/network drives never physically unmount). Persisted across launches.
    private(set) var ejectedDrives: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: AppState.ejectedDefaultsKey) ?? [])

    func driveIsEjected(_ vr: VaultRecord) -> Bool { ejectedDrives.contains(vr.id) }

    /// The drive's folder is reachable on disk right now (independent of the eject flag).
    func driveFolderExists(_ vr: VaultRecord) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: vr.rootPath, isDirectory: &isDir) && isDir.boolValue
    }

    /// "Connected": reachable AND not ejected. Ejected or missing folders read as not present.
    func driveIsPresent(_ vr: VaultRecord) -> Bool {
        !ejectedDrives.contains(vr.id) && driveFolderExists(vr)
    }

    /// Last-known kind per drive (for accurate labels while unplugged). Refreshed when present.
    private(set) var driveKinds: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "driveKinds") as? [String: String]) ?? [:]

    /// The drive's kind for display. Prefers the cache (kept fresh by add/scan/reconnect) so the
    /// render path stays a pure lookup — a live classify here would do synchronous filesystem I/O
    /// every render, which could hang on a slow/offline network share. Falls back to a one-time
    /// live classify only when the cache is cold.
    func driveKind(_ vr: VaultRecord) -> DriveKind {
        if let cached = DriveKind(rawValue: driveKinds[vr.id] ?? "") { return cached }
        if driveFolderExists(vr) { return DriveKind.of(path: vr.rootPath) }
        return .unknown
    }

    /// Remember a reachable drive's kind so its label stays accurate after it's unplugged.
    func cacheDriveKind(_ vr: VaultRecord) {
        guard driveFolderExists(vr) else { return }
        let raw = DriveKind.of(path: vr.rootPath).rawValue
        if driveKinds[vr.id] != raw {
            driveKinds[vr.id] = raw
            UserDefaults.standard.set(driveKinds, forKey: "driveKinds")
        }
    }

    /// Eject a drive. A real removable/network volume is *physically* unmounted (safe to unplug);
    /// a plain folder is ejected logically (it never unmounts on its own).
    func ejectDrive(_ vr: VaultRecord) {
        guard driveKind(vr).isRealVolume else {
            ejectedDrives.insert(vr.id); persistEjected(); return   // folder: logical eject
        }
        let url = URL(fileURLWithPath: vr.rootPath)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? url
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)   // safe to unplug now
            driveDrift[vr.id] = nil                                    // its folder vanishes → not-present
        } catch {
            driveAlert("Couldn’t eject \((vr.rootPath as NSString).lastPathComponent)",
                       error.localizedDescription)
        }
    }

    func reconnectDrive(_ vr: VaultRecord) {
        ejectedDrives.remove(vr.id); persistEjected()
        cacheDriveKind(vr)
        if let drive = openVault(for: vr) { driftScan(drive) }   // re-scan just this drive
    }

    /// Forget a drive entirely: unregister it + drop its presence. The files on the drive are NOT
    /// touched; you can add it again later. Photos that lived only on it stop showing.
    func forgetDrive(_ vr: VaultRecord) {
        try? library?.catalog.unregisterVault(id: vr.id)
        ejectedDrives.remove(vr.id); persistEjected()
        driveDrift[vr.id] = nil
        // If the viewer is showing a photo that lived only on this drive, close it (it's now gone
        // from browse — leaving it open would strand the viewer's navigation).
        if let opened = openedItem, opened.vaultID == vr.id { openedItem = nil }
        reloadDrives()
        reloadCanonicalPresence()
        try? refreshQueries()
    }

    private func persistEjected() {
        UserDefaults.standard.set(Array(ejectedDrives), forKey: Self.ejectedDefaultsKey)
    }

    func isBackedUpOnCanonical(_ item: TimelineItem) -> Bool { canonicalPresence.contains(item.hash) }

    func addDriveViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Canonical Drive"
        panel.message = "Choose a drive or folder to hold your canonical library."
        guard panel.runModal() == .OK, let url = panel.url, let lib = library else { return }
        do {
            let vault = try Vault.openOrCreate(at: url, role: .canonical)
            // Accept a canonical or backup drive (a backup self-describes as `backup` and is a valid
            // library to add/adopt for browse). Refuse a folder that is one of the user's own LOCAL
            // source vaults — adopting it would diverge catalog/disk role and could make the engine
            // try to sync a vault onto itself.
            guard vault.descriptor.role != .local else {
                driveAlert("Can’t use this folder",
                    "“\(url.lastPathComponent)” is one of your local library folders, not a drive. Choose a drive or a folder dedicated to your canonical library.")
                return
            }
            // Already adopted? Same vault_id means it's the same drive.
            if durableVaults.contains(where: { $0.id == vault.descriptor.vaultID }) {
                driveAlert("Already added",
                    "“\(url.lastPathComponent)” is already one of your drives.")
                return
            }
            try lib.catalog.registerVault(id: vault.descriptor.vaultID,
                                          role: vault.descriptor.role.rawValue, rootPath: url.path)
            reloadDrives()
            if let vr = durableVaults.first(where: { $0.id == vault.descriptor.vaultID }) { cacheDriveKind(vr) }
            // A drive that carries a catalog-snapshot is adopted through a CONFIRMED prompt
            // (`adoptableDrive` → Adopt → `adoptDrive` imports assets+presence+thumbs, then verifies
            // vs the manifest). Leave its presence empty for now so the prompt can fire — seeding
            // presence here without `assets` would suppress the prompt AND leave a fresh Mac with an
            // empty drive (the browse query joins assets ⋈ vault_presence). A drive WITHOUT a snapshot
            // gets its presence populated immediately (browse from existing local assets).
            let hasSnapshot = FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".openphoto/catalog-snapshot/catalog.sqlite").path)
            if !hasSnapshot {
                try refreshCanonicalPresence(driveVault: vault)
            }
        } catch { driveAlert("Couldn’t add drive", error.localizedDescription) }
    }

    private func driveAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Build presence entries for a drive from its manifest, restricted to `hashes` when given.
    private func presenceEntries(forDrive drive: Vault, limitedTo hashes: Set<String>?) -> [VaultPresenceEntry] {
        let bases = (library?.vaults ?? []).map { $0.rootURL.lastPathComponent }
        let entries = (try? Manifest.read(from: drive.manifestURL)) ?? []
        return entries.compactMap { e in
            if let hs = hashes, !hs.contains(e.hash.stringValue) { return nil }
            let mac = DrivePathMap.driveToMacRelPath(e.path, sourceBasenames: bases)
            return VaultPresenceEntry(hash: e.hash.stringValue, relPath: mac,
                                      dirPath: (mac as NSString).deletingLastPathComponent,
                                      size: e.size, driveRelPath: e.path)
        }
    }

    /// Re-read a drive's manifest into vault_presence, then rebuild the badge cache as the
    /// union across all durable vaults (canonical + backups), so refreshing one drive never
    /// wipes another's badges.
    func refreshCanonicalPresence(driveVault: Vault) throws {
        guard let lib = library else { return }
        let entries = presenceEntries(forDrive: driveVault, limitedTo: nil)
        try lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID, entries: entries)
        reloadCanonicalPresence()
    }

    /// Rebuild `canonicalPresence` from the persisted catalog — union of every durable vault's
    /// (canonical + backup) presence set. Cheap; safe to call at library-open and after any sync.
    func reloadCanonicalPresence() {
        guard let lib = library else { return }
        var union = Set<String>()
        for vr in durableVaults {
            if let hs = try? lib.catalog.vaultPresenceHashes(forVault: vr.id) { union.formUnion(hs) }
        }
        canonicalPresence = union
    }

    func openVault(for vr: VaultRecord) -> Vault? {
        try? Vault.open(at: URL(fileURLWithPath: vr.rootPath))
    }

    /// A connected drive that carries a catalog-snapshot whose contents this Mac doesn't yet know
    /// (no vault_presence) — a candidate to adopt. nil if none.
    var adoptableDrive: VaultRecord? {
        guard let lib = library else { return nil }
        return durableVaults.first { vr in
            driveIsPresent(vr)
            && FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: vr.rootPath).appendingPathComponent(".openphoto/catalog-snapshot/catalog.sqlite").path)
            && ((try? lib.catalog.vaultPresenceHashes(forVault: vr.id))?.isEmpty ?? true)
        }
    }

    /// Photos a candidate drive's snapshot says it holds (snapshot.json asset_count) — for the prompt.
    func adoptablePhotoCount(_ vr: VaultRecord) -> Int {
        let url = URL(fileURLWithPath: vr.rootPath).appendingPathComponent(".openphoto/catalog-snapshot/snapshot.json")
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return meta["asset_count"] as? Int ?? 0
    }

    /// Adopt a drive: import its snapshot for instant browse, then verify against the manifest.
    func adoptDrive(_ vr: VaultRecord) async {
        guard let lib = library, let drive = openVault(for: vr) else { return }
        let cat = lib.catalog, thumbs = lib.thumbnails
        let bases = lib.vaults.map { $0.rootURL.lastPathComponent }
        await Task.detached(priority: .userInitiated) {
            _ = try? CatalogSnapshot.import(from: drive, into: cat, thumbnails: thumbs)
            try? CatalogSnapshot.verifyAdoption(drive: drive, into: cat, sourceBasenames: bases)
        }.value
        reloadCanonicalPresence()
        reloadDrives()
        try? refreshQueries()
    }

    /// Full-res URL for an item: local file, or the drive file when the drive is connected.
    func fullResURL(for item: TimelineItem) -> URL? {
        if item.driveRelPath == nil { return library?.absoluteURL(for: item) }
        // Drive-only: source from any connected durable drive holding the hash (canonical preferred),
        // not only the pinned vault — so a backup serves when the canonical is unplugged. Skip a drive
        // whose recorded copy is missing on disk and try the next.
        for drive in connectedDrivesCanonicalFirst() {
            guard let row = (try? library?.catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID))?
                    .first(where: { $0.hash == item.hash }) else { continue }
            let url = drive.absoluteURL(forRelativePath: row.driveRelPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func isDriveOnly(_ item: TimelineItem) -> Bool { item.driveRelPath != nil }

    // MARK: — Drift scan / verify / repairs

    /// Last drift report per drive (vaultID → report) — drives the row status line. Populated by
    /// auto-scan on connect and by every scan/verify/repair.
    private(set) var driveDrift: [String: DriftReport] = [:]

    /// Eligible pending deletions per connected drive (vaultID → entries). Drives the row
    /// indicator + both review surfaces. Recomputed whenever an eligibility input changes:
    /// on connect/auto-scan, after any delete/restore/evict (via refreshQueries), after sync,
    /// after propagation, and after any drift scan/repair/verify (which rewrites vault_presence).
    private(set) var drivePendingDeletions: [String: [PendingDeletion]] = [:]

    /// Photos on the Mac that aren't on each connected drive yet (a Mac->drive Sync would add them).
    /// Catalog-only; recomputed alongside drivePendingDeletions. Drives the "Updates to sync" status.
    private(set) var drivePendingSync: [String: Int] = [:]

    func refreshPendingDeletions() {
        guard let lib = library else { drivePendingDeletions = [:]; drivePendingSync = [:]; return }
        let queue = (try? lib.catalog.pendingDeletions()) ?? []
        let local = (try? lib.catalog.instanceHashes()) ?? []
        var out: [String: [PendingDeletion]] = [:]
        var pendingSync: [String: Int] = [:]
        for vr in durableVaults where driveIsPresent(vr) {
            let presence = (try? lib.catalog.vaultPresenceRows(forVault: vr.id)) ?? []
            let eligible = DeletionPropagator().eligible(queue: queue, localHashes: local, presence: presence)
            if !eligible.isEmpty { out[vr.id] = eligible }
            // Mac photos this drive doesn't hold yet → a Sync would add them.
            let behind = local.subtracting(presence.map(\.hash)).count
            if behind > 0 { pendingSync[vr.id] = behind }
        }
        drivePendingDeletions = out
        drivePendingSync = pendingSync
    }

    /// Move the selected drive copies into the drive's bin (off the main thread), then refresh
    /// presence/badges/queue/UI. Returns the propagation result so the caller can report how many
    /// moved vs. were left queued (a failed move stays queued for retry).
    @discardableResult
    func propagateDeletions(drive driveVault: Vault, selected: [PendingDeletion]) async -> DeletionPropagator.Result {
        guard let lib = library, !selected.isEmpty else { return DeletionPropagator.Result() }
        let macID = lib.vaults.first?.descriptor.vaultID ?? ""
        let catalog = lib.catalog
        let result = await Task.detached(priority: .userInitiated) {
            (try? DeletionPropagator().propagate(drive: driveVault, entries: selected,
                                                 macVaultID: macID, catalog: catalog))
                ?? DeletionPropagator.Result()
        }.value
        _ = driftScan(driveVault)        // re-derives presence + badges + drift from the updated manifest
        try? refreshQueries()            // also calls refreshPendingDeletions()
        return result
    }

    /// Undo one pending deletion: un-bin the photo locally (which dequeues it + its Live pair).
    func restorePending(_ e: PendingDeletion) async {
        guard let lib = library else { return }
        if let entry = (try? lib.binItems())?.first(where: { $0.item.hash == e.hash }) {
            try? await lib.restore(entry)
        } else {
            // File already restored/gone from the bin — just drop the intent.
            try? lib.catalog.dequeuePendingDeletion(hash: e.hash)
        }
        try? refreshQueries()
    }

    /// Run a fast drift scan, set this drive's presence to verified reality, refresh badges + status.
    @discardableResult
    func driftScan(_ driveVault: Vault) -> DriftReport {
        guard let lib = library else { return DriftReport() }
        var report = (try? DriftReconciler().scan(drive: driveVault)) ?? DriftReport()
        if let p = presenceService() {
            DriftReconciler().annotateRecoverability(&report, driveID: driveVault.descriptor.vaultID, presence: p)
        }
        try? lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID,
                                              entries: presenceEntries(forDrive: driveVault,
                                                                       limitedTo: report.presentHashes))
        reloadCanonicalPresence()
        driveDrift[driveVault.descriptor.vaultID] = report
        refreshPendingDeletions()   // vault_presence just changed → recompute eligibility (reconnect + drift-repair paths)
        return report
    }

    /// Verify every connected durable drive (off-main, with progress), annotate cross-set
    /// recoverability, update presence, and return each drive's report. Drives "Verify All Drives".
    func verifyAllConnected(progress: @escaping @Sendable (String, DriftProgress) -> Void)
        async -> [(vr: VaultRecord, report: DriftReport)] {
        guard let lib = library else { return [] }
        var out: [(VaultRecord, DriftReport)] = []
        for vr in durableVaults where driveIsPresent(vr) {
            cacheDriveKind(vr)
            guard let drive = openVault(for: vr) else { continue }
            let name = (vr.rootPath as NSString).lastPathComponent
            let report = await Task.detached(priority: .userInitiated) {
                (try? DriftReconciler().verify(drive: drive) { p in progress(name, p) }) ?? DriftReport()
            }.value
            var enriched = report
            if let p = presenceService() {
                DriftReconciler().annotateRecoverability(&enriched, driveID: vr.id, presence: p)
            }
            try? lib.catalog.replaceVaultPresence(vaultID: vr.id,
                entries: presenceEntries(forDrive: drive, limitedTo: enriched.presentHashes))
            driveDrift[vr.id] = enriched
            out.append((vr, enriched))
        }
        reloadCanonicalPresence()
        refreshPendingDeletions()
        return out
    }

    /// Repair one finding from the best connected good copy: corrupt → repairCorrupt (bin-then-
    /// replace), missing → restore. Off-main. Returns whether it succeeded.
    @discardableResult
    func repairFinding(_ finding: DriftFinding, on driveVault: Vault) async -> Bool {
        guard let hash = finding.recordedHash,
              let source = goodCopyURL(forHash: hash, excluding: driveVault.descriptor.vaultID)
        else { return false }
        return await Task.detached(priority: .userInitiated) {
            do {
                switch finding.kind {
                case .corrupt:
                    try DriftReconciler().repairCorrupt(relPath: finding.relPath,
                        expectedHash: hash, from: source, on: driveVault)
                case .missing:
                    try DriftReconciler().restore(relPath: finding.relPath,
                        expectedHash: hash, from: source, on: driveVault)
                default: return false   // changed/unknown aren't auto-repaired
                }
                return true
            } catch { return false }
        }.value
    }

    /// Repair every recoverable corrupt+missing finding in `report` on `driveVault`, then one
    /// re-scan. Returns the refreshed report.
    @discardableResult
    func repairAllRecoverable(_ report: DriftReport, on driveVault: Vault) async -> DriftReport {
        let targets = (report.corrupt + report.missing).filter {
            if case .recoverable = $0.recoverability { return true } else { return false }
        }
        for f in targets { _ = await repairFinding(f, on: driveVault) }
        return driftScan(driveVault)
    }

    /// Full integrity check (slow); same presence/badge/status refresh as driftScan.
    func verifyIntegrity(_ driveVault: Vault,
                         progress: @escaping @Sendable (DriftProgress) -> Void) async -> DriftReport {
        guard let lib = library else { return DriftReport() }
        let report = await Task.detached(priority: .userInitiated) {
            (try? DriftReconciler().verify(drive: driveVault) { p in progress(p) }) ?? DriftReport()
        }.value
        var enriched = report
        if let p = presenceService() {
            DriftReconciler().annotateRecoverability(&enriched, driveID: driveVault.descriptor.vaultID, presence: p)
        }
        try? lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID,
                                              entries: presenceEntries(forDrive: driveVault,
                                                                       limitedTo: enriched.presentHashes))
        reloadCanonicalPresence()
        driveDrift[driveVault.descriptor.vaultID] = enriched
        refreshPendingDeletions()   // presence just changed → keep the deletions indicator honest after Verify
        return enriched
    }

    /// Background fast-scan of every connected durable drive (canonical + backups) — keeps badges +
    /// the status line honest automatically (at library-open and whenever a volume mounts), no manual Check.
    func autoScanConnectedDrives() async {
        for vr in durableVaults where driveIsPresent(vr) {
            cacheDriveKind(vr)
            guard let drive = openVault(for: vr) else { continue }
            // Reconcile any structural folder ops queued while this drive was offline BEFORE the
            // drift scan reads its (path-keyed) structure — so a folder that moved/was created on
            // the Mac is mirrored here first and the comparison never sees it as drift/duplication.
            await applyPendingFolderOps(forDriveID: vr.id, driveVault: drive)
            let scanned = await Task.detached(priority: .utility) {
                (try? DriftReconciler().scan(drive: drive)) ?? DriftReport()
            }.value
            var report = scanned
            if let p = presenceService() {
                DriftReconciler().annotateRecoverability(&report, driveID: vr.id, presence: p)
            }
            try? library?.catalog.replaceVaultPresence(vaultID: vr.id,
                                                       entries: presenceEntries(forDrive: drive,
                                                                                limitedTo: report.presentHashes))
            driveDrift[vr.id] = report
        }
        reloadCanonicalPresence()
        refreshPendingDeletions()
    }

    @discardableResult
    func adoptDriftFile(relPath: String, on driveVault: Vault) -> DriftReport {
        _ = try? DriftReconciler().adopt(relPath: relPath, on: driveVault)
        Task { await ingestAdopted([relPath], on: driveVault) }
        return driftScan(driveVault)
    }

    @discardableResult
    func acknowledgeGone(relPath: String, on driveVault: Vault) -> DriftReport {
        try? DriftReconciler().acknowledgeGone(relPath: relPath, on: driveVault)
        return driftScan(driveVault)
    }

    /// Restore a missing file from its best available good copy; returns the refreshed report.
    @discardableResult
    func restoreDriftFile(_ finding: DriftFinding, on driveVault: Vault) -> DriftReport {
        restoreOne(finding, on: driveVault)
        return driftScan(driveVault)
    }

    /// Adopt every unknown file in one pass, then a single re-scan.
    @discardableResult
    func adoptAll(_ relPaths: [String], on driveVault: Vault) -> DriftReport {
        for p in relPaths { _ = try? DriftReconciler().adopt(relPath: p, on: driveVault) }
        Task { await ingestAdopted(relPaths, on: driveVault) }
        return driftScan(driveVault)
    }

    private func ingestAdopted(_ relPaths: [String], on driveVault: Vault) async {
        guard let lib = library else { return }
        let ingest = CatalogIngest(catalog: lib.catalog, thumbnails: lib.thumbnails)
        let bases = lib.vaults.map { $0.rootURL.lastPathComponent }
        for p in relPaths { try? await ingest.ingestDriveFile(relPath: p, on: driveVault, sourceBasenames: bases) }
        try? refreshQueries()    // bring the new drive-only item into the timeline/folders
        pokeDerivation()
    }

    /// Restore every recoverable missing file in one pass, then a single re-scan.
    @discardableResult
    func restoreAllRecoverable(_ findings: [DriftFinding], on driveVault: Vault) -> DriftReport {
        for f in findings { restoreOne(f, on: driveVault) }
        return driftScan(driveVault)
    }

    private func restoreOne(_ finding: DriftFinding, on driveVault: Vault) {
        guard let hash = finding.recordedHash,
              let source = goodCopyURL(forHash: hash, excluding: driveVault.descriptor.vaultID) else { return }
        do {
            try DriftReconciler().restore(relPath: finding.relPath, expectedHash: hash,
                                          from: source, on: driveVault)
        } catch { NSLog("restore failed: \(error)") }
    }

    /// A reachable on-disk file with `hash` outside `driveID`: prefer the Mac's local copy, else
    /// any currently-connected durable drive (canonical or backup) that holds it. (restore re-verifies the bytes, so
    /// even a drive copy that is itself rotten fails safely rather than spreading corruption.)
    private func goodCopyURL(forHash hash: String, excluding driveID: String) -> URL? {
        guard let lib = library else { return nil }
        // 1. A local Mac instance.
        if let inst = (try? lib.catalog.instances(forHash: hash))?.first(where: { $0.vaultID != driveID }),
           let vault = lib.vault(id: inst.vaultID) {
            let url = vault.absoluteURL(forRelativePath: inst.relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // 2. Another connected durable drive that holds the hash (look up its path in its manifest).
        for vr in durableVaults where vr.id != driveID && driveIsPresent(vr) {
            guard let drive = openVault(for: vr),
                  let entry = (try? Manifest.read(from: drive.manifestURL))?
                      .first(where: { $0.hash.stringValue == hash }) else { continue }
            let url = drive.absoluteURL(forRelativePath: entry.path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    var configuredRoots: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.rootsDefaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    /// The one configured local library folder (single-root model), or nil on first run.
    var configuredRoot: URL? { configuredRoots.first }

    func openLibrary(roots: [URL]) {
        closeLibrary()   // tear down any previously-open library so this can be called to switch
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.rootsDefaultsKey)
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenPhoto")
            library = try LibraryService(vaultRoots: roots, appSupportDir: appSupport)
            startWatcher(roots: roots)
            // Load drives from the persisted catalog BEFORE the device watcher starts:
            // knownVaultIDs (below) reads durableVaults, and start() classifies
            // already-mounted volumes synchronously.
            reloadDrives()
            // Every vault ID that is OURS — a mounted vault outside this set is someone
            // else's drive and surfaces as a read-only foreign import source.
            // ORDERING: must be assigned (and durableVaults populated via reloadDrives)
            // before deviceWatcher.start() — start() scans mounted volumes immediately,
            // and with the default `{ [] }` the user's own registered drive would
            // misclassify as foreign until the next mount/unmount event.
            deviceWatcher.knownVaultIDs = { [weak self] in
                guard let self else { return [] }
                var ids = Set(self.library?.vaults.map(\.descriptor.vaultID) ?? [])
                ids.formUnion(self.durableVaults.map(\.id))
                return ids
            }
            deviceWatcher.start()
            deviceWatcher.openedDeviceRemoved = { [weak self] id in
                if self?.openedDevice?.id == id { self?.openedDevice = nil }
            }
            // Phones (ImageCaptureCore): re-verify prior sends READ-ONLY when a camera connects.
            // Volumes/SD re-verify via onVolumesChanged below (beside autoScanConnectedDrives).
            deviceWatcher.deviceConnected = { [weak self] _ in
                Task { @MainActor in await self?.reverifySentToConnectedDevices() }
            }
            try? library?.catalog.reconcileEmbeddingModel(current: EmbedStage().modelID)
            // One-time face re-derivation when the recognition model changes (e.g. after this update):
            // drops stale auto faces + face jobs so every photo re-embeds with the current model.
            // Named people are kept. The drain below repopulates the People view.
            _ = try? library?.catalog.reconcileFaceModel(current: FaceEmbedder.modelVersion)
            Task { await rescan(); pokeDerivation() }
            // Badge presence from the persisted catalog (drives were loaded above), then
            // auto-scan connected drives so badges + status reflect reality without a
            // manual Check. Re-scan on any volume mount/unmount too.
            reloadCanonicalPresence()
            // Load locked-folder state: persist set, apply to catalog, start locked (always re-lock on open).
            if let root = library?.vaults.first?.rootURL {
                lockedFolders = LockedFolderStore.load(libraryRoot: root)
                try? library?.catalog.applyLockedFolders(lockedFolders)
                try? library?.catalog.replaceAlbums(AlbumStore.loadAll(libraryRoot: root))
            } else {
                lockedFolders = []
            }
            library?.catalog.revealLocked = false
            lockedRevealed = false
            refreshAlbums()
            if finderTagSyncEnabled { syncFinderTagsNow() }   // initial Finder-tag reconcile pass
            deviceWatcher.onVolumesChanged = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reloadDrives()
                    // A peeked drive that vanished (ejected/unplugged) → close the peek. Nothing was
                    // persisted, so this just discards the throwaway temp dir.
                    if let ctx = self.peekContext,
                       !FileManager.default.fileExists(atPath: ctx.root.path) {
                        self.endQuickView()
                    }
                    await self.autoScanConnectedDrives()
                    await self.reverifySentToConnectedDevices()
                }
            }
            Task { await autoScanConnectedDrives(); await reverifySentToConnectedDevices() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Tear the open library down to the pre-open state (back to the Welcome screen). Safe to call
    /// when nothing is open. Does NOT touch the persisted root or any files — purely in-memory.
    func closeLibrary() {
        watcher?.stop(); watcher = nil
        deviceWatcher.stop()
        library = nil
        openedItem = nil; openedDevice = nil; peekContext = nil
        sections = []; flatItems = []; folderTree = []; binEntries = []
        selectedFolder = nil; selection = .timeline
        refreshToken &+= 1

        // MUST-FIX: reset cached objects that would otherwise stay bound to the old library.
        _importRegistry = nil
        _sendRegistry = nil
        _deviceRegistry = nil
        semanticIndex = nil
        semanticIndexDirty = true
        derivationTask?.cancel(); derivationTask = nil

        // Defense-in-depth: clear per-library state so a subsequent open starts clean.
        reverified = [:]
        durableVaults = []
        canonicalPresence = []
        driveDrift = [:]
        drivePendingDeletions = [:]
        drivePendingSync = [:]
        people = []
        suggestedClusters = []
        cullGroups = []
        searchResults = []
        openedPerson = nil
        viewerItems = []
        expandedFolders = []
        lockedFolders = []
        lockedRevealed = false
        albums = []
        selectedAlbumID = nil

        // MUST-FIX: clear DeviceWatcher closures that close over the old library.
        deviceWatcher.knownVaultIDs = { [] }
        deviceWatcher.onVolumesChanged = nil
        deviceWatcher.deviceConnected = nil
        deviceWatcher.openedDeviceRemoved = nil
    }

    /// Switch the library to a different single root: forget the old local vault's catalog rows
    /// (rebuildable — files and XMP sidecars are untouched), then open the new folder live.
    func changeRoot(to newRoot: URL) {
        if let current = configuredRoot, current.standardizedFileURL == newRoot.standardizedFileURL {
            return   // same folder — no-op
        }
        if let lib = library {
            for v in lib.vaults {
                try? lib.catalog.purgeLocalVault(id: v.descriptor.vaultID)
            }
        }
        openLibrary(roots: [newRoot])
    }

    /// Return to the Welcome screen and forget the configured root (used by "Close Library").
    func closeLibraryAndForgetRoot() {
        closeLibrary()
        UserDefaults.standard.removeObject(forKey: Self.rootsDefaultsKey)
    }

    func rescan() async {
        guard let library else { return }
        // Coalesce: if a scan is already running, note that the library changed again so the
        // in-flight scan loops once more when it finishes. A watcher event that lands mid-scan
        // (the tail of a large copy/import) would otherwise be dropped, leaving counts stale.
        // Also defer while a reorg is mutating the manifest — the scan runs off-main (Task.detached
        // in scanAll), so an ungated scan would read-modify-write the manifest concurrently with the
        // reorg's own rewrite and silently revert it (S03). The deferred run is honoured below.
        if scanning || reorganizing { rescanRequested = true; return }
        scanning = true
        defer { scanning = false; scanProgress = nil; wakeLibraryMutationWaiters() }
        repeat {
            rescanRequested = false
            do {
                try await library.scanAll { [weak self] p in
                    Task { @MainActor in if p.total > 50 { self?.scanProgress = p } }
                }
                try refreshQueries()
                pokeDerivation()
            } catch {
                NSAlert(error: error).runModal()
                break
            }
        } while rescanRequested
    }

    /// Take exclusive access to the manifest/catalog for a reorg: await any in-flight scan or other
    /// reorg, then mark `reorganizing` so a new scan defers (see `rescan()`). Continuation-based, so
    /// it doesn't busy-spin the main actor while a multi-second scan finishes. Always pair with
    /// `endReorg()`. Serializes reorgs against the background scan (S03) and against each other (S25).
    func beginReorg() async {
        while scanning || reorganizing {
            await withCheckedContinuation { libraryMutationWaiters.append($0) }
        }
        reorganizing = true
    }

    /// Release the reorg lock and wake whoever is waiting (a queued scan or the next reorg).
    func endReorg() {
        reorganizing = false
        wakeLibraryMutationWaiters()
    }

    private func wakeLibraryMutationWaiters() {
        let waiters = libraryMutationWaiters
        libraryMutationWaiters = []
        for w in waiters { w.resume() }
    }

    private var derivationTask: Task<Void, Never>?
    /// Stage registry: each stage's whole pending set is drained in order, with bounded concurrency
    /// inside `drainDerivation`. Order = perceived value: faces (People) + semantic (search) first,
    /// then the cheap catalog-only/quick stages, then OCR last (expensive Vision pass, niche text
    /// search) — so on a slow machine the visible features fill in early instead of after hours.
    private let derivationStages: [any DerivationStage] =
        [FaceDerivationStage(), EmbedStage(), GeocodeStage(), PHashStage(), OCRDerivationStage()]

    /// Kick the background derivation runner if it isn't already draining. Called at library-open
    /// and after anything that adds assets (scan/ingest). Cheap + idempotent.
    func pokeDerivation() {
        guard derivationTask == nil, library != nil else { return }
        derivationTask = Task { [weak self] in
            await self?.drainDerivation()
            self?.derivationTask = nil
        }
    }

    /// Drain every pending job for each stage in the registry (low priority, inference off-main,
    /// yielding between items). Pulls each stage's WHOLE pending set up front so an unreachable
    /// newest asset can't block older reachable ones (the 4.1 starvation lesson). Unreachable
    /// assets are skipped (retried on the next poke when their drive connects), not marked failed.
    private func drainDerivation() async {
        guard let lib = library else { return }
        // Bounded concurrency: analyse several items at once for a big speedup (especially on Intel,
        // which has no Neural Engine), while capping in-flight decodes so peak memory stays bounded —
        // indexing has OOM'd before. The heavy stages (faces/embed/OCR) already wrap their decode in
        // autorelease pools; we additionally limit how many run at once. Conservative cap on purpose.
        // Bounded-concurrency driver (`boundedDrain`, unit-tested in BoundedDrainTests). The per-stage
        // decoders are now autorelease-pooled, so memory stays bounded (~250 MB/slot); cap at 8
        // (≈ physical cores on a hyperthreaded i9, where activeProcessorCount reports the 16 logical).
        let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 8))
        for stage in derivationStages {
            if Task.isCancelled { break }
            // If the stage's backing resources (e.g. the embed model package) are absent on this
            // machine, skip the whole stage — leave its jobs pending so they resume once the model
            // ships. Do NOT mark anything failed; that would permanently exclude jobs from retries.
            guard stage.isAvailable else { continue }
            let pending = (try? lib.catalog.pendingDerivation(stage: stage.id)) ?? []
            guard !pending.isEmpty else { continue }
            let catalog = lib.catalog
            let stageID = stage.id
            let needsFile = stage.needsFile
            derivationStageName = Self.analysisActivity(forStageID: stage.id)
            derivationProgress = combinedProgress()
            var index = 0, completed = 0
            await boundedDrain(limit: maxConcurrent, next: {
                // Resolve the next reachable item just-in-time on the main actor (cheaper than
                // resolving the whole pending set up front, which would stall the main thread). Items
                // whose bytes are currently unreachable (e.g. a drive is ejected) are skipped and left
                // pending for a later poke; GeocodeStage needsFile == false, so a drive-only asset
                // still gets geocoded.
                while index < pending.count {
                    let hash = pending[index]; index += 1
                    let url = self.goodCopyURL(forHash: hash, excluding: "")   // "" excludes no vault
                    if url == nil && needsFile { continue }
                    let runURL = url ?? URL(fileURLWithPath: "/")              // geocode ignores url
                    return { @Sendable in
                        let ok = await stage.run(hash: hash, url: runURL, catalog: catalog)
                        if ok { try? catalog.markDerived(hash: hash, stage: stageID) }
                        else { try? catalog.markDerivationFailed(hash: hash, stage: stageID) }
                    }
                }
                return nil
            }, onComplete: {
                completed += 1
                // Progressive People refresh while faces re-derive so unassigned faces appear as
                // they're found; the !facesLoading guard self-throttles the O(n²) clustering.
                if stageID == FaceStage.id, completed % 200 == 0, !self.facesLoading { self.loadPeople() }
                // Refresh the progress line periodically (combinedProgress reads the DB).
                if completed % 4 == 0 { self.derivationProgress = self.combinedProgress() }
            })
            derivationProgress = combinedProgress()
        }
        derivationProgress = nil
        derivationStageName = nil
        semanticIndexDirty = true   // embeddings may have grown → refresh the in-memory index
        geocodeDirty = true         // geocoded places may have grown → inspector picks up new rows
        facesDirty = true
        loadPeople()                // final refresh so People reflects every newly-derived face
    }

    /// Combined remaining work across all stages (sidebar shows the sum).
    /// Only includes stages whose backing resources are available — unavailable stages are skipped
    /// by the runner and their pending jobs won't move, so adding them would inflate the total.
    private func combinedProgress() -> (done: Int, total: Int)? {
        guard let lib = library else { return nil }
        var done = 0, total = 0
        for stage in derivationStages where stage.isAvailable {
            if let p = try? lib.catalog.derivationProgress(stage: stage.id) {
                done += p.done; total += p.total
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Friendly name for the analysis stage currently draining, shown in the sidebar so the user
    /// can see what the on-device analysis is doing (faces, then search, …).
    private static func analysisActivity(forStageID id: String) -> String {
        switch id {
        case "faces":   return "faces"
        case "embed":   return "search"
        case "geocode": return "places"
        case "phash":   return "duplicates"
        case "ocr":     return "text"
        default:        return "photos"
        }
    }

    // MARK: — Locked Folder Actions

    func isFolderLocked(_ dirPath: String) -> Bool { lockedFolders.contains(dirPath) }

    /// Add a folder to the locked set. No Touch ID needed to ADD a lock.
    func lockFolder(_ dirPath: String) {
        guard !lockedFolders.contains(dirPath),
              let root = library?.vaults.first?.rootURL else { return }
        lockedFolders.append(dirPath)
        try? LockedFolderStore.save(lockedFolders, libraryRoot: root)
        try? library?.catalog.applyLockedFolders(lockedFolders)
        refreshAfterLockChange()
    }

    /// Remove a folder from the locked set — requires the session to be revealed (you must be
    /// authenticated to manage locks). If not revealed, trigger reveal first.
    func unlockFolder(_ dirPath: String) {
        guard lockedRevealed else {
            Task { if await revealLockedContent() { unlockFolder(dirPath) } }
            return
        }
        guard let root = library?.vaults.first?.rootURL else { return }
        lockedFolders.removeAll { $0 == dirPath }
        try? LockedFolderStore.save(lockedFolders, libraryRoot: root)
        try? library?.catalog.applyLockedFolders(lockedFolders)
        refreshAfterLockChange()
    }

    /// Touch ID → reveal locked content for the session. Returns whether it succeeded.
    @discardableResult
    func revealLockedContent() async -> Bool {
        guard await BiometricGate.authenticate(reason: "Show your hidden folders") else { return false }
        library?.catalog.revealLocked = true
        lockedRevealed = true
        refreshAfterLockChange()
        return true
    }

    /// Re-hide locked content.
    func relock() {
        library?.catalog.revealLocked = false
        lockedRevealed = false
        refreshAfterLockChange()
    }

    /// Refresh every browse surface after the locked set / reveal state changes.
    private func refreshAfterLockChange() {
        try? refreshQueries()   // timeline / folders / bin
        loadPeople()            // faces (catalog face queries also honour the locked gate)
        refreshToken += 1       // nudge map markers, search results, inspector, dependent views
    }

    func refreshQueries() throws {
        guard let library else { return }
        sections = try library.timelineSections(grouping: grouping, videoOnly: videoOnly)
        flatItems = sections.flatMap(\.items)
        folderTree = try library.folderTree(videoOnly: videoOnly)
        if expandedFolders.isEmpty && !folderTree.isEmpty {
            var paths: Set<String> = []
            func collect(_ nodes: [FolderNode]) {
                for n in nodes { paths.insert(n.path); collect(n.children) }
            }
            collect(folderTree)
            expandedFolders = paths
        }
        binEntries = try library.binItems()
        refreshPendingDeletions()
        refreshToken += 1
    }

    /// PresenceService over the current registries, if a library is open.
    private func presenceService() -> PresenceService? {
        guard let library, let imports = importRegistry,
              let sends = sendRegistry, let devices = deviceRegistry else { return nil }
        return PresenceService(catalog: library.catalog, imports: imports, sends: sends,
                               devices: devices, reverified: reverified)
    }

    /// Known locations of a photo (This Mac / phones / SD cards) for the inspector.
    func locations(for item: TimelineItem) -> [Location] {
        presenceService()?.locations(forHash: item.hash) ?? []
    }

    /// How many of `items` appear to exist only on this Mac (no confirmed/believed
    /// copy elsewhere). No presence info yet → treat all as only-copies.
    func onlyCopyCount(_ items: [TimelineItem]) -> Int {
        guard let presence = presenceService() else { return Set(items.map(\.hash)).count }
        return presence.onlyOnThisMac(hashes: items.map(\.hash)).count
    }

    /// Items in `items` that are drive-only AND whose drive is currently connected (rehydratable).
    func rehydratableItems(_ items: [TimelineItem]) -> [TimelineItem] {
        items.filter { item in
            item.driveRelPath != nil &&
            durableVaults.contains { $0.id == item.vaultID && driveIsPresent($0) }
        }
    }

    @discardableResult
    func rehydrate(_ items: [TimelineItem]) async -> RehydrateOutcome {
        guard let lib = library else { return RehydrateOutcome() }
        let drives = connectedDrivesCanonicalFirst()
        let outcome = await Task.detached(priority: .userInitiated) {
            (try? await lib.rehydrate(items, connectedCanonical: drives)) ?? RehydrateOutcome()
        }.value
        for vr in durableVaults where driveIsPresent(vr) { if let v = openVault(for: vr) { _ = driftScan(v) } }
        try? refreshQueries()
        return outcome
    }

    /// Evict a selection (verified by default) — release verified local originals to the Trash.
    /// Runs the re-hash + trash off the main thread; refreshes queries + presence afterward.
    @discardableResult
    func evict(_ items: [TimelineItem], mode: EvictMode = .verified) async -> EvictOutcome {
        guard let lib = library else { return EvictOutcome() }
        let drives = connectedDrivesCanonicalFirst()
        let presence = canonicalPresence
        var outcome = EvictOutcome()
        do {
            outcome = try await Task.detached(priority: .userInitiated) {
                try await lib.evict(items, mode: mode, connectedCanonical: drives, canonicalPresence: presence)
            }.value
        } catch {
            // Files may already be in the Trash but the bookkeeping rescan threw — reconcile each
            // touched local vault so the catalog never shows a trashed file as still-local.
            for vid in Set(items.filter { $0.driveRelPath == nil }.map(\.vaultID)) {
                try? await lib.rescan(vaultID: vid)
            }
        }
        // driftScan re-derives canonical presence first; refreshQueries then reads the fresh state.
        for vr in durableVaults where driveIsPresent(vr) { if let v = openVault(for: vr) { _ = driftScan(v) } }
        try? refreshQueries()
        return outcome
    }

    /// Delete a selection: move to the bin AND record the intent so it can be propagated to
    /// drives (via Review Deletions). Refreshes all queries — including the pending-deletions
    /// indicator. Unlike evict, this is how a removal reaches the canonical drive.
    /// Delete a CONTENT (timeline/viewer semantic): bin EVERY instance of each item's hash — the photo
    /// and all its folder copies. Folder-grid and Duplicates deletes bin a single file via `delete`.
    func deletePhotos(_ items: [TimelineItem]) async {
        guard let library else { return }
        let ids = Set(items.flatMap { it -> [String] in
            let insts = (try? library.catalog.instances(forHash: it.hash)) ?? []
            return insts.isEmpty ? [it.instanceID] : insts.map { $0.vaultID + "|" + $0.relPath }
        })
        let all = (try? library.catalog.items(instanceIDs: Array(ids))) ?? []
        await delete(all.isEmpty ? items : all)
    }

    func delete(_ items: [TimelineItem]) async {
        guard let library else { return }
        // Captured BEFORE the delete: asset hashes (incl. Live partners) drive the bin-restore
        // undo; count is the user-facing photo count for the menu label.
        let hashes = items.flatMap { [$0.hash] + ($0.livePairHash.map { [$0] } ?? []) }
        let count = items.count
        do {
            _ = try await library.delete(items)
            recordUndo(.deletePhotos(hashes: hashes, count: count))
            try refreshQueries()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Rename via the inspector — wraps LibraryService.rename and records the undo.
    func rename(_ item: TimelineItem, to newName: String) async {
        guard let library else { return }
        let dir = (item.relPath as NSString).deletingLastPathComponent
        let oldName = (item.relPath as NSString).lastPathComponent
        let newRel = dir.isEmpty ? newName : dir + "/" + newName
        do {
            try await library.rename(item, to: newName)
            recordUndo(.rename(vaultID: item.vaultID, relPath: newRel, oldName: oldName))
            try refreshQueries()
        } catch { NSAlert(error: error).runModal() }
    }

    /// Remove the open photo, then advance the viewer to the next one (or close it if it was the
    /// last). Shared by the viewer's keyboard delete and the inspector's Delete/Evict so they
    /// behave identically — keep culling without leaving the viewer. `removal` performs the actual
    /// bin operation (delete or evict) on the previously-open item in the background.
    func removeOpenedItem(using removal: @escaping ([TimelineItem]) async -> Void) {
        guard let item = openedItem else { return }
        if let i = flatItems.firstIndex(where: { $0.instanceID == item.instanceID }),
           flatItems.indices.contains(i + 1) {
            openedItem = flatItems[i + 1]      // advance to the next photo (current list, pre-removal)
        } else {
            openedItem = nil                    // was the last (or not found) → close the viewer
        }
        Task { await removal([item]) }
    }

    /// The connected device we can currently send to, if any. Cameras (AirDrop)
    /// are listed first by DeviceWatcher, so a connected iPhone is preferred.
    func connectedSendTarget() -> ConnectedDevice? {
        deviceWatcher.devices.first { sendDestination(for: $0) != nil }
    }

    /// All connected devices that can receive a send (phones via AirDrop, volumes via copy).
    func connectedSendTargets() -> [ConnectedDevice] {
        deviceWatcher.devices.filter { sendDestination(for: $0) != nil }
    }

    /// Local file URLs for the selected items, for the macOS system Share sheet (ShareLink).
    /// Drive-only assets (no local copy) are skipped — there's nothing on this Mac to share.
    func localFileURLs(for items: [TimelineItem]) -> [URL] {
        items.compactMap { item -> URL? in
            guard item.driveRelPath == nil, let vault = library?.vault(id: item.vaultID) else { return nil }
            return vault.absoluteURL(forRelativePath: item.relPath)
        }
    }

    /// On-connect re-verify verdicts, keyed "<destinationKey>|<hash>". Rebuildable in-memory cache
    /// (re-derived on every device connect) — never persisted, no catalog table.
    private var reverified: [String: ReverifyVerdict] = [:]

    /// On device/volume connect, re-enumerate each connected SEND target READ-ONLY and reconcile its
    /// sends.jsonl entries against what's actually there now — so the inspector Locations "sent to
    /// <device>" indicator becomes "on this device (confirmed)" or downgrades to "no longer on the
    /// device". Never writes to the device (only enumeratePresent(), never send()).
    func reverifySentToConnectedDevices() async {
        guard let sends = sendRegistry else { return }
        for device in connectedSendTargets() {
            guard let dest = sendDestination(for: device) else { continue }
            let entries = sends.entries(forDestinationKey: dest.destinationKey)
            guard !entries.isEmpty else { continue }   // nothing was ever sent here → skip
            // Heavy/IO enumeration off the @MainActor. Distinguish "couldn't enumerate" (throw →
            // leave prior verdicts) from a real empty device (legitimately marks sends .gone).
            let enumeration = await Task.detached(priority: .utility) {
                try await dest.enumeratePresent()   // READ-ONLY — never send()
            }.result
            guard let present = try? enumeration.get() else { continue }
            let verdicts = SendReverifier().reconcile(entries: entries, present: present)
            for (hash, verdict) in verdicts { reverified["\(dest.destinationKey)|\(hash)"] = verdict }
        }
        try? refreshQueries()   // re-render the inspector/panel against the updated cache
    }

    /// Build a SendDestination for a connected device: AirDrop for an iPhone,
    /// direct copy for a volume.
    func sendDestination(for device: ConnectedDevice) -> (any SendDestination)? {
        switch device {
        case .volume(_, let name, let url):
            return VolumeCopyDestination(volumeRoot: url, displayName: name)
        case .camera:
            guard let cam = deviceWatcher.source(for: device) as? CameraSource else { return nil }
            return AirDropDestination(camera: cam)
        case .photosLibrary, .takeout, .appleExport, .foreignVault:
            return nil   // import-only sources — never send/free-up targets
        }
    }

    /// Split a selection into what can be sent now (local files + connected-drive files) and what
    /// can't (drive-only items whose drive is unplugged), so the send sheet can warn before sending.
    func sendPlan(for items: [TimelineItem]) -> SendSourcePlan {
        guard let library else { return SendSourcePlan(sendable: [], unreachable: []) }
        let connectedDrives = connectedDrivesCanonicalFirst()
        let driveNames = Dictionary(durableVaults.map { ($0.id, ($0.rootPath as NSString).lastPathComponent) },
                                    uniquingKeysWith: { first, _ in first })
        return library.resolveSendSources(items, connectedDrives: connectedDrives, driveNames: driveNames)
    }

    /// Send already-resolved items to a connected device, reporting progress. Returns the result.
    func send(_ sendItems: [SendItem], to device: ConnectedDevice,
              progress: @escaping @Sendable (SendProgress) -> Void) async -> SendEngine.Result? {
        guard let library, let vault = library.vaults.first,
              let sends = sendRegistry, let devices = deviceRegistry,
              let destination = sendDestination(for: device) else { return nil }
        let engine = SendEngine(library: library, sends: sends, devices: devices)
        let result = await engine.run(destination: destination, items: sendItems, vault: vault, progress: progress)
        try? refreshQueries()
        return result
    }

    private func startWatcher(roots: [URL]) {
        watcher = FolderWatcher(paths: roots.map(\.path)) { [weak self] in
            Task { @MainActor in await self?.rescan() }
        }
        watcher?.start()
    }

    // MARK: - ML availability

    /// Recompute `mlStatus` from the Core registry snapshot. Called on init and on every
    /// `MLAvailability.didChange`.
    func refreshMLStatus() {
        let snap = MLAvailability.shared.snapshot()
        var next: [MLCapability: MLStatus] = [:]
        for cap in MLCapability.allCases { next[cap] = mlCapabilityStatus(cap, from: snap) }
        mlStatus = next
    }

    init() {
        refreshMLStatus()
        // Observer token intentionally not stored: AppState is process-lifetime (the root @State),
        // so it never deinits and never needs to unregister. `[weak self]` keeps it leak-safe anyway.
        NotificationCenter.default.addObserver(
            forName: MLAvailability.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMLStatus() }
        }
    }
}
