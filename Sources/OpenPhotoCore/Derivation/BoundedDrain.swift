import Foundation

/// Drive a stream of async work with bounded concurrency.
///
/// `next` (run on the main actor) lazily produces the next unit of work, or `nil` when exhausted —
/// lazy so the caller can resolve each item just-in-time (e.g. a filesystem check) without stalling
/// the main thread up front. At most `limit` units run concurrently. After each unit finishes,
/// `onComplete` runs on the main actor (progress, periodic refreshes, …). Honors cancellation: it
/// stops pulling new work and lets the in-flight units finish (structured concurrency).
///
/// Extracted from the background-analysis runner (`AppState.drainDerivation`) so the bounded-parallel
/// behaviour can be unit-tested deterministically (`BoundedDrainTests`), independent of the App layer.
@MainActor
public func boundedDrain(
    limit: Int,
    next: @MainActor () -> (@Sendable () async -> Void)?,
    onComplete: @MainActor () -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        @MainActor func submit() {
            if let op = next() { group.addTask(priority: .utility, operation: op) }
        }
        for _ in 0 ..< max(1, limit) { submit() }
        while await group.next() != nil {
            if Task.isCancelled { group.cancelAll(); break }
            onComplete()
            submit()
        }
    }
}
