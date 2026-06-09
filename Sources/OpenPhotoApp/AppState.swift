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
            if let vr = canonicalVaults.first(where: { $0.id == vault.descriptor.vaultID }) { cacheDriveKind(vr) }
            try refreshCanonicalPresence(driveVault: vault)
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
    /// union across all canonical vaults (so refreshing one drive never wipes another's badges).
    func refreshCanonicalPresence(driveVault: Vault) throws {
        guard let lib = library else { return }
        let entries = presenceEntries(forDrive: driveVault, limitedTo: nil)
        try lib.catalog.replaceVaultPresence(vaultID: driveVault.descriptor.vaultID, entries: entries)
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

    /// Full-res URL for an item: local file, or the drive file when the drive is connected.
    func fullResURL(for item: TimelineItem) -> URL? {
        if item.driveRelPath == nil { return library?.absoluteURL(for: item) }
        guard let vr = canonicalVaults.first(where: { $0.id == item.vaultID }),
              driveIsPresent(vr),
              let drive = openVault(for: vr) else { return nil }
        let url = drive.absoluteURL(forRelativePath: item.driveRelPath!)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDriveOnly(_ item: TimelineItem) -> Bool { item.driveRelPath != nil }

    // MARK: — Drift scan / verify / repairs

    /// Last drift report per drive (vaultID → report) — drives the row status line. Populated by
    /// auto-scan on connect and by every scan/verify/repair.
    private(set) var driveDrift: [String: DriftReport] = [:]

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
        return report
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
        return enriched
    }

    /// Background fast-scan of every connected canonical drive — keeps badges + the status line
    /// honest automatically (at library-open and whenever a volume mounts), no manual Check needed.
    func autoScanConnectedDrives() async {
        for vr in canonicalVaults where driveIsPresent(vr) {
            cacheDriveKind(vr)
            guard let drive = openVault(for: vr) else { continue }
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
    /// any currently-connected canonical drive that holds it. (restore re-verifies the bytes, so
    /// even a drive copy that is itself rotten fails safely rather than spreading corruption.)
    private func goodCopyURL(forHash hash: String, excluding driveID: String) -> URL? {
        guard let lib = library else { return nil }
        // 1. A local Mac instance.
        if let inst = (try? lib.catalog.instances(forHash: hash))?.first(where: { $0.vaultID != driveID }),
           let vault = lib.vault(id: inst.vaultID) {
            let url = vault.absoluteURL(forRelativePath: inst.relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // 2. Another connected canonical drive that holds the hash (look up its path in its manifest).
        for vr in canonicalVaults where vr.id != driveID && driveIsPresent(vr) {
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
            Task { await rescan() }
            // Load drives + badge presence from the persisted catalog, then auto-scan connected
            // drives so badges + status reflect reality without a manual Check. Re-scan on any
            // volume mount/unmount too.
            reloadDrives()
            reloadCanonicalPresence()
            deviceWatcher.onVolumesChanged = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reloadDrives()
                    await self.autoScanConnectedDrives()
                }
            }
            Task { await autoScanConnectedDrives() }
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
