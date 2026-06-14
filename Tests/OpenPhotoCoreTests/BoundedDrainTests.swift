import Testing
import Foundation
@testable import OpenPhotoCore

/// Records peak concurrency + completion count across concurrent work units.
private actor ConcTracker {
    private var current = 0, maxSeen = 0, processed = 0
    func enter() { current += 1; if current > maxSeen { maxSeen = current } }
    func leave() { current -= 1; processed += 1 }
    func snapshot() -> (max: Int, processed: Int) { (maxSeen, processed) }
}

@MainActor
@Test func boundedDrainRunsEveryItemOnceWithinTheLimit() async {
    let tracker = ConcTracker()
    let n = 50, limit = 4
    var produced = 0
    await boundedDrain(limit: limit, next: {
        guard produced < n else { return nil }
        produced += 1
        return { @Sendable in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await tracker.leave()
        }
    }, onComplete: {})
    let s = await tracker.snapshot()
    #expect(s.processed == n)     // every unit ran exactly once
    #expect(s.max <= limit)       // never exceeded the concurrency cap
    #expect(s.max >= 2)           // genuinely ran in parallel (not accidentally serial)
}

@MainActor
@Test func boundedDrainCallsOnCompleteOncePerItem() async {
    let n = 20
    var produced = 0, completes = 0
    await boundedDrain(limit: 3, next: {
        guard produced < n else { return nil }
        produced += 1
        return { @Sendable in try? await Task.sleep(for: .milliseconds(2)) }
    }, onComplete: { completes += 1 })
    #expect(completes == n)       // onComplete fired for each finished unit
}

@MainActor
@Test func boundedDrainStopsPullingWorkOnCancellation() async {
    let tracker = ConcTracker()
    var produced = 0
    let task = Task { @MainActor in
        await boundedDrain(limit: 4, next: {
            guard produced < 1000 else { return nil }
            produced += 1
            return { @Sendable in
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(10))
                await tracker.leave()
            }
        }, onComplete: {})
    }
    try? await Task.sleep(for: .milliseconds(40))
    task.cancel()
    await task.value
    let s = await tracker.snapshot()
    #expect(s.processed < 1000)   // cancellation stopped it before draining everything
}

@MainActor
@Test func boundedDrainHandlesEmptyAndUnderLimit() async {
    // Empty: never calls the operation, returns cleanly.
    var completes = 0
    await boundedDrain(limit: 4, next: { nil }, onComplete: { completes += 1 })
    #expect(completes == 0)

    // Fewer items than the limit: still runs each exactly once.
    let tracker = ConcTracker()
    var produced = 0
    await boundedDrain(limit: 8, next: {
        guard produced < 3 else { return nil }
        produced += 1
        return { @Sendable in await tracker.enter(); await tracker.leave() }
    }, onComplete: {})
    #expect(await tracker.snapshot().processed == 3)
}
