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
    /// How much of the stage's height the front postcard should try to fill, and the pt band that
    /// target is clamped into — a big ring (many trips) would otherwise leave it a stamp.
    public var frontTargetFraction: Double = 0.38
    public var frontTargetRange: ClosedRange<Double> = 280...420
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

    /// The ring the cards actually stand on. `radius` is the hand-tuned ring, which holds while the
    /// cards have room; past that the step between cards shrinks with every trip added (21 trips are
    /// 17.1° apart, not 30°) and a fixed ring would pile the postcards on top of each other. The
    /// chord between neighbouring card centres is 2·R·sin(step/2), so the smallest ring that keeps
    /// a card's own width (plus a 6% gap) between neighbours is w/(2·sin(step/2)) — never smaller
    /// than the tuned ring.
    public func radius(forCount count: Int) -> Double {
        let step = Self.step(count: count) * .pi / 180
        let half = sin(step / 2)
        guard half > 0.0001 else { return radius }
        return max(radius, cardWidth * cardScale * 1.06 / (2 * half))
    }

    /// Projected |x| of a card at 90° — the edge-on point where a card turns and vanishes.
    /// (The tuned ring; `edgeX(forCount:)` is the one an actual ring of `count` cards has.)
    public var edgeX: Double { radius * perspective / (perspective + pull) }

    public func edgeX(forCount count: Int) -> Double {
        radius(forCount: count) * perspective / (perspective + pull)
    }

    /// Smallest zoom that pushes the edge-on point past the stage edges (1 on a very wide stage).
    public func zoom(forStageWidth w: Double) -> Double {
        max(1, (w / 2 + edgeMargin) / edgeX)
    }

    public func zoom(forStageWidth w: Double, count: Int) -> Double {
        max(1, (w / 2 + edgeMargin) / edgeX(forCount: count))
    }

    /// Height the front card (θ = 0: focus bump 1.08, z = −R − pull, so dist = P + R + pull) draws
    /// at before the stage zoom is applied.
    public func frontProjectedHeight(forCount count: Int) -> Double {
        cardHeight * cardScale * 1.08 * perspective / (perspective + radius(forCount: count) + pull)
    }

    /// The zoom the stage actually uses: the wider of two rules — push the edge-on point past the
    /// stage edges (above), and give the front card a decent share of the stage's height. With many
    /// trips the ring grows and the first rule alone leaves the front postcard tiny and far away.
    /// A stage of no height falls back to the width rule alone.
    public func zoom(forStageWidth w: Double, stageHeight h: Double, count: Int) -> Double {
        let edgeZoom = zoom(forStageWidth: w, count: count)
        guard h > 0 else { return edgeZoom }
        let targetH = min(max(h * frontTargetFraction, frontTargetRange.lowerBound), frontTargetRange.upperBound)
        return max(edgeZoom, targetH / frontProjectedHeight(forCount: count))
    }

    public func placement(index: Int, count: Int, angle: Double, stageWidth: Double, stageHeight: Double = 0) -> CardPlacement {
        let step = Self.step(count: count)
        let th = Self.wrapDelta(Double(index) * step - angle)
        let d = abs(th), rad = th * .pi / 180
        let focus = 1 + max(0, 1 - d / step) * 0.08
        let s = focus * cardScale
        let r = radius(forCount: count)
        let x = -sin(rad) * r
        let z = -cos(rad) * r - pull
        let dist = perspective - z
        let proj = perspective / max(dist, 1)
        let zoom = zoom(forStageWidth: stageWidth, stageHeight: stageHeight, count: count)
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
