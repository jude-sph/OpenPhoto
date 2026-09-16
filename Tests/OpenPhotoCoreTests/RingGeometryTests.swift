import Testing
@testable import OpenPhotoCore

private let g = RingGeometry()

@Test func frontCardIsCentredLargestAndVisible() {
    let p = g.placement(index: 0, count: 12, angle: 0, stageWidth: 1200)
    #expect(p.angle == 0 && abs(p.x) < 0.001 && !p.hidden && p.depth == 0)
    let side = g.placement(index: 1, count: 12, angle: 0, stageWidth: 1200)
    #expect(p.scale > side.scale && side.x < 0)                 // index 1 sits to the LEFT (mockup: x = -R sin θ)
}

@Test func placementsAreMirrorSymmetric() {
    let l = g.placement(index: 1, count: 12, angle: 0, stageWidth: 1200)
    let r = g.placement(index: 11, count: 12, angle: 0, stageWidth: 1200)
    #expect(abs(l.x + r.x) < 0.001 && abs(l.scale - r.scale) < 0.001)
}

@Test func edgeOnCardIsHiddenOnceOutsideStage() {
    // Zoom grows with stage width so the 90° edge-on point is always pushed past the edges.
    let zoom = g.zoom(forStageWidth: 1000)
    #expect(zoom > 1 && abs(zoom - (500 + g.edgeMargin) / g.edgeX) < 1e-9)
    #expect(g.placement(index: 3, count: 12, angle: 0, stageWidth: 1000).hidden)   // 90°
    #expect(g.placement(index: 3, count: 12, angle: 0, stageWidth: 3000).hidden)   // still hidden on a huge stage
    #expect(g.zoom(forStageWidth: 3000) > g.zoom(forStageWidth: 1000))
    // A stage narrower than the ring needs no zoom at all.
    #expect(g.zoom(forStageWidth: 600) == 1)
    // A card just off the front (30°) is fully visible on a 1000-pt stage.
    #expect(!g.placement(index: 1, count: 12, angle: 0, stageWidth: 1000).hidden)
}

@Test func angleWrapsAndSteps() {
    #expect(RingGeometry.wrapDelta(190) == -170 && RingGeometry.wrapDelta(-190) == 170)
    #expect(RingGeometry.step(count: 12) == 30 && RingGeometry.step(count: 0) == 360)
    let p = g.placement(index: 0, count: 12, angle: 360, stageWidth: 1200)
    #expect(abs(p.x) < 0.001 && !p.hidden)
}

@Test func radiusGrowsWithTripCountAndFloorsAtTheTunedRing() {
    // Few trips: the ring stays exactly as tuned by hand (the floor wins).
    #expect(g.radius(forCount: 4) == g.radius)
    #expect(g.radius(forCount: 11) == g.radius)
    // A dozen trips sit right at the tuned ring's limit; beyond it the ring has to grow so the
    // cards keep their distance. 21 trips (17.1° apart) need a much bigger ring.
    #expect(g.radius(forCount: 12) >= g.radius && g.radius(forCount: 12) < g.radius * 1.06)
    #expect(g.radius(forCount: 21) > 700)
    #expect(g.radius(forCount: 30) > g.radius(forCount: 21))
    #expect(g.edgeX(forCount: 21) > g.edgeX)
    #expect(g.zoom(forStageWidth: 1400, count: 21) < g.zoom(forStageWidth: 1400, count: 8))
}

@Test func manyTripsDoNotOverlapHeavily() {
    // The card beside the front one must clear (most of) the front card's projected width, or the
    // ring becomes a heap of overlapping postcards — what 21 trips looked like on a fixed R = 400.
    for n in [12, 21, 30, 48] {
        let front = g.placement(index: 0, count: n, angle: 0, stageWidth: 1400)
        let next = g.placement(index: 1, count: n, angle: 0, stageWidth: 1400)
        let frontWidth = g.cardWidth * front.scale
        #expect(abs(next.x - front.x) >= 0.95 * frontWidth, "count \(n)")
    }
}
