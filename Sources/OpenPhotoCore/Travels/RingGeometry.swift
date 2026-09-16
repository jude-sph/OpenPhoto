import Foundation

/// The ring's maths, ported from the browser mockup (mockups/travel-carousel-DISPOSABLE/ring.html):
/// you stand near the centre of a ring of postcards; card i sits at θ = i·step − ringAngle and is placed
/// by translateZ(−pull) · rotateY(θ) · translateZ(−R) · scale(s). The viewer looks along −z from z = +P.
/// Back-facing cards (θ ≥ 90°) are explicitly hidden—SwiftUI does not cull backfaces as the browser does.
/// Front-facing cards are hidden once fully outside the stage or about to pass the camera, so they slide
/// off edges instead of fading on screen. Pure; the SwiftUI view applies the numbers.
public struct RingGeometry: Sendable, Equatable {
    public var radius: Double = 400
    public var pull: Double = -60
    public var perspective: Double = 950
    public var cardScale: Double = 0.82
    public var cardWidth: Double = 250
    public var cardHeight: Double = 330
    public var edgeMargin: Double = 36
    public init() {}

    public struct CardPlacement: Equatable, Sendable {
        public var angle: Double     // degrees relative to the front (0 = facing you)
        public var x: Double         // projected horizontal offset from the stage centre, before zoom
        public var scale: Double     // projected scale (perspective × card scale × focus bump)
        public var depth: Double     // 0 at the front … 1 at the back (z-order + dimming)
        public var hidden: Bool
    }

    public static func step(count: Int) -> Double { count > 0 ? 360 / Double(count) : 360 }
    public static func wrapDelta(_ d: Double) -> Double {
        var x = (d + 180).truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x - 180
    }

    /// Projected |x| of a card at 90° — the edge-on point where a card turns and vanishes.
    public var edgeX: Double { radius * perspective / (perspective + pull) }

    /// Smallest zoom that pushes the edge-on point past the stage edges (1 on a very wide stage).
    public func zoom(forStageWidth w: Double) -> Double {
        max(1, (w / 2 + edgeMargin) / edgeX)
    }

    public func placement(index: Int, count: Int, angle: Double, stageWidth: Double) -> CardPlacement {
        let step = Self.step(count: count)
        let th = Self.wrapDelta(Double(index) * step - angle)
        let d = abs(th), rad = th * .pi / 180
        let focus = 1 + max(0, 1 - d / step) * 0.08
        let s = focus * cardScale
        let x = -sin(rad) * radius
        let z = -cos(rad) * radius - pull
        let dist = perspective - z
        let proj = perspective / max(dist, 1)
        let zoom = zoom(forStageWidth: stageWidth)
        // Back-facing cards (past 90°) must be hidden explicitly — SwiftUI does not cull backfaces.
        // A turned card's projected half-width shrinks with cos θ; it is off-screen once its near
        // edge passes the stage edge, or when it is about to pass through the camera.
        let halfW = cardWidth / 2 * s * proj * abs(cos(rad))
        let off = d >= 90
            || (abs(x * proj) - halfW) * zoom > stageWidth / 2 + 8
            || dist < 220
        return CardPlacement(angle: th, x: x * proj, scale: s * proj, depth: d / 180, hidden: off)
    }
}
