import Foundation

/// A record of a single file's relPath before and after a user-initiated move.
public struct MovedFileRecord: Sendable, Equatable {
    public let vaultID: String
    public let from: String   // relPath before the user's action
    public let to: String     // relPath after it

    public init(vaultID: String, from: String, to: String) {
        self.vaultID = vaultID
        self.from = from
        self.to = to
    }
}

/// A data-only descriptor recording what the user did, used to drive undo replay.
/// Undo introduces zero new file operations: it replays existing public operations
/// with inverse arguments. Session-scoped, in-memory, nothing persisted.
public enum UndoAction: Sendable, Equatable {
    /// Asset hashes (including Live partners); count = user-facing photo count.
    case deletePhotos(hashes: [String], count: Int)
    /// The full set of file-level moves performed by the action.
    case movePhotos(moves: [MovedFileRecord])
    /// A folder rename/move: from and to are absolute or relative folder paths.
    case moveFolder(from: String, to: String)
    /// relPath = the CURRENT (post-rename) path of the file.
    case rename(vaultID: String, relPath: String, oldName: String)

    /// A short, human-readable description shown in the Edit menu (e.g. "Undo Move 3 Photos").
    public var label: String {
        switch self {
        case .deletePhotos(_, let count):
            return count == 1 ? "Delete 1 Photo" : "Delete \(count) Photos"
        case .movePhotos(let moves):
            return moves.count == 1 ? "Move 1 Photo" : "Move \(moves.count) Photos"
        case .moveFolder:
            return "Move Folder"
        case .rename:
            return "Rename"
        }
    }
}

/// Pure planning helpers for constructing undo arguments from recorded descriptors.
public enum UndoPlan {
    /// Inverse plan for a photo move.
    ///
    /// Groups each `MovedFileRecord` by its *origin directory* (`from` minus the
    /// last path component). The returned `destDir` is that origin directory so
    /// that the undo replay can call `movePhotos(ids:into:destDir)` once per group.
    /// The `ids` are the grid instance-IDs at the *current* (post-move) location:
    /// `vaultID + "|" + to`.
    ///
    /// Output is deterministic: groups sorted ascending by `destDir`, ids sorted
    /// ascending within each group.
    public static func inverseMoveGroups(
        _ moves: [MovedFileRecord]
    ) -> [(destDir: String, ids: [String])] {
        // Group by origin directory (the directory the file came FROM).
        var groups: [String: [String]] = [:]
        for move in moves {
            let originDir = (move.from as NSString).deletingLastPathComponent
            let instanceID = move.vaultID + "|" + move.to
            groups[originDir, default: []].append(instanceID)
        }
        // Produce a stable, sorted result.
        return groups
            .sorted { $0.key < $1.key }
            .map { (destDir: $0.key, ids: $0.value.sorted()) }
    }
}
