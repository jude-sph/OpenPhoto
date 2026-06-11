import SwiftUI
import OpenPhotoCore
@preconcurrency import ImageCaptureCore

/// A connectable import origin shown in the sidebar's Devices section.
enum ConnectedDevice: Identifiable, Equatable {
    case camera(id: String, name: String)
    case volume(id: String, name: String, url: URL)
    var id: String {
        switch self {
        case .camera(let id, _): "cam-\(id)"
        case .volume(let id, _, _): "vol-\(id)"
        }
    }
    var name: String {
        switch self {
        case .camera(_, let n): n
        case .volume(_, let n, _): n
        }
    }
    var symbol: String {
        switch self {
        case .camera: "iphone"
        case .volume: "sdcard"
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
                  v.volumeIsRemovable == true,
                  FileManager.default.fileExists(
                      atPath: url.appendingPathComponent("DCIM").path) else { continue }
            vols.append(.volume(id: v.volumeUUIDString ?? url.path,
                                name: v.volumeName ?? url.lastPathComponent, url: url))
        }
        // Keep cameras and manually-added folder sources; re-detect real removable volumes.
        let kept = devices.filter { dev in
            if case .camera = dev { return true }
            return dev.id.hasPrefix("vol-manual-")
        }
        devices = kept + vols
        onVolumesChanged?()
    }
}

extension DeviceWatcher: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice,
                                   moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let id = cam.serialNumberString ?? cam.name ?? UUID().uuidString
        let name = cam.name ?? "Camera"
        Task { @MainActor in
            self.cameras[id] = cam
            if !self.devices.contains(where: { $0.id == "cam-\(id)" }) {
                self.devices.append(.camera(id: id, name: name))
            }
            self.deviceConnected?("cam-\(id)")   // re-verify prior sends to this phone (read-only)
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice,
                                   moreGoing: Bool) {
        // Match by device name — crude but acceptable for v1 (no stable cross-boundary ID).
        let name = device.name
        Task { @MainActor in
            if let (id, _) = self.cameras.first(where: { $0.value.name == name }) {
                self.cameras[id] = nil
                self.sourceCache["cam-\(id)"]?.close()   // release the ICC session — don't leak it
                self.sourceCache["cam-\(id)"] = nil       // drop stale source so a replug makes a fresh session
                self.devices.removeAll { $0.id == "cam-\(id)" }
                if self.openedDeviceRemoved != nil { self.openedDeviceRemoved?("cam-\(id)") }
            }
        }
    }
}
