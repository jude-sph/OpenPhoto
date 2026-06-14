import Foundation
import CoreGraphics
import ImageIO

/// A 64-bit perceptual image fingerprint (difference-hash / dHash) for near-duplicate detection.
/// Deterministic, no ML model: downsample to 9×8 grayscale, emit one bit per adjacent-pixel
/// comparison. Near-identical images (re-encode / resize / recompress) land within a small Hamming
/// distance; visually different images are far apart.
public enum PerceptualHash {
    /// dHash of the image at `url`, or nil if it can't be decoded.
    public static func compute(imageAt url: URL) -> Int64? {
        // Pool per call so the decode's autoreleased buffers free immediately; the parallel analysis
        // runner would otherwise accumulate them across the library and balloon memory.
        autoreleasepool {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64,
                  ] as CFDictionary) else { return nil }
            return dHash(cg)
        }
    }

    /// dHash of a CGImage: 9×8 grayscale → 64 row-wise adjacent-pixel comparisons.
    public static func dHash(_ image: CGImage) -> Int64? {
        let w = 9, h = 8
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits: UInt64 = 0
        var i = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if buf[row * w + col] > buf[row * w + col + 1] { bits |= (UInt64(1) << UInt64(i)) }
                i += 1
            }
        }
        return Int64(bitPattern: bits)
    }

    /// Number of differing bits between two dHashes.
    public static func hamming(_ a: Int64, _ b: Int64) -> Int {
        (UInt64(bitPattern: a) ^ UInt64(bitPattern: b)).nonzeroBitCount
    }
}
