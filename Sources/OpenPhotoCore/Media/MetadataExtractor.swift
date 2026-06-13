import Foundation
import ImageIO
import AVFoundation

public enum MetadataExtractor {
    /// EXIF "yyyy:MM:dd HH:mm:ss" — interpreted in the local calendar
    /// (EXIF has no zone; this matches what every photo tool does).
    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func extract(from url: URL, kind: MediaKind) async -> MediaMetadata {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? Date()
        // Provisional date: a capture stamp parsed from the filename when present (phone/camcorder
        // names like 20190101_000146.mp4 carry the real time, and a copy/move resets the file's
        // mtime), else the file's modified date. Embedded EXIF/QuickTime dates below override this
        // whenever the file actually carries one.
        var m = MediaMetadata(takenAt: FilenameDate.parse(url.lastPathComponent) ?? mtime)
        switch kind {
        case .photo: extractImage(url, into: &m)
        case .video: await extractVideo(url, into: &m)
        }
        return m
    }

    private static func extractImage(_ url: URL, into m: inout MediaMetadata) {
        // Pool the ImageIO source + bridged CFDictionaries so they drain per file. Without it these
        // autoreleased property dicts accumulate across the whole scan — a major cause of runaway
        // memory while indexing a large library.
        autoreleasepool {
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
    }

    private static func extractVideo(_ url: URL, into m: inout MediaMetadata) async {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            m.durationSeconds = CMTimeGetSeconds(d)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            m.pixelWidth = Int(abs(size.width))
            m.pixelHeight = Int(abs(size.height))
        }
        // Embedded capture date: prefer the common creation-date metadata, then the asset-level
        // creationDate (which surfaces dates stored in the moov/mvhd header that the common
        // metadata can miss). Only a real embedded date overrides the filename/mtime provisional.
        let meta = (try? await asset.load(.metadata)) ?? []
        var embedded: Date?
        if let created = meta.first(where: { $0.commonKey == .commonKeyCreationDate }),
           let s = try? await created.load(.stringValue) {
            embedded = ISO8601Millis.date(from: s) ?? ISO8601Millis.dateLenient(from: s)
        }
        if embedded == nil, let item = try? await asset.load(.creationDate) {
            if let d = try? await item.load(.dateValue) {
                embedded = d
            } else if let s = try? await item.load(.stringValue) {
                embedded = ISO8601Millis.date(from: s) ?? ISO8601Millis.dateLenient(from: s)
            }
        }
        if let embedded { m.takenAt = embedded }
        if let cid = meta.first(where: {
            $0.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier"
        }), let s = try? await cid.load(.stringValue) {
            m.contentIdentifier = s
        }
    }
}
