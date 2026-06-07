import Foundation

public enum MediaKind: String, Codable, Sendable {
    case photo, video

    private static let photoExts: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "tif",
        "webp", "bmp", "dng", "raw", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
    private static let videoExts: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "3gp", "webm",
    ]

    public static func of(filename: String) -> MediaKind? {
        guard !filename.hasPrefix(".") else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        if photoExts.contains(ext) { return .photo }
        if videoExts.contains(ext) { return .video }
        return nil
    }
}
