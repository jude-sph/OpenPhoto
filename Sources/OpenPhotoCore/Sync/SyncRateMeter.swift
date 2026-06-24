import Foundation

/// Pure smoothed-throughput + ETA estimator. Feed cumulative (bytesDone, monotonic time); get a
/// stable EMA speed and an ETA (nil until warmed up). No Date/clock inside — caller passes `now`.
public struct SyncRateMeter {
    private var ema = 0.0
    private var lastBytes: Int64 = 0
    private var lastTime = 0.0
    private var samples = 0
    private let alpha: Double
    public init(alpha: Double = 0.2) { self.alpha = alpha }

    public mutating func update(bytesDone: Int64, bytesTotal: Int64, now: Double)
        -> (speed: Double, eta: Double?) {
        defer { lastBytes = bytesDone; lastTime = now; samples += 1 }
        guard samples >= 1 else { return (0, nil) }                 // first call = warm-up
        let dt = now - lastTime
        if dt > 0 {
            let inst = Double(max(0, bytesDone - lastBytes)) / dt
            ema = samples == 1 ? inst : alpha * inst + (1 - alpha) * ema
        }
        let eta: Double? = (samples >= 2 && ema > 1) ? Double(max(0, bytesTotal - bytesDone)) / ema : nil
        return (ema, eta)
    }
}
