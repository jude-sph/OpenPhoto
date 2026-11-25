import Foundation

/// The set-union plan for merging one folder into another: which local instances move (and to which
/// sub-dir under the destination), and which are exact duplicates to bin. Nothing in `dest` is touched.
public struct MergeFolderPlan: Sendable, Equatable {
    public struct Move: Sendable, Equatable {
        public let instanceID: String
        public let intoDir: String
        public init(instanceID: String, intoDir: String) { self.instanceID = instanceID; self.intoDir = intoDir }
    }
    public var moves: [Move]
    public var binInstanceIDs: [String]
    public init(moves: [Move] = [], binInstanceIDs: [String] = []) {
        self.moves = moves; self.binInstanceIDs = binInstanceIDs
    }
}

extension LibraryService {
    /// Plan a set-union merge of `src` folder into `dest`: every distinct photo (by content hash) ends
    /// up once in `dest`. A `src` photo whose content isn't already in `dest` (nor an earlier src item)
    /// MOVES in, preserving its sub-path under `src`; a `src` photo whose content is already present is
    /// an exact duplicate → binned. Only local instances are considered (drive-only assets can't move).
    public func mergeFolderPlan(src: String, into dest: String) throws -> MergeFolderPlan {
        func norm(_ s: String) -> String {
            s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let s = norm(src), d = norm(dest)
        // Content already in dest — EXCLUDING the source's own subtree. When `dest` is an ancestor of
        // `src`, the recursive listing of dest contains every source photo; counting those made each
        // one an "exact duplicate" of itself and binned the whole folder.
        func underSource(_ dir: String) -> Bool { s.isEmpty || dir == s || dir.hasPrefix(s + "/") }
        var seen = Set((try items(inDir: d, recursive: true))
            .filter { !underSource($0.dirPath) }.map(\.hash))
        var plan = MergeFolderPlan()
        for item in try items(inDir: s, recursive: true) {
            guard item.driveRelPath == nil else { continue }        // only local instances can move
            if seen.contains(item.hash) {
                plan.binInstanceIDs.append(item.instanceID)          // exact duplicate → bin
            } else {
                seen.insert(item.hash)
                // Preserve the item's sub-path relative to `src` under `dest`.
                let sub: String
                if item.dirPath == s { sub = "" }
                else if !s.isEmpty && item.dirPath.hasPrefix(s + "/") { sub = String(item.dirPath.dropFirst(s.count + 1)) }
                else if s.isEmpty { sub = item.dirPath }
                else { sub = "" }
                plan.moves.append(.init(instanceID: item.instanceID,
                                        intoDir: sub.isEmpty ? d : d + "/" + sub))
            }
        }
        return plan
    }
}
