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

@Test func videoRotationZeroIsIdentity() {
    let (t, size) = VideoRotation.render(displaySize: CGSize(width: 100, height: 200), degreesCW: 0)
    #expect(t == .identity)
    #expect(size == CGSize(width: 100, height: 200))
}

@Test func videoRotation90And270SwapDimensionsAndStayInFrame() {
    for deg in [90, 270] {
        let display = CGSize(width: 160, height: 90)
        let (t, size) = VideoRotation.render(displaySize: display, degreesCW: deg)
        #expect(abs(size.width - 90) < 0.01 && abs(size.height - 160) < 0.01)   // dimensions swapped
        #expect(fitsInFrame(display, t, size))                                   // content never clipped
    }
}

@Test func videoRotation180KeepsDimensionsAndStaysInFrame() {
    let display = CGSize(width: 160, height: 90)
    let (t, size) = VideoRotation.render(displaySize: display, degreesCW: 180)
    #expect(abs(size.width - 160) < 0.01 && abs(size.height - 90) < 0.01)
    #expect(fitsInFrame(display, t, size))
}
