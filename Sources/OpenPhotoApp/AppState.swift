import SwiftUI
import OpenPhotoCore

typealias Scanner = OpenPhotoCore.Scanner   // Foundation.Scanner collision

enum SidebarItem: String, Hashable, CaseIterable {
    case timeline, folders, people, map, search, drives, tidyUp, bin
    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .folders: "Folders"
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
    var scanning = false
    var refreshToken = 0
    /// Bumped after a per-photo move so the folder grid clears its (now-stale) selection.
    var photoMoveToken = 0
    var grouping: TimelineGrouping = {
        let raw = UserDefaults.standard.string(forKey: "timelineGrouping") ?? ""
        return TimelineGrouping(rawValue: raw) ?? .day
    }() {
        didSet {
            UserDefaults.standard.set(grouping.rawValue, forKey: "timelineGrouping")
        }
    }
    var videoOnly: Bool = UserDefaults.standard.bool(forKey: "videoOnly") {
        didSet { UserDefaults.standard.set(videoOnly, forKey: "videoOnly") }
    }
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

    /// When Finder sync is on, reconcile a tag edit with Finder (writes Finder + baseline) and return
    /// the merged set to persist; otherwise return the user's set unchanged.
    func tagsForSave(item: TimelineItem, proposed: [String]) -> [String] {
        guard finderTagSyncEnabled, let lib = library else { return proposed }
        return (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: proposed)) ?? proposed
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
                let merged = (try? lib.reconcileFinderTags(forHash: item.hash, proposedTags: current)) ?? current
                if Set(merged) != Set(current) {
                    try? lib.updateMetadata(for: item, rating: item.rating, favorite: item.favorite,
                                            caption: item.caption, tags: merged)
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
    /// Non-nil → the People view shows this person's detail grid. Lifted out of the view so the
    /// inspector's "In this image" section can deep-link straight to a person.
    var openedPerson: PersonRow?
    var facesLoading = false
    private var facesDirty = true
    private var geocodeDirty = true
    /// Cosine-distance threshold for suggesting clusters (tuned default; an adjustable slider is
    /// optional future polish).
    private let faceClusterThreshold = 0.4

    /// Compute named-people cards (Catalog.people()) and suggested unnamed clusters
    /// (FaceClusterer over unassignedFacesWithEmbeddings()) off the main actor. Called when the
    /// People view appears and re-called when facesDirty after a drain.
    func loadPeople() {
        guard let lib = library else { return }
        facesLoading = true
        let threshold = faceClusterThreshold
        Task {
            let (ppl, clusters): ([PersonRow], [FaceCluster]) =
                await Task.detached(priority: .userInitiated) {
                    let ppl = (try? lib.catalog.people()) ?? []
                    let unassigned = (try? lib.catalog.unassignedFacesWithEmbeddings()) ?? []
                    let groups = FaceClusterer.cluster(unassigned, threshold: threshold)
                    let conf = groups.map { ids -> FaceCluster in
                        FaceCluster(faceIDs: ids, representativeFaceID: ids.first ?? 0,
                                    count: ids.count)
                    }
                    return (ppl, conf)
                }.value
            self.people = ppl
            self.suggestedClusters = clusters
            self.facesLoading = false
            self.facesDirty = false
        }
    }

    // MARK: — Tidy Up (cull)

    struct CullGroup: Identifiable {
        let id: String                 // the keeper hash
        let items: [TimelineItem]
        let keep: String
        let suggestedEvict: Set<String>
    }
    var cullMode: CullMode = .bursts
    var cullGroups: [CullGroup] = []
    var cullLoading = false

    /// Compute redundant-photo groups off-main (the loadPeople pattern). Bursts reuse `embeddings`;
    /// Duplicates use the `phash` table. Sharpness (bursts) is measured on-demand from cached thumbs.
    func loadCullGroups() {
        guard let lib = library else { return }
        let mode = cullMode
        cullLoading = true
        Task {
            let groups: [CullGroup] = await Task.detached(priority: .userInitiated) {
                let raw: [[String]]
                switch mode {
                case .bursts:
                    let items = (try? lib.catalog.embeddingsWithTakenAt(model: EmbedStage().modelID)) ?? []
                    raw = BurstGrouper.group(items, windowMs: 60_000, cosineThreshold: 0.93)
                case .duplicates:
                    let rows = (try? lib.catalog.phashRowsWithDirPath()) ?? []
                    raw = DuplicateGrouper.group(rows, hammingThreshold: 6)
                }
                var out: [CullGroup] = []
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
                    out.append(CullGroup(id: s.keep, items: items, keep: s.keep,
                                         suggestedEvict: Set(s.evict)))
                }
                return out
            }.value
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
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let personID = try lib.catalog.createPerson(name: name)
                try lib.catalog.assignFaces(faceIDs, to: personID)
                self?.writeSidecarRegions(forPersonID: personID, lib: lib)
            } catch { NSLog("nameCluster failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.loadPeople()
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
                self?.loadPeople()
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
                // Rewrite sidecars for both persons (new has the moved faces; old has lost them).
                self?.writeSidecarRegions(forPersonID: newID, lib: lib)
                self?.writeSidecarRegions(forPersonID: sourcePerson, lib: lib)
            } catch { NSLog("splitFaces failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.loadPeople()
            }
        }
    }

    /// Reassign one face to another person (or nil → unassign). Updates sidecars accordingly.
    func reassignFace(_ id: Int64, to personID: Int64?, fromPerson oldPersonID: Int64?) {
        guard let lib = library else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try lib.catalog.reassignFace(id, to: personID)
                if let personID { self?.writeSidecarRegions(forPersonID: personID, lib: lib) }
                if let oldPersonID { self?.writeSidecarRegions(forPersonID: oldPersonID, lib: lib) }
                // If unassigned (no new person), also clear this face's region from its sidecar.
                if personID == nil {
                    self?.clearSidecarRegion(forFaceID: id, lib: lib)
                }
            } catch { NSLog("reassignFace failed: \(error)") }
            await MainActor.run { [weak self] in
                self?.facesDirty = true
                self?.loadPeople()
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
                self?.loadPeople()
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

    func openLibrary(roots: [URL]) {
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.rootsDefaultsKey)
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenPhoto")
            library = try LibraryService(vaultRoots: roots, appSupportDir: appSupport)
            startWatcher(roots: roots)
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
            Task { await rescan(); pokeDerivation() }
            // Load drives + badge presence from the persisted catalog, then auto-scan connected
            // drives so badges + status reflect reality without a manual Check. Re-scan on any
            // volume mount/unmount too.
            reloadDrives()
            reloadCanonicalPresence()
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

    func rescan() async {
        guard let library, !scanning else { return }
        scanning = true
        defer { scanning = false; scanProgress = nil }
        do {
            try await library.scanAll { [weak self] p in
                Task { @MainActor in if p.total > 50 { self?.scanProgress = p } }
            }
            try refreshQueries()
            pokeDerivation()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private var derivationTask: Task<Void, Never>?
    /// Stage registry: each stage's whole pending set is drained in order. Inference runs off-main
    /// via `Task.detached(.utility)` inside `drainDerivation`. Add stages here as they are implemented.
    private let derivationStages: [any DerivationStage] =
        [OCRDerivationStage(), EmbedStage(), FaceDerivationStage(), GeocodeStage(), PHashStage()]

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
        for stage in derivationStages {
            if Task.isCancelled { break }
            // If the stage's backing resources (e.g. the embed model package) are absent on this
            // machine, skip the whole stage — leave its jobs pending so they resume once the model
            // ships. Do NOT mark anything failed; that would permanently exclude jobs from retries.
            guard stage.isAvailable else { continue }
            let pending = (try? lib.catalog.pendingDerivation(stage: stage.id)) ?? []
            guard !pending.isEmpty else { continue }
            // Seed the progress line from the catalog so it appears immediately, then advance it
            // locally per successful item — inference dominates the per-item cost, so a published
            // increment each item is cheap and keeps the count climbing smoothly with no DB read.
            var progress = (try? lib.catalog.derivationProgress(stage: stage.id))
                ?? (done: 0, total: pending.count)
            derivationProgress = combinedProgress()
            for hash in pending {
                if Task.isCancelled { break }
                // "" excludes no vault — any reachable copy (Mac-local or a connected drive) is fine.
                let url = goodCopyURL(forHash: hash, excluding: "")
                // Stages that need the image bytes are skipped when the file is unreachable
                // (e.g. drive ejected) — they retry on the next poke. GeocodeStage reads catalog
                // lat/lon only (needsFile == false), so a drive-only asset still gets geocoded.
                if url == nil && stage.needsFile { continue }
                let runURL = url ?? URL(fileURLWithPath: "/")   // geocode ignores url; pass a harmless placeholder
                let ok = await Task.detached(priority: .utility) {
                    await stage.run(hash: hash, url: runURL, catalog: lib.catalog)
                }.value
                if ok {
                    try? lib.catalog.markDerived(hash: hash, stage: stage.id)
                    progress.done += 1
                } else {
                    try? lib.catalog.markDerivationFailed(hash: hash, stage: stage.id)
                }
                derivationProgress = combinedProgress()
                await Task.yield()
            }
        }
        derivationProgress = nil
        semanticIndexDirty = true   // embeddings may have grown → refresh the in-memory index
        facesDirty = true           // faces may have grown → refresh the People clustering
        geocodeDirty = true         // geocoded places may have grown → inspector picks up new rows
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

    func refreshQueries() throws {
        guard let library else { return }
        sections = try library.timelineSections(grouping: grouping, videoOnly: videoOnly)
        flatItems = sections.flatMap(\.items)
        folderTree = try library.folderTree()
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
    func delete(_ items: [TimelineItem]) async {
        guard let library else { return }
        do {
            _ = try await library.delete(items)
            try refreshQueries()
        } catch {
            NSAlert(error: error).runModal()
        }
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
        case .photosLibrary, .takeout:
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
}
