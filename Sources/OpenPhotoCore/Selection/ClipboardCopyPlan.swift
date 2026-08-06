import Foundation

/// Bounds on how much gets decoded for a single "Copy". Full-res decodes are large (a 50MP photo is
/// ~200MB in memory), so a big selection must never be turned into pixels — this app has already
/// OOM'd once on unbounded decoding.
public enum ClipboardCopyBudget {
    /// Most photos copied as pixels in one go.
    public static let maxImages = 12
    /// Ceiling on the ESTIMATED decoded bytes of a copy (w × h × 4 per photo).
    public static let maxDecodedBytes = 750 * 1024 * 1024
    /// Assumed decoded size of a photo whose dimensions the catalog doesn't know (~12MP).
    public static let assumedDecodedBytes = 50 * 1024 * 1024
}

/// What a "Copy" puts on the clipboard for a set of items — decided up front from catalog metadata,
/// before anything is decoded, so the menu title can state exactly what you'll get.
///
/// Photos copy as full-resolution pixels; videos copy as file references (pixels are meaningless for
/// them). A selection too large to decode safely copies entirely as files instead — deliberately all
/// of it, so the result is one predictable thing rather than a partial mix.
public struct ClipboardCopyPlan: Equatable, Sendable {
    /// Copied as full-resolution pixels.
    public let images: [TimelineItem]
    /// Copied as file references (pastes into Finder/Mail/Messages as the file itself).
    public let files: [TimelineItem]
    /// Menu title — names the exact outcome ("Copy 30 Files", never a vague "Copy").
    public let title: String

    public var isEmpty: Bool { images.isEmpty && files.isEmpty }

    public static func make(for items: [TimelineItem]) -> ClipboardCopyPlan {
        let photos = items.filter { $0.kind != MediaKind.video.rawValue }
        let videos = items.filter { $0.kind == MediaKind.video.rawValue }
        let estimate = photos.reduce(0) { total, p in
            guard let w = p.pixelWidth, let h = p.pixelHeight, w > 0, h > 0 else {
                return total + ClipboardCopyBudget.assumedDecodedBytes
            }
            return total + w * h * 4
        }
        let overBudget = photos.count > ClipboardCopyBudget.maxImages
            || estimate > ClipboardCopyBudget.maxDecodedBytes
        let images = overBudget ? [] : photos
        let files = overBudget ? items : videos
        return ClipboardCopyPlan(images: images, files: files,
                                 title: title(images: images.count, files: files.count))
    }

    private static func title(images: Int, files: Int) -> String {
        let total = images + files
        switch (images, files) {
        case (0, 0):  return "Copy"
        case (_, 0):  return total == 1 ? "Copy Image" : "Copy \(total) Images"
        case (0, _):  return total == 1 ? "Copy File" : "Copy \(total) Files"
        default:      return "Copy \(total) Items"
        }
    }
}
