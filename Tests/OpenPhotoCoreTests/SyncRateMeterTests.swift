import Testing
@testable import OpenPhotoCore

@Test func rateMeterSteadySpeedAndEta() {
    var m = SyncRateMeter(alpha: 0.5)
    let total: Int64 = 1000
    var out = m.update(bytesDone: 0, bytesTotal: total, now: 0)     // first sample: warm-up
    #expect(out.eta == nil)
    out = m.update(bytesDone: 100, bytesTotal: total, now: 1)       // 100 B/s
    out = m.update(bytesDone: 200, bytesTotal: total, now: 2)       // steady 100 B/s
    #expect(abs(out.speed - 100) < 1)
    #expect(out.eta != nil)
    #expect(abs(out.eta! - 8) < 0.5)                                // (1000-200)/100 = 8s
}

@Test func rateMeterNoEtaUntilWarm() {
    var m = SyncRateMeter()
    #expect(m.update(bytesDone: 0, bytesTotal: 100, now: 0).eta == nil)
    #expect(m.update(bytesDone: 10, bytesTotal: 100, now: 1).eta == nil)  // only 1 interval
}
