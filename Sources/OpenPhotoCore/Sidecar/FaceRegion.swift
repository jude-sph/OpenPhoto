import Foundation
import CoreGraphics

/// A human-confirmed face region as it appears in a sidecar. Stored in the catalog's Vision frame
/// (normalized boundingBox, bottom-left origin, lower-left corner) and written to XMP as an MWG
/// `Area` (center + size, TOP-left origin). The two reps are converted symmetrically here.
public struct FaceRegion: Sendable, Equatable {
    public let name: String
    public let visionRect: CGRect          // Vision normalized boundingBox (bottom-left origin)

    public init(name: String, visionRect: CGRect) {
        self.name = name
        self.visionRect = visionRect
    }

    /// MWG `stArea` values: center point with top-left origin, normalized size.
    public struct MWGArea: Sendable, Equatable {
        public let cx: Double   // region center x, top-left origin
        public let cy: Double   // region center y, top-left origin
        public let w: Double    // normalized width
        public let h: Double    // normalized height
    }

    /// Vision lower-left corner (bottom-left origin) → MWG center (top-left origin).
    ///
    /// Vision `boundingBox`: origin = bottom-left corner; y increases upward.
    /// MWG `stArea`: x/y = region CENTER; y increases downward (top-left origin).
    ///
    /// Conversion:
    ///   cx = rect.midX                (x-axis unchanged)
    ///   cy = 1 − rect.midY            (flip y: Vision midY from bottom → distance from top)
    public static func mwgArea(fromVision r: CGRect) -> MWGArea {
        let cx = Double(r.midX)
        let cy = 1.0 - Double(r.midY)   // flip y to top-left origin
        return MWGArea(cx: cx, cy: cy, w: Double(r.width), h: Double(r.height))
    }

    /// MWG center (top-left origin) → Vision lower-left corner (bottom-left origin).
    ///
    /// Inverse of `mwgArea(fromVision:)`:
    ///   midY_bottom = 1 − cy          (flip y back)
    ///   origin_y    = midY_bottom − h/2
    public static func visionRect(fromMWG a: MWGArea) -> CGRect {
        let midYBottom = 1.0 - a.cy
        return CGRect(
            x: a.cx - a.w / 2,
            y: midYBottom - a.h / 2,
            width: a.w,
            height: a.h
        )
    }
}
