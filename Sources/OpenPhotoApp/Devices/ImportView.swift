import SwiftUI
import OpenPhotoCore

struct ImportView: View {
    @Bindable var state: AppState
    let device: ConnectedDevice

    enum Phase: Equatable { case connecting, waitingForUnlock, ready, importing(done: Int, total: Int), failedToConnect(String) }
    @State private var phase: Phase = .connecting
    @State private var source: (any ImportSource)?
    @State private var items: [ImportItem] = []
    @State private var selection = Set<String>()
    @State private var destination: String = ""
    @State private var newFolderName: String = ""
    @State private var sessionImported: [ImportEngine.ImportedItem] = []   // across batches
    @State private var sessionImportedIDs = Set<String>()
    @State private var lastResult: ImportEngine.BatchResult?
    @State private var showFreeUp = false
    @State private var stateStreamTask: Task<Void, Never>?
    @State private var importedIDCache = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
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
            if case .ready = phase {
                Text("\(items.count) items · \(alreadyImportedCount) already imported")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Select all new") {
                selection = Set(items.filter { !isImported($0) }.map(\.id))
            }.controlSize(.small)
            Button("Deselect") { selection.removeAll() }.controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .connecting:
            ContentUnavailableView("Connecting…", systemImage: "cable.connector")
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
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Theme.gridGap)],
                          spacing: Theme.gridGap) {
                    ForEach(displayItems) { item in
                        ImportTile(
                            item: item, source: source!,
                            alreadyImported: isImported(item),
                            importedThisSession: sessionImportedIDs.contains(item.id),
                            selected: selection.contains(item.id),
                            onToggle: { toggle(item) })
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
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
                destinationPicker
                Button("Import \(selectedDisplayCount) items") { Task { await runBatch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDisplayCount == 0 || destination.isEmpty)
                if !sessionImported.isEmpty || hasPreviouslyImportedOnDevice {
                    Button("Free up space on \(device.name)…") { showFreeUp = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight + 8)
    }

    // MARK: Destination picker
    // Note: Menu containing TextField does not work reliably on macOS — the TextField
    // inside a Menu is not focusable. Replaced with the plan's sanctioned fallback:
    // a Picker of existing folders + an adjacent "New folder" TextField whose submit
    // sets the destination.
    private var destinationPicker: some View {
        HStack(spacing: 6) {
            Picker(selection: $destination) {
                Text("Destination…").tag("")
                ForEach(allFolders, id: \.self) { f in
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

    private var displayItems: [ImportItem] {
        // Hide the video halves of Live pairs — the photo tile represents both.
        items.filter { !($0.kind == .video && $0.livePartnerID != nil) }
    }
    /// Count of selected items that are visible in the grid (excludes hidden Live-pair video halves).
    /// Use this for UI labels; `selection` itself (which may contain hidden partner IDs) is still
    /// passed to the engine so it can handle both halves correctly.
    private var selectedDisplayCount: Int {
        displayItems.filter { selection.contains($0.id) }.count
    }
    private var allFolders: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { paths.append(n.path); walk(n.children) } }
        walk(state.folderTree)
        return paths.sorted()
    }
    private var alreadyImportedCount: Int { items.filter { isImported($0) }.count }
    private var hasPreviouslyImportedOnDevice: Bool {
        items.contains { isImported($0) && !sessionImportedIDs.contains($0.id) }
    }
    private func isImported(_ item: ImportItem) -> Bool {
        sessionImportedIDs.contains(item.id) || importedIDCache.contains(item.id)
    }
    private func toggle(_ item: ImportItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
        // Live pairs select atomically (engine enforces too; UI mirrors it).
        if let pid = item.livePartnerID {
            if selection.contains(item.id) { selection.insert(pid) }
            else { selection.remove(pid) }
        }
    }

    private func connect() async {
        stateStreamTask?.cancel()
        stateStreamTask = nil
        phase = .connecting
        guard let src = state.deviceWatcher.source(for: device) else {
            phase = .failedToConnect("Source unavailable"); return
        }
        source = src
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
        rebuildImportedCache()
    }

    /// Rebuild the imported-ID cache from the registry (+ this session's imports).
    /// Called after enumeration AND after every batch so freshly imported *and*
    /// skipped-as-duplicate items immediately badge "already in library" and the
    /// free-up button appears without needing to reopen the device. Avoids
    /// per-render NSLock calls in isImported(_:).
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

    private func runBatch() async {
        guard let source, let lib = state.library, let registry = state.importRegistry,
              // LIMITATION (v1): destination always targets the primary vault (vaults.first);
              // multi-vault routing deferred — the app is single-vault in the current shipping configuration.
              let vault = lib.vaults.first else { return }
        let batchItems = items.filter { selection.contains($0.id) }
        phase = .importing(done: 0, total: batchItems.count)
        let engine = ImportEngine(library: lib, registry: registry)
        let result = await engine.run(source: source, items: batchItems,
                                      vault: vault, dirPath: destination) { p in
            Task { @MainActor in phase = .importing(done: p.done, total: p.total) }
        }
        lastResult = result
        sessionImported.append(contentsOf: result.imported)
        sessionImportedIDs.formUnion(result.imported.map(\.item.id))
        // Rebuild from the registry (now updated by the engine) so BOTH imported
        // and skipped-as-duplicate items immediately reflect "already in library"
        // and the free-up button appears without reopening the device.
        rebuildImportedCache()
        selection.removeAll()
        try? state.refreshQueries()
        phase = .ready
    }
}
