import Testing
import CoreGraphics
@testable import OpenPhotoCore

private func fitsInFrame(_ size: CGSize, _ t: CGAffineTransform, _ render: CGSize) -> Bool {
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                   CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
    return corners.map { $0.applying(t) }.allSatisfy {
        $0.x >= -0.01 && $0.x <= render.width + 0.01 && $0.y >= -0.01 && $0.y <= render.height + 0.01
    }
}

@Test func videoRotationZeroNoPreferredFillsFrame() {
    let nat = CGSize(width: 1920, height: 1080)
    let (t, size) = VideoRotation.render(naturalSize: nat, preferred: .identity, degreesCW: 0)
    #expect(abs(size.width - 1920) < 0.01 && abs(size.height - 1080) < 0.01)
    #expect(fitsInFrame(nat, t, size))
}

@Test func videoRotation90And270SwapDimensionsAndFillFrame() {
    let nat = CGSize(width: 1920, height: 1080)
    for deg in [90, 270] {
        let (t, size) = VideoRotation.render(naturalSize: nat, preferred: .identity, degreesCW: deg)
        #expect(abs(size.width - 1080) < 0.01 && abs(size.height - 1920) < 0.01)   // swapped
        #expect(fitsInFrame(nat, t, size))                                          // content fills it
        #expect(size.width * size.height > 0)
    }
}

@Test func videoRotationComposesWithPreferredAndFillsFrame() {
    // A portrait phone video: landscape sensor + a 90°-CW preferredTransform.
    let nat = CGSize(width: 1920, height: 1080)
    let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    let (t, size) = VideoRotation.render(naturalSize: nat, preferred: preferred, degreesCW: 90)
    #expect(fitsInFrame(nat, t, size))                                  // never clipped/off-frame
    #expect(abs(size.width - 1920) < 0.01 && abs(size.height - 1080) < 0.01)  // 90 preferred + 90 user = landscape
}
