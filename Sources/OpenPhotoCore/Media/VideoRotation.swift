import Foundation
import CoreGraphics

/// Pure geometry for rotating a video frame in an AVFoundation video composition. Kept out of the
/// AV layer so it can be unit-tested without a player: the returned transform maps a `displaySize`
/// rect (the video as preferredTransform orients it) so the rotated frame exactly fills
/// `[0, renderSize]` — guaranteeing the content is never clipped or pushed off-frame.
public enum VideoRotation {
    /// Transform + render size for a video track, applying the track's `preferred` orientation and an
    /// extra user rotation of `degreesCW` clockwise. Computed by transforming the natural-size frame's
    /// four corners and taking their actual bounding box — so the result always fills `[0, renderSize]`
    /// exactly (no clipping, no off-frame strip), regardless of how the two transforms compose.
    public static func render(naturalSize: CGSize, preferred: CGAffineTransform,
                              degreesCW: Int) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let d = ((degreesCW % 360) + 360) % 360
        let rot = d == 0 ? .identity : CGAffineTransform(rotationAngle: CGFloat(d) * .pi / 180)
        let combined = preferred.concatenating(rot)   // orient, then apply the user rotation
        let corners = [CGPoint(x: 0, y: 0),
                       CGPoint(x: naturalSize.width, y: 0),
                       CGPoint(x: 0, y: naturalSize.height),
                       CGPoint(x: naturalSize.width, y: naturalSize.height)].map { $0.applying(combined) }
        let minX = corners.map(\.x).min() ?? 0, minY = corners.map(\.y).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0, maxY = corners.map(\.y).max() ?? 0
        // Translate the real bounding box to the origin so the content fills the render size.
        let transform = combined.concatenating(CGAffineTransform(translationX: -minX, y: -minY))
        return (transform, CGSize(width: maxX - minX, height: maxY - minY))
    }
}
