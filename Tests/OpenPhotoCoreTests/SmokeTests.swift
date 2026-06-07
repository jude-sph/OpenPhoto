import Testing
@testable import OpenPhotoCore

@Test func smoke() {
    #expect(ContentHash(stringValue: "x").stringValue == "x")
}
