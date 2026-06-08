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
    private let browser = ICDeviceBrowser()

    /// Set by AppState; called with the removed device's id.
    var openedDeviceRemoved: ((String) -> Void)?

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000001 | 0x00000100)!
        browser.start()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        volumesChanged()
    }

    func source(for device: ConnectedDevice) -> (any ImportSource)? {
        switch device {
        case .camera(let id, _):
            cameras[id].map { CameraSource(camera: $0) }
        case .volume(_, _, let url):
            VolumeSource(rootURL: url, displayName: device.name)
        }
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
        devices = devices.filter { if case .camera = $0 { true } else { false } } + vols
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
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice,
                                   moreGoing: Bool) {
        // Match by device name — crude but acceptable for v1 (no stable cross-boundary ID).
        let name = device.name
        Task { @MainActor in
            if let (id, _) = self.cameras.first(where: { $0.value.name == name }) {
                self.cameras[id] = nil
                self.devices.removeAll { $0.id == "cam-\(id)" }
                if self.openedDeviceRemoved != nil { self.openedDeviceRemoved?("cam-\(id)") }
            }
        }
    }
}
