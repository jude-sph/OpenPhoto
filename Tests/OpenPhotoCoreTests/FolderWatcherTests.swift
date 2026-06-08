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

@Test func doesNotFireForOpenPhotoInternalWrites() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("watched")
    // Create the .openphoto subdirectory so the write goes into it
    let openPhotoDir = dir.appendingPathComponent("sub/.openphoto")
    try FileManager.default.createDirectory(at: openPhotoDir, withIntermediateDirectories: true)

    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let watcher = FolderWatcher(paths: [dir.path], debounce: .milliseconds(200)) {
        continuation.yield(())
    }
    watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))   // let FSEvents stream warm up

    // Write inside .openphoto — should NOT fire
    try Data("xmp data".utf8).write(to: openPhotoDir.appendingPathComponent("x.xmp"))

    // Wait for debounce window + margin; if we get a value the watcher incorrectly fired
    let fired = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var it = stream.makeAsyncIterator()
            return await it.next() != nil   // true = unwanted fire
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(600))   // debounce + margin
            return false   // timeout = did not fire (good)
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
    #expect(!fired, "Watcher should NOT fire for .openphoto internal writes")
}

@Test func doesFireForNormalPhotoWrite() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("watched")
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let watcher = FolderWatcher(paths: [dir.path], debounce: .milliseconds(200)) {
        continuation.yield(())
    }
    watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))
    try Data("jpg data".utf8).write(to: dir.appendingPathComponent("sub/y.jpg").creatingParent())
    let result = await withTimeout(seconds: 5) {
        var it = stream.makeAsyncIterator()
        return await it.next() != nil
    }
    #expect(result, "Watcher SHOULD fire for normal photo writes")
}
