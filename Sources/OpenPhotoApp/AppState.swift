import SwiftUI
import OpenPhotoCore

typealias Scanner = OpenPhotoCore.Scanner   // Foundation.Scanner collision

enum SidebarItem: String, Hashable, CaseIterable {
    case timeline, folders, drives, bin
    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .folders: "Folders"
        case .drives: "Drives"
        case .bin: "Bin"
        }
    }
    var symbol: String {
        switch self {   // SF Symbol map from the UI-Design README
        case .timeline: "photo.on.rectangle.angled"
        case .folders: "folder"
        case .drives: "externaldrive"
        case .bin: "trash"
        }
    }
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
    var scanProgress: Scanner.Progress?
    var scanning = false
    var refreshToken = 0
    var grouping: TimelineGrouping = {
        let raw = UserDefaults.standard.string(forKey: "timelineGrouping") ?? ""
        return TimelineGrouping(rawValue: raw) ?? .day
    }() {
        didSet {
            UserDefaults.standard.set(grouping.rawValue, forKey: "timelineGrouping")
        }
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
        deviceWatcher.addManualVolume(url: url)
        if let dev = deviceWatcher.devices.first(where: { $0.id == "manual-" + url.path }) {
            openedDevice = dev
        }
    }

    var canonicalVaults: [VaultRecord] {
        (try? library?.catalog.registeredVaults().filter { $0.role == "canonical" }) ?? []
    }

    private(set) var canonicalPresence: Set<String> = []

    func driveIsPresent(_ vr: VaultRecord) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: vr.rootPath, isDirectory: &isDir) && isDir.boolValue
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
            try lib.catalog.registerVault(id: vault.descriptor.vaultID,
                                          role: vault.descriptor.role.rawValue, rootPath: url.path)
            try refreshCanonicalPresence(driveVault: vault)
        } catch { NSLog("addDrive failed: \(error)") }
    }

    func refreshCanonicalPresence(driveVault: Vault) throws {
        guard let lib = library else { return }
        let hashes = (try? Manifest.read(from: driveVault.manifestURL))?.map { $0.hash.stringValue } ?? []
        try lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID, hashes: hashes)
        canonicalPresence = Set(hashes)
    }

    func openVault(for vr: VaultRecord) -> Vault? {
        try? Vault.openOrCreate(at: URL(fileURLWithPath: vr.rootPath), role: .canonical)
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
            Task { await rescan() }
            if let canon = canonicalVaults.first, let v = openVault(for: canon), driveIsPresent(canon) {
                try? refreshCanonicalPresence(driveVault: v)
            }
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
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func refreshQueries() throws {
        guard let library else { return }
        sections = try library.timelineSections(grouping: grouping)
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
        refreshToken += 1
    }

    /// PresenceService over the current registries, if a library is open.
    private func presenceService() -> PresenceService? {
        guard let library, let imports = importRegistry,
              let sends = sendRegistry, let devices = deviceRegistry else { return nil }
        return PresenceService(catalog: library.catalog, imports: imports, sends: sends, devices: devices)
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

    /// Evict a selection to the bin, then refresh all queries.
    func evict(_ items: [TimelineItem]) async {
        guard let library else { return }
        do {
            _ = try await library.evict(items)
            try refreshQueries()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The connected device we can currently send to, if any. Cameras (AirDrop)
    /// are listed first by DeviceWatcher, so a connected iPhone is preferred.
    func connectedSendTarget() -> ConnectedDevice? {
        deviceWatcher.devices.first { sendDestination(for: $0) != nil }
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
        }
    }

    /// Map a library item to a SendItem (read-only original + fingerprint).
    func sendItem(for item: TimelineItem) -> SendItem? {
        guard let url = library?.absoluteURL(for: item) else { return nil }
        return SendItem(
            hash: item.hash, originalURL: url,
            fingerprint: PresenceFingerprint(size: item.size, captureDateMs: item.takenAtMs, hash: item.hash),
            displayName: (item.relPath as NSString).lastPathComponent)
    }

    /// Send a selection to a connected device, reporting progress. Returns the result.
    func send(_ items: [TimelineItem], to device: ConnectedDevice,
              progress: @escaping @Sendable (SendProgress) -> Void) async -> SendEngine.Result? {
        guard let library, let vault = library.vaults.first,
              let sends = sendRegistry, let devices = deviceRegistry,
              let destination = sendDestination(for: device) else { return nil }
        let sendItems = items.compactMap { sendItem(for: $0) }
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
