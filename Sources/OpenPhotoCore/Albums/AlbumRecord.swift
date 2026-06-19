import Foundation

/// One manually-curated album — a sovereign, human-authored collection persisted as
/// `<libraryRoot>/.openphoto/albums/<id>.json` (vault-format-v1). Members are content hashes (a
/// photo *is* its content), so an album survives renames/moves and is portable to a drive holding
/// the same content with no path remapping. The catalog mirror (`albums`/`album_members`) is
/// rebuildable from these files, keeping with "human metadata is durable, the catalog is rebuildable".
public struct AlbumRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String            // UUID string, == filename stem; immutable identity
    public var name: String
    public var description: String?
    public var coverHash: String?    // nil → cover derives from the first member
    public var createdAtMs: Int64
    public var modifiedAtMs: Int64
    public var members: [String]     // ordered content hashes; each appears at most once

    public init(id: String, name: String, description: String? = nil, coverHash: String? = nil,
                createdAtMs: Int64, modifiedAtMs: Int64, members: [String]) {
        self.id = id; self.name = name; self.description = description; self.coverHash = coverHash
        self.createdAtMs = createdAtMs; self.modifiedAtMs = modifiedAtMs; self.members = members
    }
}
