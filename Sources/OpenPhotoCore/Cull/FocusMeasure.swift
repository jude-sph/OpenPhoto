import Foundation
import CoreGraphics

/// Sharpness estimate via the variance of the Laplacian (a focus measure). Higher = sharper.
/// Used to pick the in-focus frame of a burst. Pure; operates on a (cached) CGImage.
public enum FocusMeasure {
    public static func varianceOfLaplacian(_ image: CGImage) -> Double {
        let w = min(image.width, 256), h = min(image.height, 256)
        guard w > 2, h > 2 else { return 0 }
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(buf[y * w + x])
                let lap = 4 * c - Double(buf[(y - 1) * w + x]) - Double(buf[(y + 1) * w + x])
                              - Double(buf[y * w + x - 1]) - Double(buf[y * w + x + 1])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}
