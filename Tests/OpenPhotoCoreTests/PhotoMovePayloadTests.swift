import Testing
import Foundation
@testable import OpenPhotoCore

@Test func photoMovePayloadRoundTripsAndRejectsFolderPaths() throws {
    let ids = ["vault-1|2025/rome/IMG_1.jpg", "vault-1|2025/rome/IMG 2 (2).jpg", "v|émojí📷.jpg"]
    let encoded = PhotoMovePayload.encode(ids)
    #expect(PhotoMovePayload.decode(encoded) == ids)
    // A plain folder path (what folder drags carry) is NOT a photo payload.
    #expect(PhotoMovePayload.decode("2025/rome") == nil)
    #expect(PhotoMovePayload.decode("") == nil)
    // Marker without valid JSON is rejected, not crashed on.
    #expect(PhotoMovePayload.decode("photos:notjson") == nil)
    #expect(PhotoMovePayload.decode(PhotoMovePayload.encode([])) == [])
}
