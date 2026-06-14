import Foundation
import ImageIO
import CoreGraphics
import AVFoundation

/// Shared import-grid thumbnail generation for file-based sources (folders, volumes, Takeout, XMP
/// exports). A photo thumbnails via ImageIO; a VIDEO needs a decoded frame via AVAssetImageGenerator
/// — `CGImageSource` returns nil for video files, which is why videos previously showed as black tiles.
public enum ImportThumbnail {
    public static func make(url: URL, kind: MediaKind, maxPixel: Int) async -> CGImage? {
        if kind == .video { return await videoFrame(url: url, maxPixel: maxPixel) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    private static func videoFrame(url: URL, maxPixel: Int) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true      // honor rotation
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        // A frame ~1s in (skips a black first frame); fall back to the very start for short clips.
        if let img = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
            return img
        }
        return try? await gen.image(at: .zero).image
    }
}
