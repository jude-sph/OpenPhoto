import SwiftUI
import OpenPhotoCore

struct ImportView: View {
    @Bindable var state: AppState
    let device: ConnectedDevice

    enum Phase: Equatable { case connecting, waitingForUnlock, ready, importing(done: Int, total: Int), failedToConnect(String) }
    @State private var phase: Phase = .connecting
    @State private var source: (any ImportSource)?
    @State private var items: [ImportItem] = []
    @State private var selection = SelectionModel()
    @State private var destination: String = ""
    @State private var newFolderName: String = ""
    @State private var sessionImported: [ImportEngine.ImportedItem] = []   // across batches
    @State private var sessionImportedIDs = Set<String>()
    @State private var lastResult: ImportEngine.BatchResult?
    @State private var showFreeUp = false
    @State private var stateStreamTask: Task<Void, Never>?
    @State private var importedIDCache = Set<String>()
    @State private var sentIDCache = Set<String>()
    @State private var inLibraryCache = Set<String>()
    // Foreign-vault folder selection + the shared "Include their metadata" toggle.
    @State private var checkedFolders = Set<String>()
    @State private var foreignFolderCounts: [String: Int] = [:]
    @State private var carryMetadata = false
    @State private var enumProgress: (done: Int, total: Int)?

    /// Display items (Live video halves hidden) as selectable items carrying their partner.
    private var orderedSelectable: [SelectableItem] {
        displayItems.map { SelectableItem(id: $0.id, partnerID: $0.livePartnerID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            livePhotoNote
            content
            Divider().overlay(Theme.hairline)
            footer
        }
        .task(id: device.id) { await connect() }
        .onDisappear { stateStreamTask?.cancel() }
        .sheet(isPresented: $showFreeUp) {
            if let source, let registry = state.importRegistry,
               let lib = state.library, let vault = lib.vaults.first {
                FreeUpPhoneView(source: source, registry: registry,
                                library: lib, vault: vault,
                                deviceItems: items,
                                sessionImportedIDs: sessionImportedIDs) {
                    Task { await reloadItems() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
            Text(device.name).font(.system(size: 15, weight: .semibold))
            // Recognized-type indicator so the user can confirm OpenPhoto identified the source right.
            Text(device.recognizedKind)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.accentDim, in: Capsule())
                .help("OpenPhoto recognized this import source as: \(device.recognizedKind)")
            if case .ready = phase {
                Text("\(items.count) items · \(alreadyImportedCount) already imported")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Select all new") {
                selection.clear()
                selection.selectAll(displayItems.filter { !isImported($0) }
                    .map { SelectableItem(id: $0.id, partnerID: $0.livePartnerID) })
            }.controlSize(.small)
            Button("Deselect") { selection.clear() }.controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    /// iPhones don't expose the Live Photo motion `.mov` over USB (an Apple/
    /// ImageCaptureCore limitation — confirmed by the Phase-2 spike), so Live Photos
    /// import as plain stills. Tell the user how to keep them live. Shown only for a
    /// connected camera once the grid is up (SD cards/folders pair Live Photos fine).
    private var showLivePhotoNote: Bool {
        guard case .camera = device else { return false }
        switch phase { case .ready, .importing: return true; default: return false }
    }

    @ViewBuilder private var livePhotoNote: some View {
        if showLivePhotoNote {
            HStack(spacing: 7) {
                Image(systemName: "livephoto")
                Text("Live Photos import as stills over USB — Apple doesn't expose the motion video to apps. To keep them live, import via Apple Photos, or AirDrop them to a folder first.")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 16).padding(.vertical, 7)
            Divider().overlay(Theme.hairline)
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .connecting:
            ContentUnavailableView {
                Label("Connecting…", systemImage: "cable.connector")
            } description: {
                if let p = enumProgress {
                    Text("Reading \(p.done) of \(p.total)…")
                }
            }
            .frame(maxHeight: .infinity)
        case .waitingForUnlock:
            ContentUnavailableView {
                Label("Unlock your \(device.name)", systemImage: "lock.iphone")
            } description: {
                Text("OpenPhoto is waiting — unlock the device and this screen will continue automatically.")
            }.frame(maxHeight: .infinity)
        case .failedToConnect(let why):
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
            } description: { Text(why) }.frame(maxHeight: .infinity)
        case .ready, .importing:
            HStack(spacing: 0) {
                if isForeign {
                    folderPanel
                    Divider().overlay(Theme.hairline)
                }
                importGrid
            }
        }
    }

    private var importGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Theme.gridGap)],
                      spacing: Theme.gridGap) {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                    ImportTile(
                        item: item, source: source!,
                        alreadyImported: isImported(item),
                        importedThisSession: sessionImportedIDs.contains(item.id),
                        sentFromHere: sentIDCache.contains(item.id),
                        inLibrary: inLibraryCache.contains(item.id),
                        selected: selection.contains(item.id),
                        onToggle: {
                            selection.tap(index: index, items: orderedSelectable,
                                          extendingRange: NSEvent.modifierFlags.contains(.shift))
                        })
                        .cellFrame(item.id, in: "importgrid")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
        }
        .coordinateSpace(name: "importgrid")
        .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                     space: "importgrid", enabled: true))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch phase {
            case .importing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                Text("Copying & verifying… \(done)/\(total) · checksum verified before any deletion")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            default:
                if let r = lastResult {
                    Label("\(r.imported.count) imported & verified" +
                          (r.skipped.isEmpty ? "" : " · \(r.skipped.count) duplicates skipped") +
                          (r.failed.isEmpty ? "" : " · \(r.failed.count) FAILED"),
                          systemImage: r.failed.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(r.failed.isEmpty ? Theme.green : Theme.amber)
                }
                Text("\(selectedDisplayCount) selected")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
                if isForeign || (source as? VolumeSource)?.sawXMPSidecars == true {
                    Toggle("Include their metadata", isOn: $carryMetadata)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help(isForeign
                              ? "Copy their captions, ratings, tags and favorites (their .openphoto sidecars) alongside the imported photos."
                              : "Fold the exported .xmp sidecars (captions, keywords) into the imported files.")
                }
                destinationPicker
                Button("Import \(selectedDisplayCount) items") { Task { await runBatch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDisplayCount == 0 || destination.isEmpty)
                if device.supportsDeviceDelete && (!sessionImported.isEmpty || hasPreviouslyImportedOnDevice) {
                    Button("Free up space on \(device.name)…") { showFreeUp = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight + 8)
    }

    // MARK: Destination picker
    private var destinationPicker: some View {
        HStack(spacing: 6) {
            Picker(selection: $destination) {
                Text("Destination…").tag("")
                ForEach(pickerFolders, id: \.self) { f in
                    Text(f).tag(f)
                }
            } label: {
                EmptyView()
            }
            .frame(maxWidth: 200)
            TextField("New folder…", text: $newFolderName)
                .frame(width: 130)
                .onSubmit {
                    if !newFolderName.isEmpty {
                        destination = newFolderName
                        newFolderName = ""
                    }
                }
        }
    }

    // MARK: helpers

    // NOTE: `source` is Optional — `source is ForeignVaultSource` would always be false;
    // `as?` flattens through the optional correctly.
    private var isForeign: Bool { (source as? ForeignVaultSource) != nil }

    /// Foreign vault: only items inside a checked folder (subtree-inclusive) display.
    private var displayItems: [ImportItem] {
        let base = items.filter { !($0.kind == .video && $0.livePartnerID != nil) }
        guard isForeign else { return base }
        return base.filter { item in
            let dir = (item.id as NSString).deletingLastPathComponent
            return checkedFolders.contains { dir == $0 || dir.hasPrefix($0 + "/") }
        }
    }

    /// Their folders, sorted; checking a folder includes its whole subtree.
    private var foreignFolderList: [String] { foreignFolderCounts.keys.sorted() }

    private var folderPanel: some View {
        List {
            ForEach(foreignFolderList, id: \.self) { path in
                Toggle(isOn: Binding(
                    get: { checkedFolders.contains(path) },
                    set: { on in
                        if on { checkedFolders.insert(path) }
                        else { checkedFolders.remove(path) }
                        selection.clear()
                    })) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                        Text(path.isEmpty ? "(root)" : path).font(.system(size: 12))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(foreignFolderCounts[path] ?? 0)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 230)
    }
    private var selectedDisplayCount: Int {
        displayItems.filter { selection.contains($0.id) }.count
    }
    private var allFolders: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { paths.append(n.path); walk(n.children) } }
        walk(state.folderTree)
        return paths.sorted()
    }
    /// Picker options including a just-typed new folder, so selecting it never shows a blank menu.
    private var pickerFolders: [String] {
        var fs = allFolders
        if !destination.isEmpty, !fs.contains(destination) { fs.insert(destination, at: 0) }
        return fs
    }
    private var alreadyImportedCount: Int { items.filter { isImported($0) }.count }
    private var hasPreviouslyImportedOnDevice: Bool {
        items.contains { isImported($0) && !sessionImportedIDs.contains($0.id) }
    }
    private func isImported(_ item: ImportItem) -> Bool {
        sessionImportedIDs.contains(item.id) || importedIDCache.contains(item.id)
    }

    private func connect() async {
        stateStreamTask?.cancel()
        stateStreamTask = nil
        phase = .connecting
        selection.clear()
        guard let src = state.deviceWatcher.source(for: device) else {
            phase = .failedToConnect("Source unavailable"); return
        }
        source = src
        if let vol = src as? VolumeSource {
            vol.enumerationProgress = { done, total in
                Task { @MainActor in enumProgress = (done, total) }
            }
        }
        if src is PhotosLibrarySource {
            let ok = PhotosLibrarySource.currentStatus == .authorized
                || PhotosLibrarySource.currentStatus == .limited
            let status = ok ? PhotosLibrarySource.currentStatus : await PhotosLibrarySource.requestAccess()
            if status != .authorized && status != .limited {
                phase = .failedToConnect("OpenPhoto needs access to Apple Photos. Grant it in System Settings → Privacy & Security → Photos, then reopen this source.")
                return
            }
        }
        if let cam = src as? CameraSource {
            stateStreamTask = Task { [weak cam] in
                guard let cam else { return }
                for await s in cam.stateStream {
                    if Task.isCancelled { break }
                    await MainActor.run { if s == .waitingForUnlock { phase = .waitingForUnlock } }
                }
            }
            do { try await cam.open() }
            catch { phase = .failedToConnect(String(describing: error)); return }
        }
        await reloadItems()
        phase = .ready
    }

    private func reloadItems() async {
        guard let source else { return }
        items = (try? await source.enumerateItems()) ?? []
        enumProgress = nil
        if let foreign = source as? ForeignVaultSource {
            foreignFolderCounts = (try? foreign.folderCounts()) ?? [:]
            checkedFolders = []
            if destination.isEmpty { destination = "From " + device.name } // spec §3: suggested parent, editable
        }
        rebuildImportedCache()
        rebuildSentCache()
        rebuildInLibraryCache()
    }

    private func rebuildImportedCache() {
        guard let source else { return }
        var cache = Set<String>()
        if let reg = state.importRegistry {
            for item in items {
                let taken = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
                if reg.contains(sourceKey: source.sourceKey, name: item.name,
                                size: item.byteSize, takenAt: taken) {
                    cache.insert(item.id)
                }
            }
        }
        cache.formUnion(sessionImportedIDs)
        importedIDCache = cache
    }

    /// Mark items that OpenPhoto previously sent to THIS device (so a returned
    /// photo reads "sent from here", not a new import). Matched by fingerprint.
    /// Flag device photos that already exist ANYWHERE in OpenPhoto's catalog (any source, including
    /// drive-only) — matched by size + capture-second (no device-file hashing). Drives the drive glyph.
    private func rebuildInLibraryCache() {
        guard let keys = try? state.library?.catalog.knownSizeDateKeys() else { inLibraryCache = []; return }
        var cache = Set<String>()
        for item in items {
            let ms = item.takenAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            if ms != 0, keys.contains("\(item.byteSize)|\(ms / 1000)") { cache.insert(item.id) }
        }
        // Foreign drives: exact-hash pre-flag from their manifest — zero I/O.
        if items.contains(where: { $0.knownHash != nil }),
           let hashes = try? state.library?.catalog.assetHashes() {
            for item in items {
                if let kh = item.knownHash, hashes.contains(kh) { cache.insert(item.id) }
            }
        }
        inLibraryCache = cache
    }

    private func rebuildSentCache() {
        guard let source, let reg = state.sendRegistry else { sentIDCache = []; return }
        var cache = Set<String>()
        for item in items {
            let ms = item.takenAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            if reg.wasSentToDevice(destinationKey: source.sourceKey,
                                   size: item.byteSize, captureDateMs: ms) {
                cache.insert(item.id)
            }
        }
        sentIDCache = cache
    }

    private func runBatch() async {
        guard let source, let lib = state.library, let registry = state.importRegistry,
              let vault = lib.vaults.first else { return }
        let batchItems = items.filter { selection.contains($0.id) }
        phase = .importing(done: 0, total: batchItems.count)
        let engine = ImportEngine(library: lib, registry: registry)
        let foreign = source as? ForeignVaultSource
        if let vol = source as? VolumeSource { vol.foldXMPSidecars = carryMetadata }
        let carry = carryMetadata
        var subdirForItem: (@Sendable (ImportItem) -> String)?
        if foreign != nil {
            subdirForItem = { item in (item.id as NSString).deletingLastPathComponent }
        }
        var postPlace: (@Sendable (ImportEngine.ImportedItem) async -> Void)?
        if foreign != nil && carry {
            postPlace = { placed in
                // Carry their sidecar (their human metadata) for the placed copy —
                // collision-renamed names included; the engine rescans right after.
                guard let data = foreign?.sidecarData(for: placed.item) else { return }
                let mediaURL = vault.absoluteURL(forRelativePath: placed.placedRelPath)
                try? AtomicFile.write(data, to: vault.sidecarURL(forMediaAt: mediaURL))
            }
        }
        let result = await engine.run(
            source: source, items: batchItems, vault: vault, dirPath: destination,
            subdirForItem: subdirForItem, postPlace: postPlace) { p in
            Task { @MainActor in phase = .importing(done: p.done, total: p.total) }
        }
        lastResult = result
        sessionImported.append(contentsOf: result.imported)
        sessionImportedIDs.formUnion(result.imported.map(\.item.id))
        rebuildImportedCache()
        rebuildSentCache()
        rebuildInLibraryCache()
        selection.clear()
        try? state.refreshQueries()
        phase = .ready
    }
}
