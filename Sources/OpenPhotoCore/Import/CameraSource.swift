import Foundation
import CoreGraphics
@preconcurrency import ImageCaptureCore

/// ImportSource for a USB-connected camera device (iPhone) via ImageCaptureCore.
/// Hardware-validated (see spike Sources/ICCSpike/main.swift); keep this layer THIN.
///
/// NOTE: @unchecked Sendable — all ICC delegate callbacks arrive on ICC's internal
/// queue (not the Swift concurrency executor). The continuation dance assumes
/// single-flight fetch/delete: the ImportEngine calls them sequentially per item,
/// so downloadContinuation and deleteContinuation are never written concurrently.
public final class CameraSource: NSObject, ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let camera: ICCameraDevice
    private var itemsByID: [String: ICCameraItem] = [:]

    public private(set) var stateStream: AsyncStream<SourceState>!
    private var stateContinuation: AsyncStream<SourceState>.Continuation!
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var deleteContinuation: CheckedContinuation<Void, Error>?

    public init(camera: ICCameraDevice) {
        self.camera = camera
        self.displayName = camera.name ?? "Camera"
        // sourceKey: stable per device — registry key part (spec §3).
        self.sourceKey = "cam-" + (camera.serialNumberString ?? camera.name ?? "unknown")
        super.init()
        (stateStream, stateContinuation) = {
            var c: AsyncStream<SourceState>.Continuation!
            let s = AsyncStream<SourceState> { c = $0 }
            return (s, c)
        }()
        camera.delegate = self
    }

    /// Open session; resolves when content catalog is ready. ICC error -9943 (locked)
    /// surfaces as .waitingForUnlock on stateStream and the call keeps waiting —
    /// unlock auto-retries the session (spike-proven pattern, cameraDeviceDidRemoveAccessRestriction).
    public func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyContinuations.append(c)
            stateContinuation.yield(.connected)
            camera.requestOpenSession()
        }
    }

    /// Enumerate items sorted by capture date descending, Live pairs linked.
    public func enumerateItems() async throws -> [ImportItem] {
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        itemsByID.removeAll()
        var items: [ImportItem] = files.map { f in
            let id = String(f.ptpObjectHandle)
            itemsByID[id] = f
            return ImportItem(
                id: id,
                name: f.name ?? "item-\(id)",
                byteSize: Int64(f.fileSize),
                takenAt: f.creationDate,
                kind: MediaKind.of(filename: f.name ?? "") ?? .photo,
                livePartnerID: nil
            )
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    /// Download file to `url` (directory + filename). Uses ICDownloadsDirectoryURL +
    /// ICSaveAsFilename option keys (ICDownloadOption NS_TYPED_ENUM, spike-validated).
    public func fetch(_ item: ImportItem, to url: URL) async throws {
        guard let file = itemsByID[item.id] as? ICCameraFile else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = url.deletingLastPathComponent()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            downloadContinuation = c
            camera.requestDownloadFile(
                file,
                options: [
                    .downloadsDirectoryURL: dir as Any,
                    .saveAsFilename: url.lastPathComponent as Any,
                ],
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    /// Delete one-by-one so failures are attributable per item (spec §5).
    /// Each deletion awaits didCompleteDeleteFilesWithError (spike-proven callback).
    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        var results: [DeleteResult] = []
        for item in items {
            guard let file = itemsByID[item.id] else {
                results.append(DeleteResult(itemID: item.id, error: "not found"))
                continue
            }
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    deleteContinuation = c
                    camera.requestDeleteFiles([file])
                }
                results.append(DeleteResult(itemID: item.id, error: nil))
            } catch {
                results.append(DeleteResult(itemID: item.id, error: String(describing: error)))
            }
        }
        return results
    }

    /// Return thumbnail for item. ICCameraItem.thumbnail is CGImage? (CGImageRef,
    /// not Unmanaged — SDK bridges it directly). Polls briefly after requestThumbnail;
    /// UI re-requests on nil.
    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        guard let file = itemsByID[item.id] else { return nil }
        if let existing = file.thumbnail { return existing }
        file.requestThumbnail()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let thumb = file.thumbnail { return thumb }
        }
        return nil
    }

}

// MARK: - ICCameraDeviceDelegate + ICCameraDeviceDownloadDelegate

extension CameraSource: ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {

    // ICCameraDeviceDownloadDelegate — selector target for requestDownloadFile.
    // Must be public because ICCameraDeviceDownloadDelegate is a public protocol.
    @objc public func didDownloadFile(_ file: ICCameraFile, error: (any Error)?,
                                      options: [String: Any],
                                      contextInfo: UnsafeMutableRawPointer?) {
        if let error {
            downloadContinuation?.resume(throwing: error)
        } else {
            downloadContinuation?.resume()
        }
        downloadContinuation = nil
    }

    /// Session open result. -9943 = device locked; yield .waitingForUnlock and
    /// keep the continuation alive — cameraDeviceDidRemoveAccessRestriction retries.
    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            let ns = error as NSError
            if ns.code == -9943 {
                // Device locked — surface lock state but do NOT fail open().
                stateContinuation.yield(.waitingForUnlock)
                return
            }
            readyContinuations.forEach { $0.resume(throwing: error) }
            readyContinuations.removeAll()
        }
    }

    /// Content catalog fully loaded — open() resolves here.
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        stateContinuation.yield(.ready)
        readyContinuations.forEach { $0.resume() }
        readyContinuations.removeAll()
    }

    /// Device unlocked — retry session (spike-proven auto-retry pattern).
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        stateContinuation.yield(.connected)
        camera.requestOpenSession()
    }

    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        stateContinuation.yield(.waitingForUnlock)
    }

    public func didRemove(_ device: ICDevice) {
        stateContinuation.yield(.gone)
        readyContinuations.forEach {
            $0.resume(throwing: URLError(.cancelled))
        }
        readyContinuations.removeAll()
    }

    /// Called when requestDeleteFiles completes (spike-proven delegate path).
    public func cameraDevice(_ camera: ICCameraDevice,
                             didCompleteDeleteFilesWithError error: (any Error)?) {
        if let error {
            deleteContinuation?.resume(throwing: error)
        } else {
            deleteContinuation?.resume()
        }
        deleteContinuation = nil
    }

    // Required stubs (macOS 15 SDK non-optional methods — signatures per spike):
    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice,
                             didReceiveThumbnail thumbnail: CGImage?,
                             for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice,
                             didReceiveMetadata metadata: [AnyHashable: Any]?,
                             for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
