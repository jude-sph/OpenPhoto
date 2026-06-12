import Testing
import Foundation
@testable import OpenPhotoCore

@Test func candidateNamesCoverGoogleQuirks() {
    let plain = TakeoutJSONMatcher.candidateJSONNames(forMediaFilename: "IMG_1234.JPG")
    #expect(plain.contains("IMG_1234.JPG.json"))
    #expect(plain.contains("IMG_1234.JPG.supplemental-metadata.json"))

    // Counter quirk: Google moves "(1)" to after the extension on the JSON.
    let counter = TakeoutJSONMatcher.candidateJSONNames(forMediaFilename: "IMG_1234(1).JPG")
    #expect(counter.contains("IMG_1234.JPG(1).json"))
    #expect(counter.contains("IMG_1234(1).JPG.json"))
}

@Test func resolvesJSONInDirectory() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("album")
    try t.file("album/IMG_1.JPG", Data([0xFF]))
    try t.file("album/IMG_1.JPG.supplemental-metadata.json", Data("{}".utf8))
    let found = TakeoutJSONMatcher.jsonURL(forMediaNamed: "IMG_1.JPG", in: dir)
    #expect(found?.lastPathComponent == "IMG_1.JPG.supplemental-metadata.json")

    #expect(TakeoutJSONMatcher.jsonURL(forMediaNamed: "missing.JPG", in: dir) == nil)
}
