import Foundation
import CoreGraphics

/// Pure geometry for rotating a video frame in an AVFoundation video composition. Kept out of the
/// AV layer so it can be unit-tested without a player: the returned transform maps a `displaySize`
/// rect (the video as preferredTransform orients it) so the rotated frame exactly fills
/// `[0, renderSize]` — guaranteeing the content is never clipped or pushed off-frame.
public enum VideoRotation {
    public static func render(displaySize: CGSize, degreesCW: Int) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let d = ((degreesCW % 360) + 360) % 360
        guard d == 90 || d == 180 || d == 270 else { return (.identity, displaySize) }
        let angle = CGFloat(d) * .pi / 180          // AV render space is y-down → positive = clockwise
        let r = CGAffineTransform(rotationAngle: angle)
        let corners = [CGPoint(x: 0, y: 0),
                       CGPoint(x: displaySize.width, y: 0),
                       CGPoint(x: 0, y: displaySize.height),
                       CGPoint(x: displaySize.width, y: displaySize.height)].map { $0.applying(r) }
        let minX = corners.map(\.x).min() ?? 0, minY = corners.map(\.y).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0, maxY = corners.map(\.y).max() ?? 0
        // Rotate, then translate the rotated bounding box back to the origin.
        let transform = r.concatenating(CGAffineTransform(translationX: -minX, y: -minY))
        return (transform, CGSize(width: maxX - minX, height: maxY - minY))
    }
}
