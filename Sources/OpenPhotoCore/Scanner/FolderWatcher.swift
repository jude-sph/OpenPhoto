import Foundation
import CoreServices

/// FSEvents wrapper: watches vault roots, fires a debounced callback on change.
/// The callback should trigger an incremental rescan (cheap — mtime fast-path).
///
/// - Note: `start()` and `stop()` are not concurrency-safe; call them from a
///   single owning context (e.g. the main actor or a dedicated serialised queue).
public final class FolderWatcher: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let paths: [String]
    private let debounce: Duration
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "openphoto.fsevents")
    private var pending: DispatchWorkItem?

    public init(paths: [String], debounce: Duration = .seconds(2),
                onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        guard streamRef == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleFire()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    private func scheduleFire() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        let ms = Int(debounce.components.seconds * 1_000
            + debounce.components.attoseconds / 1_000_000_000_000_000)
        queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    deinit { stop() }
}
