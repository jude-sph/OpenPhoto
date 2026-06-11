import Foundation

public struct SidecarData: Equatable, Sendable {
    public var rating: Int          // 0–5; 0 = unrated
    public var favorite: Bool
    public var caption: String?
    public var tags: [String]
    /// Named/confirmed face regions (human-authored). Written to XMP as mwg-rs:Regions.
    /// Unnamed clusters are never written here — only confirmed person assignments.
    public var faces: [FaceRegion]

    public static let empty = SidecarData(rating: 0, favorite: false, caption: nil, tags: [], faces: [])

    public init(rating: Int, favorite: Bool, caption: String?, tags: [String],
                faces: [FaceRegion] = []) {
        self.rating = min(max(rating, 0), 5) // 0–5; 0 = unrated
        self.favorite = favorite
        self.caption = (caption?.isEmpty == true) ? nil : caption
        self.tags = tags
        self.faces = faces
    }
}
