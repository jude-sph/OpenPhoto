import Foundation
import Accelerate

/// Portable IEEE-754 binary16 (half) <-> Float packing for embedding storage.
///
/// Uses Accelerate's vImage converters rather than `Float16(_:)` / `Float(_:)`: those concrete
/// conversion initializers are NOT available in the x86_64 Swift stdlib (arm64 only), so using them
/// breaks the Intel build. vImage produces standard little-endian IEEE binary16 — byte-identical to
/// the previous `Float16`-based encoding on arm64 — so the on-disk format is unchanged and existing
/// catalogs stay readable. (Same rationale as EmbedStage/FaceEmbedder reading MLMultiArray via NSNumber.)
enum Float16Codec {
    /// Pack floats as little-endian binary16 (half the footprint; cosine == dot for L2-normalized vecs).
    static func pack(_ v: [Float]) -> Data {
        let n = v.count
        guard n > 0 else { return Data() }
        var src = v
        var halves = [UInt16](repeating: 0, count: n)
        src.withUnsafeMutableBytes { sraw in
            halves.withUnsafeMutableBytes { draw in
                var s = vImage_Buffer(data: sraw.baseAddress, height: 1,
                                      width: vImagePixelCount(n), rowBytes: n * MemoryLayout<Float>.stride)
                var d = vImage_Buffer(data: draw.baseAddress, height: 1,
                                      width: vImagePixelCount(n), rowBytes: n * MemoryLayout<UInt16>.stride)
                _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return halves.withUnsafeBytes { Data($0) }
    }

    /// Unpack up to `dim` little-endian binary16 values back to Float (never over-reads the data).
    static func unpack(_ data: Data, dim: Int) -> [Float] {
        let n = min(dim, data.count / 2)
        guard n > 0 else { return [] }
        var halves = [UInt16](repeating: 0, count: n)
        halves.withUnsafeMutableBytes { dst in _ = data.copyBytes(to: dst, count: n * 2) }
        var out = [Float](repeating: 0, count: n)
        halves.withUnsafeMutableBytes { sraw in
            out.withUnsafeMutableBytes { draw in
                var s = vImage_Buffer(data: sraw.baseAddress, height: 1,
                                      width: vImagePixelCount(n), rowBytes: n * MemoryLayout<UInt16>.stride)
                var d = vImage_Buffer(data: draw.baseAddress, height: 1,
                                      width: vImagePixelCount(n), rowBytes: n * MemoryLayout<Float>.stride)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }
}
