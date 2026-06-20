import Foundation
import SwiftUI
import OpenPhotoCore

/// One face on the map. `pos` is in normalized projection space (~[-1,1]); rendering applies the camera.
struct FaceMapPoint: Identifiable, Sendable {
    let id: Int64            // faceID
    let personID: Int64?     // nil = unassigned
    let pos: SIMD2<Float>
}

/// Everything the map view needs, computed once per (re)load.
struct FaceMapData: Sendable {
    var points: [FaceMapPoint] = []
    /// Row-major `points.count × dim` unit face vectors, aligned with `points` — powers the live
    /// similarity lens (cosine == dot). Held in memory so the lens can recompute under the cursor.
    var vectors: [Float] = []
    var dim: Int = 512
    /// personID → its mean position (island centroid) for drawing lookalike lines / labels.
    var personCentersByID: [Int64: SIMD2<Float>] = [:]
    /// personID → a real on-island anchor point (the medoid face's position) — lines terminate here so
    /// they visibly land on the island instead of in the empty space the mean can fall into.
    var personAnchorByID: [Int64: SIMD2<Float>] = [:]
    var lookalikes: [Int64: [FaceResemblance.Lookalike]] = [:]
    /// personID → (medoidFaceID, outlierFaceIDs)
    var typicalityByID: [Int64: FaceResemblance.Typicality] = [:]
    /// personID → its centroid vector, for on-demand morph-path computation.
    var centroidsByID: [Int64: [Float]] = [:]
}

/// Pure 2D camera: maps normalized projection space → screen points. Instant updates (no animation),
/// mirroring MapView's authoritative-state pan/zoom.
struct FaceMapCamera: Equatable {
    var center: SIMD2<Float> = .zero   // projection-space point at screen center
    var scale: Float = 1               // screen points per projection unit (before fit)

    func worldToScreen(_ p: SIMD2<Float>, viewSize: CGSize, fit: Float) -> CGPoint {
        let s = scale * fit
        let x = (p.x - center.x) * s + Float(viewSize.width) / 2
        let y = (p.y - center.y) * s + Float(viewSize.height) / 2
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
    func screenToWorld(_ pt: CGPoint, viewSize: CGSize, fit: Float) -> SIMD2<Float> {
        let s = scale * fit
        return SIMD2(Float(pt.x - viewSize.width/2)/s + center.x, Float(pt.y - viewSize.height/2)/s + center.y)
    }
    /// `fit` scales the unit box to ~80% of the smaller view dimension at scale 1.
    static func fit(for viewSize: CGSize) -> Float { Float(min(viewSize.width, viewSize.height)) * 0.4 }
}
