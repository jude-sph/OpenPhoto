import Foundation

public struct MediaMetadata: Sendable {
    public var takenAt: Date
    public var pixelWidth: Int? = nil
    public var pixelHeight: Int? = nil
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    public var cameraModel: String? = nil
    public var lensModel: String? = nil
    public var durationSeconds: Double? = nil
    /// Apple Live Photo content identifier, when present (format v1 §6).
    public var contentIdentifier: String? = nil

    public init(takenAt: Date) { self.takenAt = takenAt }
}
