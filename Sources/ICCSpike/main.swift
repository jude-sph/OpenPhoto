import Foundation
import ImageCaptureCore

final class SpikeDelegate: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate,
                           ICCameraDeviceDownloadDelegate {
    let deleteTest = CommandLine.arguments.contains("--delete-test")
    let downloadFirst = CommandLine.arguments.contains("--download-first")
    let deleteNewest = CommandLine.arguments.contains("--delete-newest")
    var pendingDelete: ICCameraItem?
    var deletingCamera: ICCameraDevice?

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice,
                       moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        print("Found: \(device.name ?? "?") — opening session…")
        camera.delegate = self
        camera.requestOpenSession()
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            let nsError = error as NSError
            if nsError.code == -9943 {   // device locked — wait for unlock, retry
                print("Phone is locked. Waiting — unlock it and I'll retry automatically…")
                return
            }
            print("Open session FAILED: \(error)"); exit(1)
        }
        print("Session open. Waiting for contents…")
    }

    func deviceDidBecomeReady(withCompleteContentCatalog camera: ICCameraDevice) {
        let files = camera.mediaFiles ?? []
        print("Items visible: \(files.count)")
        for f in files.prefix(10) {
            let sizeStr: String
            if let file = f as? ICCameraFile {
                sizeStr = "\(file.fileSize) bytes"
            } else {
                sizeStr = "? bytes"
            }
            print("  \(f.name ?? "?")  \(sizeStr)  locked=\(f.isLocked)")
        }
        if deleteNewest {
            // Target the most recent photo by capture date (user-designated test
            // photo). Phase-2 ritual: download → verify → delete.
            guard let target = files.compactMap({ $0 as? ICCameraFile })
                .max(by: { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) })
            else { print("No items."); exit(0) }
            print("Newest item: \(target.name ?? "?")  \(target.fileSize) bytes  taken \(target.creationDate.map(String.init(describing:)) ?? "?")")
            let dest = URL(fileURLWithPath: "spike-download", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            print("Step 1: downloading backup copy…")
            pendingDelete = target
            deletingCamera = camera
            camera.requestDownloadFile(target,
                options: [.downloadsDirectoryURL: dest as Any],
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil)
            return
        }
        if downloadFirst {
            guard let target = files.first as? ICCameraFile else {
                print("No downloadable first item."); exit(0)
            }
            let dest = URL(fileURLWithPath: "spike-download", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            print("Downloading \(target.name ?? "?") to \(dest.path)/ …")
            camera.requestDownloadFile(target,
                options: [.downloadsDirectoryURL: dest as Any],
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil)
            return
        }
        guard deleteTest else {
            print("Enumeration-only mode. --download-first copies the first item locally; --delete-test deletes it.")
            exit(0)
        }
        guard let victim = files.first else { print("No items to test with."); exit(0) }
        print("Attempting deletion of \(victim.name ?? "?") …")
        camera.requestDeleteFiles([victim])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("RESULT: no deletion callback within 15s — treat as NOT SUPPORTED / silently ignored.")
            exit(2)
        }
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: (any Error)?,
                               options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        if let error {
            print("RESULT: download FAILED: \(error)")
            exit(5)
        }
        print("Download SUCCEEDED → spike-download/\(file.name ?? "?")")
        if let victim = pendingDelete, let camera = deletingCamera {
            print("Step 2: requesting deletion of \(victim.name ?? "?") from the phone…")
            camera.requestDeleteFiles([victim])
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                print("RESULT: no deletion callback within 15s — treat as NOT SUPPORTED / silently ignored.")
                exit(2)
            }
        } else {
            exit(0)
        }
    }

    // Called after requestDeleteFiles: completes (legacy path)
    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?) {
        if let error {
            print("RESULT: deletion FAILED: \(error)")
            exit(3)
        } else {
            print("RESULT: deletion SUCCEEDED (didCompleteDeleteFilesWithError, no error)")
            exit(0)
        }
    }

    // Required protocol stubs:
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {}
    func device(_ d: ICDevice, didCloseSessionWithError e: (any Error)?) {}
    func didRemove(_ d: ICDevice) { print("Device removed."); exit(4) }
    // Required in macOS 15 SDK (non-optional):
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        print("Access restriction removed (device unlocked) — retrying session…")
        (device as? ICCameraDevice)?.requestOpenSession()
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        print("Access restriction enabled (device locked).")
    }
    // Optional stubs:
    func cameraDevice(_ c: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ c: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ c: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ c: ICCameraDevice) {}
    func cameraDevice(_ c: ICCameraDevice, didReceiveThumbnail t: CGImage?,
                      for i: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ c: ICCameraDevice, didReceiveMetadata m: [AnyHashable: Any]?,
                      for i: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ c: ICCameraDevice, didReceivePTPEvent d: Data) {}
}

let delegate = SpikeDelegate()
let browser = ICDeviceBrowser()
browser.delegate = delegate
// ICDeviceTypeMask and ICDeviceLocationTypeMask are NS_ENUM (not NS_OPTIONS),
// so use raw-value OR composition: camera=0x1, local=0x100
browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000001 | 0x00000100)!
browser.start()
print("Browsing for USB camera devices… plug in the iPhone and UNLOCK it. Ctrl-C to quit.")
RunLoop.main.run()
