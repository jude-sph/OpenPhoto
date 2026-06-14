import Testing
@testable import OpenPhotoCore

@Test func defaultSensitivityReproducesCurrentConstants() {
    let p = FaceClusterParams.forSensitivity(0.5)
    #expect(abs(p.eps - 0.50) < 1e-9)
    #expect(p.minPts == 3)
    #expect(abs(p.matchThreshold - 0.55) < 1e-9)
}

@Test func strictAndLooseEndpoints() {
    let strict = FaceClusterParams.forSensitivity(0.0)
    #expect(abs(strict.eps - 0.45) < 1e-9)
    #expect(strict.minPts == 4)
    #expect(abs(strict.matchThreshold - 0.50) < 1e-9)

    let loose = FaceClusterParams.forSensitivity(1.0)
    #expect(abs(loose.eps - 0.60) < 1e-9)
    #expect(loose.minPts == 2)
    #expect(abs(loose.matchThreshold - 0.60) < 1e-9)
}

@Test func looserIsMorePermissiveThanStricter() {
    let strict = FaceClusterParams.forSensitivity(0.2)
    let loose = FaceClusterParams.forSensitivity(0.8)
    #expect(loose.eps > strict.eps)                 // bigger neighbourhood
    #expect(loose.minPts <= strict.minPts)          // sparser clusters allowed
    #expect(loose.matchThreshold > strict.matchThreshold)
}

@Test func clampsOutOfRangeInput() {
    #expect(FaceClusterParams.forSensitivity(-3) == FaceClusterParams.forSensitivity(0))
    #expect(FaceClusterParams.forSensitivity(9) == FaceClusterParams.forSensitivity(1))
}
