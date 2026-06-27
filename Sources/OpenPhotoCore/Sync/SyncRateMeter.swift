import Foundation

/// Whole-job throughput + ETA. Feed cumulative (bytesDone, seconds-elapsed-since-start) at any
/// cadence; the speed is the running WHOLE-JOB average (bytesDone ÷ elapsed) and the ETA is the
/// remaining bytes ÷ that average. A whole-job average is smooth and — unlike a short sliding window —
/// never craters to "Zero KB/s" while a single large file is flushing to a slow drive; it just reflects
/// the overall rate. No clock inside — the caller passes the elapsed time as `now`.
public struct SyncRateMeter {
    private let minElapsed: Double

    public init(minElapsed: Double = 0.5) { self.minElapsed = minElapsed }

    /// The whole-job average speed (bytes/sec) and ETA (seconds) — both 0/nil until a little time has
    /// elapsed and some bytes have moved, so the very first samples don't report a wild rate.
    public mutating func update(bytesDone: Int64, bytesTotal: Int64, now: Double)
        -> (speed: Double, eta: Double?) {
        guard now >= minElapsed, bytesDone > 0 else { return (0, nil) }   // warm-up
        let speed = Double(bytesDone) / now
        let eta: Double? = speed > 1 ? Double(max(0, bytesTotal - bytesDone)) / speed : nil
        return (speed, eta)
    }
}
