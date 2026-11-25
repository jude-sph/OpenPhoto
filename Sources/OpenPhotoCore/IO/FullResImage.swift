import Foundation
import ImageIO
import CoreGraphics
import CoreImage

/// Full-resolution image decode for the viewer — the FAST path (the one Quick Look and the app's own
/// thumbnailer use): ImageIO decodes the whole image up front, so nothing is deferred to a main-thread
/// `NSImage.cgImage` decode later. Safe to call off the main actor.
public enum FullResImage {
    // One shared Core Image context. Creating a CIContext allocates GPU resources, so it must be reused
    // — the viewer's old per-image `CIContext()` was a large hidden cost on every rotated photo.
    nonisolated(unsafe) private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Decode `url` at NATIVE resolution (no downscaling), fully decoded up front
    /// (`kCGImageSourceShouldCacheImmediately`), with the file's EXIF orientation applied. `extraRotationCW`
    /// (0/90/180/270 CW) is the user's display rotation, folded into the pixels on top. Returns nil if the
    /// file can't be decoded.
    public static func decode(url: URL, extraRotationCW: Int = 0) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // decode the full image, not an embedded thumb
            kCGImageSourceCreateThumbnailWithTransform: true,     // bake in EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,           // decode now (off-main), not lazily at draw
        ]
        // Cap the long side at the native size → full resolution, never upscaled/downscaled.
        if max(w, h) > 0 { opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h) }
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return applyRotation(oriented, degreesCW: extraRotationCW)
    }

    /// Apply the user's display rotation to an already-oriented CGImage, via the shared CIContext.
    /// (Mirrors the viewer's prior orientation mapping.)
    public static func applyRotation(_ image: CGImage, degreesCW: Int) -> CGImage {
        let d = ((degreesCW % 360) + 360) % 360
        guard d != 0 else { return image }
        let orient: CGImagePropertyOrientation = d == 90 ? .right : (d == 180 ? .down : .left)
        let ci = CIImage(cgImage: image).oriented(orient)
        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }
}
