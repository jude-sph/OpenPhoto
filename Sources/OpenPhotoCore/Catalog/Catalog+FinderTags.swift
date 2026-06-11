import Foundation
import GRDB

extension Catalog {
    /// Store (replace) the last-synced Finder/OpenPhoto tag set for an asset (the merge baseline).
    public func setFinderTagBaseline(hash: String, tags: [String]) throws {
        let json = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO finder_tag_sync (hash, baseline) VALUES (?, ?)",
                           arguments: [hash, json])
        }
    }
    /// The stored baseline tag set for an asset (`[]` if never synced).
    public func finderTagBaseline(forHash hash: String) throws -> [String] {
        try dbQueue.read { db in
            guard let json = try String.fetchOne(db,
                sql: "SELECT baseline FROM finder_tag_sync WHERE hash = ?", arguments: [hash]) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
    }
}
