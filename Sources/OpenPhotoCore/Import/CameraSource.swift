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
/// Thread-safety: `lock` guards `isGone`, all three continuation properties, the
/// `itemsByID` map, and `enumerationTask`. The import grid and the on-connect
/// send-reverify both reach the SAME CameraSource, so enumeration and the reads
/// that depend on its map (fetch/thumbnail/delete) genuinely race — `itemsByID`
/// is a non-Sendable Dictionary and MUST only be touched under `lock`.
/// Discipline: copy-out the continuation, nil it, unlock, THEN resume — never
/// resume while holding the lock to avoid re-entrancy deadlocks. In async contexts
/// use `lock.withLock { }` (the Swift 6-safe closure form).
public final class CameraSource: NSObject, ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let camera: ICCameraDevice

    public private(set) var stateStream: AsyncStream<SourceState>!
    private var stateContinuation: AsyncStream<SourceState>.Continuation!

    // Guarded by `lock`:
    private let lock = NSLock()
    private var isGone = false
    private var isReady = false   // session open + catalog ready; lets open() short-circuit on reuse
    private var isOpening = false  // an open is in flight — don't issue requestOpenSession twice
    private var recoveredBusy = false  // tried close+reopen after a -21347 once
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var deleteContinuation: CheckedContinuation<Void, Error>?
    private var itemsByID: [String: ICCameraItem] = [:]
    private var enumerationTask: Task<[ImportItem], Error>?  // single-flights concurrent enumerations

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

    // MARK: - Private lock helpers (non-async, safe to call from sync ICC callbacks)

    /// Atomically swap downloadContinuation for nil and return the old value.
    private func takeDownloadContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            let c = downloadContinuation
            downloadContinuation = nil
            return c
        }
    }

    /// Atomically swap deleteContinuation for nil and return the old value.
    private func takeDeleteContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            let c = deleteContinuation
            deleteContinuation = nil
            return c
        }
    }

    /// Open session; resolves when content catalog is ready. ICC error -9943 (locked)
    /// surfaces as .waitingForUnlock on stateStream and the call keeps waiting —
    /// unlock auto-retries the session (spike-proven pattern, cameraDeviceDidRemoveAccessRestriction).
    public func open() async throws {
        let (gone, ready) = lock.withLock { (isGone, isReady) }
        if gone { throw URLError(.cancelled) }
        if ready { return }   // cached source already open — reuse instantly, no reconnect

        enum OpenAction { case cancel, wait, open }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // Single-flight: only the FIRST caller issues requestOpenSession; others
            // just wait on the same in-flight open. Calling requestOpenSession twice
            // yields ICC -21347 "session already open".
            let action: OpenAction = lock.withLock {
                if isGone { return .cancel }
                readyContinuations.append(c)
                if isOpening || isReady { return .wait }
                isOpening = true
                return .open
            }
            switch action {
            case .cancel: c.resume(throwing: URLError(.cancelled))
            case .wait: break   // resumed when the in-flight open resolves
            case .open:
                stateContinuation.yield(.connected)
                camera.requestOpenSession()
            }
        }
    }

    /// Mark the session ready and resume everyone waiting (success).
    private func resolveReady() {
        let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
            isReady = true
            isOpening = false
            let p = readyContinuations
            readyContinuations.removeAll()
            return p
        }
        pending.forEach { $0.resume() }
    }

    /// Enumerate items sorted by capture date descending, Live pairs linked.
    /// Release the ICC session so it doesn't leak across plug/unplug cycles
    /// (leaked sessions accumulate and the daemon starts returning partial catalogs).
    public func close() {
        lock.withLock { isReady = false; isOpening = false }
        camera.requestCloseSession()
    }

    public func enumerateItems() async throws -> [ImportItem] {
        // Single-flight. The import grid and the on-connect send-reverify both ask
        // the SAME CameraSource to enumerate, often at the same instant on plug-in.
        // Running two device reads concurrently used to clobber the shared itemsByID
        // map (heap corruption → SIGSEGV) and returned varying partial counts.
        // Coalesce concurrent callers onto one in-flight read; a caller arriving
        // AFTER it finishes starts a fresh read (so reconnects still re-scan).
        let task: Task<[ImportItem], Error> = lock.withLock {
            if let existing = enumerationTask { return existing }
            let t = Task { try await self.performEnumeration() }
            enumerationTask = t
            return t
        }
        defer { lock.withLock { if enumerationTask == task { enumerationTask = nil } } }
        return try await task.value
    }

    private func performEnumeration() async throws -> [ImportItem] {
        // iPhone media catalogs keep growing for a moment after "ready", so a
        // single read catches a varying partial count. Wait until the count is
        // stable across two checks (capped at ~6s) before snapshotting.
        var last = -1
        for _ in 0..<30 {
            let count = camera.mediaFiles?.count ?? 0
            if count > 0 && count == last { break }
            last = count
            try? await Task.sleep(for: .milliseconds(200))
        }
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        // ptpObjectHandle is unreliable on iPhones (often 0 for every file), which
        // collapses the SwiftUI grid to a single cell. Use the enumeration index
        // for a guaranteed-unique, session-stable id (registry dedup keys on
        // name+size+takenAt, not this id, so a per-session id is fine).
        //
        // Build the id→file map in a LOCAL dictionary, then publish it atomically
        // under `lock`. Never mutate the shared itemsByID incrementally: fetch()/
        // thumbnail() read it concurrently while the grid renders, and an in-place
        // removeAll()+refill is a data race on a non-Sendable Dictionary.
        var localMap: [String: ICCameraItem] = [:]
        localMap.reserveCapacity(files.count)
        var items: [ImportItem] = files.enumerated().map { index, f in
            let id = "icc-\(index)"
            localMap[id] = f
            return ImportItem(
                id: id,
                name: f.name ?? "item-\(index)",
                byteSize: Int64(f.fileSize),
                takenAt: f.creationDate,
                kind: MediaKind.of(filename: f.name ?? "") ?? .photo,
                livePartnerID: nil
            )
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        lock.withLock { itemsByID = localMap }
        return pairLiveItems(items)
    }

    /// Download file to `url` (directory + filename). Uses ICDownloadsDirectoryURL +
    /// ICSaveAsFilename option keys (ICDownloadOption NS_TYPED_ENUM, spike-validated).
    public func fetch(_ item: ImportItem, to url: URL) async throws {
        if lock.withLock({ isGone }) { throw URLError(.cancelled) }

        guard let file = lock.withLock({ itemsByID[item.id] }) as? ICCameraFile else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = url.deletingLastPathComponent()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var alreadyGone = false
            lock.withLock {
                if isGone {
                    alreadyGone = true
                } else {
                    downloadContinuation = c
                }
            }
            if alreadyGone {
                c.resume(throwing: URLError(.cancelled))
                return
            }
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
            // Guard: if device is gone, mark this and all remaining items disconnected.
            if lock.withLock({ isGone }) {
                results.append(DeleteResult(itemID: item.id, error: "device disconnected"))
                continue
            }

            guard let file = lock.withLock({ itemsByID[item.id] }) else {
                results.append(DeleteResult(itemID: item.id, error: "not found"))
                continue
            }
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    var alreadyGone = false
                    lock.withLock {
                        if isGone {
                            alreadyGone = true
                        } else {
                            deleteContinuation = c
                        }
                    }
                    if alreadyGone {
                        c.resume(throwing: URLError(.cancelled))
                        return
                    }
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
        guard let file = lock.withLock({ itemsByID[item.id] }) else { return nil }
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
        let c = takeDownloadContinuation()
        if let error {
            c?.resume(throwing: error)
        } else {
            c?.resume()
        }
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
            if ns.code == -21347 {
                // "A session is already open" — typically a stale session left by a
                // previous run. Close it and reopen once to get a working session
                // for THIS process (just marking ready would enumerate 0 items).
                let recover = lock.withLock {
                    if recoveredBusy { return false }
                    recoveredBusy = true
                    return true
                }
                if recover {
                    camera.requestCloseSession()   // device(_:didCloseSessionWithError:) reopens
                } else {
                    failOpen(error)
                }
                return
            }
            failOpen(error)
        }
        // Success with no error: wait for deviceDidBecomeReady to resolve.
    }

    private func failOpen(_ error: any Error) {
        let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
            isOpening = false
            let p = readyContinuations
            readyContinuations.removeAll()
            return p
        }
        pending.forEach { $0.resume(throwing: error) }
    }

    /// Content catalog fully loaded — open() resolves here.
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        stateContinuation.yield(.ready)
        resolveReady()
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
        // 1. Atomically mark gone and collect all pending continuations.
        let (pendingReady, pendingDownload, pendingDelete): (
            [CheckedContinuation<Void, Error>],
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?
        ) = lock.withLock {
            isGone = true
            isReady = false
            isOpening = false
            let r = readyContinuations
            readyContinuations.removeAll()
            let d = downloadContinuation
            downloadContinuation = nil
            let del = deleteContinuation
            deleteContinuation = nil
            return (r, d, del)
        }

        // 2. Resume everything outside the lock.
        pendingDownload?.resume(throwing: URLError(.cancelled))
        pendingDelete?.resume(throwing: URLError(.cancelled))
        pendingReady.forEach { $0.resume(throwing: URLError(.cancelled)) }

        // 3. Yield gone state on stream.
        stateContinuation.yield(.gone)
    }

    /// Called when requestDeleteFiles completes (spike-proven delegate path).
    public func cameraDevice(_ camera: ICCameraDevice,
                             didCompleteDeleteFilesWithError error: (any Error)?) {
        let c = takeDeleteContinuation()
        if let error {
            c?.resume(throwing: error)
        } else {
            c?.resume()
        }
    }

    // Required stubs (macOS 15 SDK non-optional methods — signatures per spike):
    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        // If we closed to recover from a stale -21347 session, reopen now.
        let shouldReopen = lock.withLock { recoveredBusy && !isGone && !isReady }
        if shouldReopen { camera.requestOpenSession() }
    }
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
