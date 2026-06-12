import Testing
import Foundation
@testable import OpenPhotoCore

@Test func parsesTakeoutJSONFields() throws {
    let json = """
    {
      "title": "IMG_1234.JPG",
      "description": "Beach trip",
      "photoTakenTime": { "timestamp": "1600000000", "formatted": "..." },
      "geoData": { "latitude": 51.5, "longitude": -0.12, "altitude": 0.0 },
      "favorited": true
    }
    """
    let m = try #require(TakeoutMetadata.parse(Data(json.utf8)))
    #expect(m.description == "Beach trip")
    #expect(m.favorited == true)
    #expect(abs((m.latitude ?? 0) - 51.5) < 0.0001)
    #expect(abs((m.longitude ?? 0) - (-0.12)) < 0.0001)
    #expect(m.takenAt == Date(timeIntervalSince1970: 1_600_000_000))
}

@Test func treatsZeroGeoAsAbsentAndMissingFavoriteAsFalse() throws {
    let json = """
    { "photoTakenTime": { "timestamp": "1600000000" },
      "geoData": { "latitude": 0.0, "longitude": 0.0 } }
    """
    let m = try #require(TakeoutMetadata.parse(Data(json.utf8)))
    #expect(m.latitude == nil)        // 0,0 is Google's "no location" sentinel
    #expect(m.longitude == nil)
    #expect(m.favorited == false)
    #expect(m.description == nil)
}
