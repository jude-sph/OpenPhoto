import Foundation

public struct SidecarData: Equatable, Sendable {
    public var rating: Int          // 0–5; 0 = unrated
    public var favorite: Bool
    public var caption: String?
    public var tags: [String]

    public static let empty = SidecarData(rating: 0, favorite: false, caption: nil, tags: [])

    public init(rating: Int, favorite: Bool, caption: String?, tags: [String]) {
        self.rating = rating; self.favorite = favorite
        self.caption = (caption?.isEmpty == true) ? nil : caption
        self.tags = tags
    }
}
