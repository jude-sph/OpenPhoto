import Foundation
import GRDB

public struct VaultRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "vaults"
    public var id: String          // vault_id from vault.json
    public var role: String
    public var rootPath: String
    public var lastSeenMs: Int64

    public init(id: String, role: String, rootPath: String, lastSeenMs: Int64) {
        self.id = id
        self.role = role
        self.rootPath = rootPath
        self.lastSeenMs = lastSeenMs
    }
}

public struct AssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "assets"
    public var hash: String        // primary key, "sha256:…"
    public var kind: String        // MediaKind.rawValue
    public var takenAtMs: Int64    // epoch ms — sort key
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var cameraModel: String?
    public var lensModel: String?
    public var durationSeconds: Double?
    public var livePairHash: String?      // set on the photo half of a Live Photo
    public var isLivePairedVideo: Bool    // true on the video half → hidden in browse
    // Mirrors of sidecar data (sidecars are authoritative — spec §3):
    public var favorite: Bool
    public var rating: Int
    public var caption: String?
    public var tagsJSON: String           // JSON array of strings

    public init(hash: String, kind: String, takenAtMs: Int64,
                pixelWidth: Int?, pixelHeight: Int?,
                latitude: Double?, longitude: Double?,
                cameraModel: String?, lensModel: String?,
                durationSeconds: Double?,
                livePairHash: String?, isLivePairedVideo: Bool,
                favorite: Bool, rating: Int, caption: String?, tagsJSON: String) {
        self.hash = hash
        self.kind = kind
        self.takenAtMs = takenAtMs
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.latitude = latitude
        self.longitude = longitude
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.durationSeconds = durationSeconds
        self.livePairHash = livePairHash
        self.isLivePairedVideo = isLivePairedVideo
        self.favorite = favorite
        self.rating = rating
        self.caption = caption
        self.tagsJSON = tagsJSON
    }
}

public struct InstanceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "instances"
    public var hash: String
    public var vaultID: String
    public var relPath: String
    public var dirPath: String     // dirname(relPath), "" for vault root
    public var size: Int64
    public var mtimeMs: Int64

    public init(hash: String, vaultID: String, relPath: String,
                dirPath: String, size: Int64, mtimeMs: Int64) {
        self.hash = hash
        self.vaultID = vaultID
        self.relPath = relPath
        self.dirPath = dirPath
        self.size = size
        self.mtimeMs = mtimeMs
    }
}

/// One browseable row: asset + its (first) local instance.
public struct TimelineItem: Codable, FetchableRecord, Sendable, Equatable {
    public var hash: String
    public var kind: String
    public var takenAtMs: Int64
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var cameraModel: String?
    public var lensModel: String?
    public var durationSeconds: Double?
    public var livePairHash: String?
    public var favorite: Bool
    public var rating: Int
    public var caption: String?
    public var tagsJSON: String
    public var vaultID: String
    public var relPath: String
    public var dirPath: String
    public var size: Int64
}
