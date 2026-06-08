import Testing
import Foundation
@testable import OpenPhotoCore

@Test func firesAfterFileChange() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("watched")
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let watcher = FolderWatcher(paths: [dir.path], debounce: .milliseconds(200)) {
        continuation.yield(())
    }
    watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))   // let the FSEvents stream warm up
    try Data("x".utf8).write(to: dir.appendingPathComponent("new.jpg"))
    let result = await withTimeout(seconds: 5) {
        var it = stream.makeAsyncIterator()         // created inside the task — no capture issue
        return await it.next() != nil
    }
    #expect(result)   // change observed within 5s
}

/// Race an async predicate against a deadline.
func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await op() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
