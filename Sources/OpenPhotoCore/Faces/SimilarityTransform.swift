import Foundation
import CoreGraphics

/// Closed-form least-squares 2D **similarity** transform (uniform scale + rotation + translation)
/// mapping a set of source points onto a set of destination points. Used to warp a detected face
/// onto the canonical 5-point landmark template before embedding (AdaFace expects aligned crops).
///
/// Pure and deterministic ⇒ unit-tested against known transforms (no Vision/Core ML, no real faces).
public enum SimilarityTransform {

    /// Solve for the `CGAffineTransform` `t` minimizing Σ‖t(src[i]) − dst[i]‖². Requires `src.count ==
    /// dst.count ≥ 1`. With one pair (or all-coincident source points) it degrades to a pure
    /// translation. The result is a true similarity: equal scale on both axes, no shear.
    public static func solve(src: [CGPoint], dst: [CGPoint]) -> CGAffineTransform {
        precondition(src.count == dst.count && !src.isEmpty, "need matching, non-empty point sets")
        let n = CGFloat(src.count)

        var sm = CGPoint.zero, dm = CGPoint.zero
        for i in src.indices { sm.x += src[i].x; sm.y += src[i].y; dm.x += dst[i].x; dm.y += dst[i].y }
        sm.x /= n; sm.y /= n; dm.x /= n; dm.y /= n

        // a-term = Σ (s−sm)·(d−dm) ; b-term = Σ (s−sm)×(d−dm) ; varS = Σ ‖s−sm‖².
        var aNum: CGFloat = 0, bNum: CGFloat = 0, varS: CGFloat = 0
        for i in src.indices {
            let sx = src[i].x - sm.x, sy = src[i].y - sm.y
            let dx = dst[i].x - dm.x, dy = dst[i].y - dm.y
            aNum += sx * dx + sy * dy
            bNum += sx * dy - sy * dx
            varS += sx * sx + sy * sy
        }
        guard varS > 0 else { return CGAffineTransform(translationX: dm.x - sm.x, y: dm.y - sm.y) }

        let a = aNum / varS    // = scale·cosθ
        let b = bNum / varS    // = scale·sinθ
        // Similarity matrix [[a, -b], [b, a]]; translation aligns the centroids.
        let tx = dm.x - (a * sm.x - b * sm.y)
        let ty = dm.y - (b * sm.x + a * sm.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }
}
