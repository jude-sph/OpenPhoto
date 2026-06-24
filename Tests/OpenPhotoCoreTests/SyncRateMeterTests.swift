import Testing
@testable import OpenPhotoCore

@Test func rateMeterSteadySpeedAndEta() {
    var m = SyncRateMeter(window: 3.0, minSpan: 0.4)
    let total: Int64 = 1000
    _ = m.update(bytesDone: 0, bytesTotal: total, now: 0)          // span 0 → warm-up
    let a = m.update(bytesDone: 100, bytesTotal: total, now: 1)    // 100 B over 1 s
    #expect(abs(a.speed - 100) < 1)
    #expect(a.eta != nil)
    #expect(abs(a.eta! - 9) < 0.5)                                 // (1000-100)/100 = 9 s (whole job)
    let b = m.update(bytesDone: 200, bytesTotal: total, now: 2)    // steady 100 B/s
    #expect(abs(b.speed - 100) < 1)
    #expect(abs(b.eta! - 8) < 0.5)                                 // (1000-200)/100 = 8 s
}

@Test func rateMeterNoSpeedUntilWarm() {
    var m = SyncRateMeter(window: 3.0, minSpan: 0.4)
    #expect(m.update(bytesDone: 0, bytesTotal: 100, now: 0).eta == nil)     // span 0
    #expect(m.update(bytesDone: 10, bytesTotal: 100, now: 0.2).eta == nil)  // span 0.2 < 0.4
    #expect(m.update(bytesDone: 30, bytesTotal: 100, now: 0.5).eta != nil)  // span 0.5 ≥ 0.4
}

@Test func rateMeterSmoothsBursts() {
    // A cached/duplicate file copies in a blink (big bytes over ~0 time), then ~nothing for a second.
    // The windowed average must NOT report the instantaneous 500 MB/s spike.
    var m = SyncRateMeter(window: 3.0, minSpan: 0.4)
    _ = m.update(bytesDone: 0, bytesTotal: 1_000_000, now: 0)
    _ = m.update(bytesDone: 500_000, bytesTotal: 1_000_000, now: 0.001)
    let r = m.update(bytesDone: 500_100, bytesTotal: 1_000_000, now: 1.0)
    #expect(r.speed < 600_000)            // ≈ 500_100 B / 1 s, not 500_000 / 0.001
}
