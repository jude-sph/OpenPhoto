import Testing
import Foundation
@testable import OpenPhotoCore

private let cal = Calendar.current

private func comps(_ d: Date) -> (y: Int, mo: Int, day: Int, h: Int, mi: Int, s: Int) {
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    return (c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
}

@Test func parsesSamsungStyleDateTime() {
    let d = FilenameDate.parse("20190101_000146.mp4")
    #expect(d != nil)
    let c = comps(d!)
    #expect((c.y, c.mo, c.day, c.h, c.mi, c.s) == (2019, 1, 1, 0, 1, 46))
}

@Test func parsesPrefixedAndMillisecondNames() {
    for name in ["VID_20210704_153000.mov", "IMG_20210704_153000.jpg", "PXL_20210704_153000123.mp4"] {
        let c = comps(FilenameDate.parse(name)!)
        #expect((c.y, c.mo, c.day, c.h, c.mi, c.s) == (2021, 7, 4, 15, 30, 0), "\(name)")
    }
}

@Test func parsesHyphenAndDotSeparatedScreenshot() {
    let c = comps(FilenameDate.parse("Screenshot 2022-12-25 at 09.08.07.png")!)
    #expect((c.y, c.mo, c.day) == (2022, 12, 25))
}

@Test func parsesWhatsAppDateOnlyToNoon() {
    let d = FilenameDate.parse("VID-20200815-WA0007.mp4")
    #expect(d != nil)
    let c = comps(d!)
    #expect((c.y, c.mo, c.day, c.h) == (2020, 8, 15, 12))   // date-only → noon
}

@Test func rejectsNonDateDigitRuns() {
    #expect(FilenameDate.parse("IMG_1234.JPG") == nil)
    #expect(FilenameDate.parse("DSC_0123.jpg") == nil)
    #expect(FilenameDate.parse("clip_1920x1080.mp4") == nil)        // resolution, not a date
    #expect(FilenameDate.parse("20231345_000000.mp4") == nil)       // month 13 / impossible
    #expect(FilenameDate.parse("18990101_000000.mp4") == nil)       // year out of range
    #expect(FilenameDate.parse("no digits here.mov") == nil)
}

@Test func skipsInvalidLeadingRunForLaterValidDate() {
    // The first regex match (2023-13-45) is range-invalid; the parser must keep scanning and
    // return the later valid stamp rather than bailing on the first hit.
    let c = comps(FilenameDate.parse("20231345 backup 20190101_000146.mp4")!)
    #expect((c.y, c.mo, c.day, c.h, c.mi, c.s) == (2019, 1, 1, 0, 1, 46))
}
