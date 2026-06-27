import Testing
@testable import OpenPhotoCore

@Test func rateMeterSteadySpeedAndEta() {
    var m = SyncRateMeter()
    let total: Int64 = 1000
    _ = m.update(bytesDone: 0, bytesTotal: total, now: 0)          // warm-up
    let a = m.update(bytesDone: 100, bytesTotal: total, now: 1)    // 100 B in 1 s = 100 B/s
    #expect(abs(a.speed - 100) < 1)
    #expect(a.eta != nil)
    #expect(abs(a.eta! - 9) < 0.5)                                 // (1000-100)/100 = 9 s
    let b = m.update(bytesDone: 200, bytesTotal: total, now: 2)    // 200 B in 2 s = 100 B/s
    #expect(abs(b.speed - 100) < 1)
    #expect(abs(b.eta! - 8) < 0.5)                                 // (1000-200)/100 = 8 s
}

@Test func rateMeterNoSpeedUntilWarm() {
    var m = SyncRateMeter()
    #expect(m.update(bytesDone: 0, bytesTotal: 100, now: 0).eta == nil)     // elapsed 0
    #expect(m.update(bytesDone: 10, bytesTotal: 100, now: 0.2).eta == nil)  // 0.2 < 0.5 warm-up
    #expect(m.update(bytesDone: 30, bytesTotal: 100, now: 0.5).eta != nil)  // 0.5 ≥ 0.5
}

@Test func rateMeterIsWholeJobAverageNotWindowed() {
    // Whole-job: a burst then a long stall reports the OVERALL average — it must NOT crater to zero
    // the way a short window would while a large file flushes to a slow drive.
    var m = SyncRateMeter()
    _ = m.update(bytesDone: 0, bytesTotal: 1_000_000, now: 0)
    _ = m.update(bytesDone: 500_000, bytesTotal: 1_000_000, now: 1)        // 500 KB in 1 s
    let r = m.update(bytesDone: 500_000, bytesTotal: 1_000_000, now: 10)   // 9 s with no new bytes
    #expect(abs(r.speed - 50_000) < 1)        // 500_000 B / 10 s = 50 KB/s — still meaningful, not 0
    #expect(r.speed > 0)
    #expect(abs(r.eta! - 10) < 0.5)           // (1_000_000-500_000)/50_000 = 10 s
}
