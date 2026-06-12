import SwiftUI
import OpenPhotoCore
@preconcurrency import ImageCaptureCore

/// A connectable import origin shown in the sidebar's Devices section.
enum ConnectedDevice: Identifiable, Equatable {
    case camera(id: String, name: String)
    case volume(id: String, name: String, url: URL)
    case photosLibrary
    case takeout(id: String, name: String, url: URL)
    case foreignVault(id: String, name: String, url: URL)
    var id: String {
        switch self {
        case .camera(let id, _): "cam-\(id)"
        case .volume(let id, _, _): "vol-\(id)"
        case .photosLibrary: "photoslib"
        case .takeout(let id, _, _): "takeout-\(id)"
        case .foreignVault(let id, _, _): "foreign-\(id)"
        }
    }
    var name: String {
        switch self {
        case .camera(_, let n): n
        case .volume(_, let n, _): n
        case .photosLibrary: "Apple Photos"
        case .takeout(_, let n, _): n
        case .foreignVault(_, let n, _): n
        }
    }
    var symbol: String {
        switch self {
        case .camera: "iphone"
        case .volume: "sdcard"
        case .photosLibrary: "photo.on.rectangle.angled"
        case .takeout: "arrow.down.circle"
        case .foreignVault: "externaldrive.badge.person.crop"
        }
    }
    /// Sources whose items can actually be deleted off them, enabling the
    /// "free up space" flow: a connected camera (iPhone) and a removable volume
    /// (SD card → moves to .openphoto-trash). The read-only library imports
    /// (Apple Photos, Google Takeout, someone else's OpenPhoto drive) do NOT support it.
    var supportsDeviceDelete: Bool {
        switch self {
        case .camera, .volume: return true
        case .photosLibrary, .takeout, .foreignVault: return false
        }
    }
}

/// Watches ICDeviceBrowser + volume mounts; exposes devices + source factory.
@Observable @MainActor
final class DeviceWatcher: NSObject {
    private(set) var devices: [ConnectedDevice] = []
    private var cameras: [String: ICCameraDevice] = [:]
    private var sourceCache: [String: any ImportSource] = [:]   // keep one open source per device
    private let browser = ICDeviceBrowser()

    /// Set by AppState; called with the removed device's id.
    var openedDeviceRemoved: ((String) -> Void)?

    /// Set by AppState; called with a newly-connected device's id (camera) so it can be
    /// re-verified against sends.jsonl. Read-only — DeviceWatcher itself never enumerates.
    var deviceConnected: ((String) -> Void)?

    /// Set by AppState; called whenever volumes mount/unmount (to re-scan canonical drives).
    var onVolumesChanged: (() -> Void)?

    /// Set by AppState: every vault ID that is OURS (local source vaults + registered
    /// durable drives). A mounted vault with an unknown ID is someone else's → foreign.
    var knownVaultIDs: () -> Set<String> = { [] }

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000001 | 0x00000100)!
        browser.start()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closeAllSessions),
                                               name: NSApplication.willTerminateNotification, object: nil)
        volumesChanged()
        // Apple Photos is always available (permission is requested when opened) — pin it first.
        if !devices.contains(where: { $0.id == "photoslib" }) {
            devices.insert(.photosLibrary, at: 0)
        }
    }

    /// Tear down everything `start()` set up, so the watcher can be cleanly restarted when the user
    /// switches libraries. Idempotent.
    func stop() {
        browser.stop()
        browser.delegate = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        for src in sourceCache.values { src.close() }
        sourceCache.removeAll()
        cameras.removeAll()
        devices.removeAll()
    }

    /// Release all camera sessions on quit so they don't linger into the next launch.
    @objc private func closeAllSessions() {
        for src in sourceCache.values { src.close() }
    }

    func addManualVolume(url: URL) {
        let dev = ConnectedDevice.volume(id: "manual-" + url.path,
                                         name: url.lastPathComponent, url: url)
        if !devices.contains(where: { $0.id == dev.id }) { devices.append(dev) }
    }

    /// Route a chosen folder to the right source: a Google Takeout export becomes a
    /// `.takeout` device (special metadata folding); any other folder is a plain volume.
    func addImportFolder(url: URL) {
        if TakeoutSource.looksLikeTakeout(url) {
            let dev = ConnectedDevice.takeout(id: "manual-" + url.path,
                                              name: url.lastPathComponent, url: url)
            if !devices.contains(where: { $0.id == dev.id }) { devices.append(dev) }
        } else {
            addManualVolume(url: url)
        }
    }

    /// Remove a manually-added folder import source by its device id (`vol-manual-…`). Real
    /// phones/SD cards are removed by unplugging; this is for folder sources the user added.
    func removeManualVolume(id deviceID: String) {
        sourceCache[deviceID]?.close()
        sourceCache[deviceID] = nil
        devices.removeAll { $0.id == deviceID }
        openedDeviceRemoved?(deviceID)   // closes the import view if this source was open
    }

    /// Returns the (cached) source for a device. Caching keeps a single open ICC
    /// session alive across ImportView appearances — without it, re-entering the
    /// import screen opens a second session and enumeration comes back empty.
    func source(for device: ConnectedDevice) -> (any ImportSource)? {
        if let cached = sourceCache[device.id] { return cached }
        let made: (any ImportSource)?
        switch device {
        case .camera(let id, _):
            made = cameras[id].map { CameraSource(camera: $0) }
        case .volume(_, _, let url):
            made = VolumeSource(rootURL: url, displayName: device.name)
        case .photosLibrary:
            made = PhotosLibrarySource()
        case .takeout(_, _, let url):
            made = TakeoutSource(rootURL: url, displayName: device.name)
        case .foreignVault(_, let name, let url):
            made = ((try? Vault.open(at: url)) ?? nil)
                .map { ForeignVaultSource(vault: $0, displayName: name) }
        }
        if let made { sourceCache[device.id] = made }
        return made
    }

    @objc private func volumesChanged() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var vols: [ConnectedDevice] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsRemovable == true else { continue }
            // Someone ELSE's OpenPhoto drive → a read-only import source. Our own
            // registered drives never land here (their IDs are known); adoption stays
            // behind the explicit Add Drive flow.
            if let vault = (try? Vault.open(at: url)) ?? nil,
               !knownVaultIDs().contains(vault.descriptor.vaultID) {
                vols.append(.foreignVault(id: vault.descriptor.vaultID,
                                          name: v.volumeName ?? url.lastPathComponent,
                                          url: url))
                continue
            }
            guard FileManager.default.fileExists(
                      atPath: url.appendingPathComponent("DCIM").path) else { continue }
            vols.append(.volume(id: v.volumeUUIDString ?? url.path,
                                name: v.volumeName ?? url.lastPathComponent, url: url))
        }
        // Keep cameras, Apple Photos, Takeout, and manually-added folders; re-detect real
        // removable volumes and foreign vaults (none of the kept kinds are removable mounts).
        let kept = devices.filter { dev in
            switch dev {
            case .camera, .photosLibrary, .takeout: return true
            case .volume: return dev.id.hasPrefix("vol-manual-")
            case .foreignVault: return false
            }
        }
        devices = kept + vols
        onVolumesChanged?()
    }
}

extension DeviceWatcher: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice,
                                   moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        // Stable id keyed on the USB location, so a locked phone added as "LOC:<id>"
        // and its later resolved re-add collapse to ONE row instead of two.
        let id = CameraIdentity.id(usbLocationID: Int(device.usbLocationID),
                                   serial: cam.serialNumberString, name: device.name)
        let name = CameraIdentity.displayName(device.name)
        Task { @MainActor in
            self.cameras[id] = cam
            if let idx = self.devices.firstIndex(where: { $0.id == "cam-\(id)" }) {
                // Same physical device re-reported (e.g. its name resolved after unlock):
                // refresh the label in place rather than appending a duplicate row.
                if self.devices[idx].name != name {
                    self.devices[idx] = .camera(id: id, name: name)
                }
            } else {
                self.devices.append(.camera(id: id, name: name))
            }
            self.deviceConnected?("cam-\(id)")   // re-verify prior sends to this phone (read-only)
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice,
                                   moreGoing: Bool) {
        // Same stable id as didAdd — the USB location is constant for the connection,
        // so removal always matches even though the name resolved after the add.
        let id = (device as? ICCameraDevice).map {
            CameraIdentity.id(usbLocationID: Int(device.usbLocationID),
                              serial: $0.serialNumberString, name: device.name)
        }
        guard let id else { return }
        Task { @MainActor in
            self.cameras[id] = nil
            self.sourceCache["cam-\(id)"]?.close()   // release the ICC session — don't leak it
            self.sourceCache["cam-\(id)"] = nil       // drop stale source so a replug makes a fresh session
            self.devices.removeAll { $0.id == "cam-\(id)" }
            self.openedDeviceRemoved?("cam-\(id)")    // close the import view if this source was open
        }
    }
}
