import Foundation
import ImageIO
import CoreGraphics

/// Lossless read/write of standard EXIF + XMP metadata inside image files. The
/// import-time "fold" (Takeout JSON / Apple favorite → self-describing file) and
/// the scanner's embedded-metadata read both go through here, reusing the same
/// `XMP.serialize`/`XMP.parse` as the `.openphoto/` sidecars. Pixels are never
/// recompressed (CGImageDestinationCopyImageSource copies the encoded image).
public enum EmbeddedMetadata {
    public enum EmbedError: Error { case unreadable, badXMP, cantWrite }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Write `data` (as an XMP packet) plus optional EXIF date/GPS into the image,
    /// losslessly, replacing the file in place. A no-op if there is nothing to write.
    public static func embed(_ data: SidecarData, exifDate: Date?,
                             latitude: Double?, longitude: Double?,
                             intoImageAt url: URL) throws {
        if data == .empty && exifDate == nil && latitude == nil { return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { throw EmbedError.unreadable }

        // Start from our XMP packet; mutate to add EXIF/GPS tags.
        let meta: CGMutableImageMetadata
        if data != .empty {
            // `XMP.serialize` emits a full sidecar packet (BOM + <?xpacket?> PIs);
            // `CGImageMetadataCreateFromXMPData` only accepts the bare <x:xmpmeta>
            // element, so hand it just that slice.
            let xmpData = Data(bareXMP(XMP.serialize(data)).utf8)
            guard let base = CGImageMetadataCreateFromXMPData(xmpData as CFData),
                  let mutable = CGImageMetadataCreateMutableCopy(base) else { throw EmbedError.badXMP }
            meta = mutable
        } else {
            meta = CGImageMetadataCreateMutable()
        }
        if let exifDate {
            CGImageMetadataSetValueMatchingImageProperty(
                meta, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal,
                exifDateFormatter.string(from: exifDate) as CFString)
        }
        if let latitude, let longitude {
            func set(_ dict: CFString, _ key: CFString, _ value: CFTypeRef) {
                CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, value)
            }
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(latitude) as CFNumber)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (latitude >= 0 ? "N" : "S") as CFString)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(longitude) as CFNumber)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (longitude >= 0 ? "E" : "W") as CFString)
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw EmbedError.cantWrite
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: kCFBooleanTrue as Any,
        ]
        var err: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err)
        guard ok else { throw (err?.takeRetainedValue() as Error?) ?? EmbedError.cantWrite }
        let fm = FileManager.default
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }

    /// Read the embedded XMP packet (if any) back into a `SidecarData`. Nil when the
    /// file has no XMP or it carries no human metadata.
    public static func read(from url: URL) -> SidecarData? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let xmp = CGImageMetadataCreateXMPData(meta, nil) as Data? else { return nil }
        guard let parsed = try? XMP.parse(xmp), parsed != .empty else { return nil }
        return parsed
    }

    /// The bare `<x:xmpmeta>…</x:xmpmeta>` element from a full XMP packet, dropping
    /// the BOM and `<?xpacket?>` processing instructions that ImageIO won't parse.
    private static func bareXMP(_ packet: String) -> String {
        guard let start = packet.range(of: "<x:xmpmeta"),
              let end = packet.range(of: "</x:xmpmeta>") else { return packet }
        return String(packet[start.lowerBound..<end.upperBound])
    }
}
