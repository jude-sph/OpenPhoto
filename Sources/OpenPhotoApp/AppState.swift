import SwiftUI
import OpenPhotoCore

typealias Scanner = OpenPhotoCore.Scanner   // Foundation.Scanner collision

enum SidebarItem: String, Hashable, CaseIterable {
    case timeline, folders, bin
    var label: String {
        switch self {
        case .timeline: "Timeline"
        case .folders: "Folders"
        case .bin: "Bin"
        }
    }
    var symbol: String {
        switch self {   // SF Symbol map from the UI-Design README
        case .timeline: "photo.on.rectangle.angled"
        case .folders: "folder"
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
    var inspectorShown = true
    var gridMinSize: CGFloat = 132           // grid-size slider, 48…220
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
    private var watcher: FolderWatcher?

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

    private func startWatcher(roots: [URL]) {
        watcher = FolderWatcher(paths: roots.map(\.path)) { [weak self] in
            Task { @MainActor in await self?.rescan() }
        }
        watcher?.start()
    }
}
