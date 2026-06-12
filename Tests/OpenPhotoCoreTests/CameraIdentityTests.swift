import Testing
import Foundation
@testable import OpenPhotoCore

/// `CameraIdentity` derives the sidebar's per-connection camera id and display name from
/// raw ImageCaptureCore device facts. The id MUST be stable whether the phone is locked
/// (no serial/name yet — ICC names it "LOC:<usbLocationID>") or unlocked (serial + real
/// name resolved), so the same physical phone never forks into two sidebar rows.

@Test func cameraIDPrefersUsbLocationSoLockedAndUnlockedDedupe() {
    // Locked: no serial, placeholder name. Unlocked: serial + real name. Same USB port.
    let locked = CameraIdentity.id(usbLocationID: 1048576, serial: nil, name: "LOC:1048576")
    let unlocked = CameraIdentity.id(usbLocationID: 1048576, serial: "ABC123", name: "jude's iPhone")
    #expect(locked == unlocked)            // ← the dedup that kills the phantom "LOC:" row
    #expect(locked == "loc-1048576")
}

@Test func cameraIDFallsBackToSerialThenName() {
    #expect(CameraIdentity.id(usbLocationID: 0, serial: "S1", name: "Cam") == "serial-S1")
    #expect(CameraIdentity.id(usbLocationID: 0, serial: nil, name: "Cam") == "name-Cam")
    #expect(CameraIdentity.id(usbLocationID: 0, serial: "", name: "Cam") == "name-Cam")  // empty serial ignored
    #expect(CameraIdentity.id(usbLocationID: 0, serial: nil, name: nil) == "name-camera")
}

@Test func displayNameNeverSurfacesTheLocPlaceholder() {
    #expect(CameraIdentity.displayName("LOC:1048576") == "iPhone")
    #expect(CameraIdentity.displayName("") == "iPhone")
    #expect(CameraIdentity.displayName(nil) == "iPhone")
    #expect(CameraIdentity.displayName("jude's iPhone") == "jude's iPhone")   // real names pass through
}
