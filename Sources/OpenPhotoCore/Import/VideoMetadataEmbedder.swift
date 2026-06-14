import Foundation
import AVFoundation

/// Embeds location (+ creation date) into a QuickTime/MP4-family video by **passthrough** export —
/// streams are copied unchanged (no re-encode), only a `location` + `creationDate` metadata atom is
/// added. Used on import to make a geotagged video self-describing, mirroring how we fold EXIF GPS
/// into imported photos. Containers AVFoundation can't write (e.g. .mpg/.avi) return false so the
/// caller falls back to a plain copy.
public enum VideoMetadataEmbedder {

    /// Export `src` → `dst` (which must not yet exist) adding the location/date metadata. Returns
    /// true only on a completed export; false on any unsupported-format or failure.
    public static func embed(from src: URL, to dst: URL,
                             latitude: Double, longitude: Double, date: Date?) async -> Bool {
        let fileType: AVFileType
        switch dst.pathExtension.lowercased() {
        case "mov":          fileType = .mov
        case "mp4":          fileType = .mp4
        case "m4v":          fileType = .m4v
        default:             return false
        }
        let asset = AVURLAsset(url: src)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else { return false }

        var items: [AVMetadataItem] = []
        let iso6709 = String(format: "%+.6f%+.6f/", latitude, longitude)
        let loc = AVMutableMetadataItem()
        loc.identifier = .quickTimeMetadataLocationISO6709
        loc.value = iso6709 as NSString
        items.append(loc)
        if let date {
            let d = AVMutableMetadataItem()
            d.identifier = .quickTimeMetadataCreationDate
            d.value = ISO8601DateFormatter().string(from: date) as NSString
            items.append(d)
        }

        session.metadata = items
        try? FileManager.default.removeItem(at: dst)   // export fails if the output already exists
        do {
            try await session.export(to: dst, as: fileType)
            return true
        } catch {
            try? FileManager.default.removeItem(at: dst)   // clean a partial output
            return false
        }
    }
}
