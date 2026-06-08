import Foundation
import ImageIO
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

/// Content-addressed JPEG thumbnail cache: <cacheDir>/<hex[0..2]>/<hex>.jpg
/// Cache survives eviction — that's what keeps offline photos browsable.
public final class ThumbnailStore: Sendable {
    public static let maxPixel = 512
    private let cacheDir: URL

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

    public func cacheURL(for hash: ContentHash) -> URL {
        let hex = String(hash.stringValue.split(separator: ":").last ?? "x")
        return cacheDir.appendingPathComponent(String(hex.prefix(2)))
            .appendingPathComponent(hex + ".jpg")
    }

    /// Returns cached thumb, generating it from sourceURL if absent.
    /// Deviation from spec: made async so video frame-grab uses the non-deprecated
    /// `AVAssetImageGenerator.image(at:)` async API (copyCGImage is deprecated on macOS 15).
    public func thumbnail(for hash: ContentHash, sourceURL: URL, kind: MediaKind) async throws -> CGImage? {
        let cached = cacheURL(for: hash)
        if let src = CGImageSourceCreateWithURL(cached as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        guard let img = try await generate(from: sourceURL, kind: kind) else { return nil }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(cached as CFURL,
                                                      UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return img
    }

    /// A display-sized thumbnail, downsampled from the cached 512px thumb, so small
    /// grid cells don't hand the compositor oversized GPU textures (a screen full of
    /// 512px textures hitches on Space switches). Ensures the canonical cache exists,
    /// then decodes the cached JPEG at `maxPixel` (capped at the stored size).
    public func displayImage(for hash: ContentHash, sourceURL: URL, kind: MediaKind,
                             maxPixel: Int) async throws -> CGImage? {
        let cached = cacheURL(for: hash)
        if !FileManager.default.fileExists(atPath: cached.path) {
            _ = try await thumbnail(for: hash, sourceURL: sourceURL, kind: kind)
        }
        guard let src = CGImageSourceCreateWithURL(cached as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(maxPixel, 1), Self.maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private func generate(from url: URL, kind: MediaKind) async throws -> CGImage? {
        switch kind {
        case .photo:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: Self.maxPixel, height: Self.maxPixel)
            let result = try await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            return result.image
        }
    }
}
