import Foundation
import ImageIO
import AVFoundation

public enum MetadataExtractor {
    /// EXIF "yyyy:MM:dd HH:mm:ss" — interpreted in the local calendar
    /// (EXIF has no zone; this matches what every photo tool does).
    nonisolated(unsafe) private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func extract(from url: URL, kind: MediaKind) -> MediaMetadata {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? Date()
        var m = MediaMetadata(takenAt: mtime)
        switch kind {
        case .photo: extractImage(url, into: &m)
        case .video: extractVideo(url, into: &m)
        }
        return m
    }

    private static func extractImage(_ url: URL, into m: inout MediaMetadata) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return }
        m.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        m.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let d = exifDate.date(from: s) { m.takenAt = d }
            m.lensModel = exif[kCGImagePropertyExifLensModel] as? String
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            m.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            m.latitude = latRef == "S" ? -lat : lat
            m.longitude = lonRef == "W" ? -lon : lon
        }
        if let apple = props[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any] {
            // Key "17" holds the Live Photo content identifier in Apple maker notes.
            m.contentIdentifier = apple["17" as CFString] as? String
        }
    }

    private static func extractVideo(_ url: URL, into m: inout MediaMetadata) {
        // AVFoundation loading is async-only; bridge to sync via a probe struct
        // (this always runs on scanner background threads, never the main thread).
        struct VideoProbe: Sendable {
            var width: Int?; var height: Int?
            var duration: Double?; var takenAt: Date?; var contentID: String?
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var probe = VideoProbe()
        Task.detached {
            var p = VideoProbe()
            defer { probe = p; sem.signal() }
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration) {
                p.duration = CMTimeGetSeconds(d)
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                p.width = Int(abs(size.width))
                p.height = Int(abs(size.height))
            }
            if let meta = try? await asset.load(.metadata) {
                if let created = meta.first(where: { $0.commonKey == .commonKeyCreationDate }),
                   let s = try? await created.load(.stringValue) {
                    p.takenAt = ISO8601Millis.date(from: s) ?? ISO8601DateFormatter().date(from: s)
                }
                if let cid = meta.first(where: {
                    $0.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier"
                }), let s = try? await cid.load(.stringValue) {
                    p.contentID = s
                }
            }
        }
        sem.wait()
        m.pixelWidth = probe.width
        m.pixelHeight = probe.height
        m.durationSeconds = probe.duration
        if let d = probe.takenAt { m.takenAt = d }
        m.contentIdentifier = probe.contentID
    }
}
