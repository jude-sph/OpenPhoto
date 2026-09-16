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
    // At 90° the projected centre is R·P/(P+pull) ≈ 427 pt; with zoom applied it must sit past the edge.
    let zoom = g.zoom(forStageWidth: 1000)
    #expect(zoom > 1)
    let edge = g.placement(index: 3, count: 12, angle: 0, stageWidth: 1000)   // 90°
    #expect(edge.hidden)
    let wide = g.placement(index: 3, count: 12, angle: 0, stageWidth: 3000)   // huge stage: still on screen
    #expect(!wide.hidden && g.zoom(forStageWidth: 3000) == 1)
}

@Test func angleWrapsAndSteps() {
    #expect(RingGeometry.wrapDelta(190) == -170 && RingGeometry.wrapDelta(-190) == 170)
    #expect(RingGeometry.step(count: 12) == 30 && RingGeometry.step(count: 0) == 360)
    let p = g.placement(index: 0, count: 12, angle: 360, stageWidth: 1200)
    #expect(abs(p.x) < 0.001 && !p.hidden)
}
