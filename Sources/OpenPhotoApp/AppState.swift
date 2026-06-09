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

    private(set) var canonicalVaults: [VaultRecord] = []

    /// Refresh the observable drive list from the catalog. A computed property that queries the
    /// DB doesn't trigger @Observable invalidation, so the Drives view wouldn't react when a drive
    /// is adopted — this stored property does. Call after adopting a drive and at library-open.
    func reloadDrives() {
        canonicalVaults = (try? library?.catalog.registeredVaults().filter { $0.role == "canonical" }) ?? []
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
            // Refuse a folder that already holds a non-canonical vault (e.g. the user picked
            // one of their own source roots). Adopting it would diverge catalog/disk role and
            // could make the engine try to sync a vault onto itself.
            guard vault.descriptor.role == .canonical else {
                driveAlert("Can’t use this folder",
                    "“\(url.lastPathComponent)” already contains a \(vault.descriptor.role.rawValue) library vault. Choose an empty folder or a drive dedicated to your canonical library.")
                return
            }
            // Already adopted? Same vault_id means it's the same drive.
            if canonicalVaults.contains(where: { $0.id == vault.descriptor.vaultID }) {
                driveAlert("Already added",
                    "“\(url.lastPathComponent)” is already one of your drives.")
                return
            }
            try lib.catalog.registerVault(id: vault.descriptor.vaultID,
                                          role: vault.descriptor.role.rawValue, rootPath: url.path)
            reloadDrives()
            try refreshCanonicalPresence(driveVault: vault)
        } catch { driveAlert("Couldn’t add drive", error.localizedDescription) }
    }

    private func driveAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Re-read a drive's manifest into vault_presence, then rebuild the badge cache as the
    /// union across all canonical vaults (so refreshing one drive never wipes another's badges).
    func refreshCanonicalPresence(driveVault: Vault) throws {
        guard let lib = library else { return }
        let hashes = (try? Manifest.read(from: driveVault.manifestURL))?.map { $0.hash.stringValue } ?? []
        try lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID, hashes: hashes)
        reloadCanonicalPresence()
    }

    /// Rebuild `canonicalPresence` from the persisted catalog — union of every canonical
    /// vault's presence set. Cheap; safe to call at library-open and after any sync.
    func reloadCanonicalPresence() {
        guard let lib = library else { return }
        var union = Set<String>()
        for vr in canonicalVaults {
            if let hs = try? lib.catalog.vaultPresenceHashes(forVault: vr.id) { union.formUnion(hs) }
        }
        canonicalPresence = union
    }

    func openVault(for vr: VaultRecord) -> Vault? {
        try? Vault.openOrCreate(at: URL(fileURLWithPath: vr.rootPath), role: .canonical)
    }

    // MARK: — Drift scan / verify / repairs

    /// Run a fast drift scan, set this drive's presence to verified reality, refresh badges.
    @discardableResult
    func driftScan(_ driveVault: Vault) -> DriftReport {
        guard let lib = library else { return DriftReport() }
        var report = (try? DriftReconciler().scan(drive: driveVault)) ?? DriftReport()
        if let p = presenceService() {
            DriftReconciler().annotateRecoverability(&report, driveID: driveVault.descriptor.vaultID, presence: p)
        }
        try? lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID,
                                              hashes: Array(report.presentHashes))
        reloadCanonicalPresence()
        return report
    }

    /// Full integrity check (slow); same presence/badge refresh as driftScan.
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
                                              hashes: Array(enriched.presentHashes))
        reloadCanonicalPresence()
        return enriched
    }

    func adoptDriftFile(relPath: String, on driveVault: Vault) {
        _ = try? DriftReconciler().adopt(relPath: relPath, on: driveVault)
        driftScan(driveVault)
    }

    func acknowledgeGone(relPath: String, on driveVault: Vault) {
        try? DriftReconciler().acknowledgeGone(relPath: relPath, on: driveVault)
        driftScan(driveVault)
    }

    /// Restore a missing file from its best available good copy; returns true on success.
    @discardableResult
    func restoreDriftFile(_ finding: DriftFinding, on driveVault: Vault) -> Bool {
        guard let hash = finding.recordedHash,
              let source = goodCopyURL(forHash: hash, excluding: driveVault.descriptor.vaultID) else { return false }
        do {
            try DriftReconciler().restore(relPath: finding.relPath, expectedHash: hash,
                                          from: source, on: driveVault)
            driftScan(driveVault); return true
        } catch { NSLog("restore failed: \(error)"); return false }
    }

    /// A reachable on-disk file with `hash` outside `driveID` — currently the Mac's local copy.
    private func goodCopyURL(forHash hash: String, excluding driveID: String) -> URL? {
        guard let lib = library, let inst = (try? lib.catalog.instances(forHash: hash))?
            .first(where: { $0.vaultID != driveID }),
              let vault = lib.vault(id: inst.vaultID) else { return nil }
        let url = vault.absoluteURL(forRelativePath: inst.relPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
            // Load drives + badge presence from the persisted catalog.
            reloadDrives()
            reloadCanonicalPresence()
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
