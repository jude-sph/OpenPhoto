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
