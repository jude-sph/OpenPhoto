import Foundation

/// Pure running-average throughput + ETA over a sliding time window. Feed cumulative
/// (bytesDone, monotonic time) at any cadence; the speed is the average over roughly the last
/// `window` seconds, so bursty samples (cached/duplicate files that copy in a blink, or a batch of
/// callbacks landing together) don't make it spike. The ETA is for the WHOLE job: remaining total
/// bytes ÷ that averaged speed. No clock inside — the caller passes `now`.
public struct SyncRateMeter {
    private var samples: [(t: Double, bytes: Int64)] = []
    private let window: Double
    private let minSpan: Double

    public init(window: Double = 3.0, minSpan: Double = 0.4) {
        self.window = window; self.minSpan = minSpan
    }

    /// Returns the averaged speed (bytes/sec) and a whole-job ETA (seconds, nil until there's enough
    /// span to trust a rate).
    public mutating func update(bytesDone: Int64, bytesTotal: Int64, now: Double)
        -> (speed: Double, eta: Double?) {
        samples.append((now, bytesDone))
        // Trim samples older than the window, but always keep at least two to measure a span.
        while samples.count > 2, let first = samples.first, now - first.t > window {
            samples.removeFirst()
        }
        guard let first = samples.first, let last = samples.last else { return (0, nil) }
        let span = last.t - first.t
        guard span >= minSpan else { return (0, nil) }     // warm-up: not enough time to estimate yet
        let speed = Double(max(0, last.bytes - first.bytes)) / span
        let eta: Double? = speed > 1 ? Double(max(0, bytesTotal - bytesDone)) / speed : nil
        return (speed, eta)
    }
}
