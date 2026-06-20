import Foundation
import CoreGraphics
import GRDB

extension Catalog {
    /// Bump when the projection algorithm OR the visible-face rules change, so cached coordinates from
    /// an older build are recomputed (it's woven into the fingerprint below, not just a display column).
    /// v3 added the locked-folder visibility filter.
    public static let faceLayoutAlgoVersion = 3

    /// All current-model faces (assigned + unassigned) that have a real embedding — the projection input.
    /// Excludes faces in locked/hidden folders (unless the session is Touch-ID-revealed), exactly like
    /// every other browse query, so locked-folder people never appear on the map.
    public func facesForLayout() throws -> [(id: Int64, personID: Int64?, hash: String, rect: CGRect, vector: [Float])] {
        let lvc = lockedVisibilityClause(hashColumn: "faces.hash")
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, personID, hash, rectX, rectY, rectW, rectH, dim, embedding FROM faces
                WHERE dim = \(FaceEmbedder.dimension) \(lvc)
                """).map { row in
                    let blob: Data = row["embedding"]
                    let rx: Double = row["rectX"], ry: Double = row["rectY"]
                    let rw: Double = row["rectW"], rh: Double = row["rectH"]
                    let rect = CGRect(x: rx, y: ry, width: rw, height: rh)
                    return (id: row["id"], personID: row["personID"], hash: row["hash"], rect: rect,
                            vector: Float16Codec.unpack(blob, dim: row["dim"]))
                }
        }
    }

    /// Replace the entire layout table with these coordinates and stamp the fingerprint — atomically.
    public func writeFaceLayout(_ points: [(faceID: Int64, x: Double, y: Double)], version: Int) throws {
        let lvc = lockedVisibilityClause(hashColumn: "faces.hash")
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM face_layout")
            for p in points {
                try db.execute(sql: "INSERT INTO face_layout (faceID, x, y, layoutVersion) VALUES (?,?,?,?)",
                               arguments: [p.faceID, p.x, p.y, version])
            }
            // Stamp the fingerprint of the SAME transactional snapshot (and same visible-face rules as
            // the projection input). Computing it in a separate read afterwards would let a concurrent
            // face derivation insert/delete a face between the two transactions, certifying these
            // coordinates as current for a face set they don't cover.
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(id),0) AS m, COALESCE(SUM(id),0) AS s
                FROM faces WHERE dim = \(FaceEmbedder.dimension) \(lvc)
                """)!
            let fp = "a\(Self.faceLayoutAlgoVersion)-\(row["c"] as Int64)-\(row["m"] as Int64)-\(row["s"] as Int64)"
            try db.execute(sql: """
                INSERT INTO catalog_meta (key, value) VALUES ('faceLayoutFingerprint', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [fp])
        }
    }

    public func readFaceLayout() throws -> [(faceID: Int64, x: Double, y: Double)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT faceID, x, y FROM face_layout").map {
                (faceID: $0["faceID"], x: $0["x"], y: $0["y"])
            }
        }
    }

    /// Cheap signature of the embedded-face *id set*: count + max id + sum of ids. Changes when an
    /// embedded face is added or removed. NOT sensitive to personID reassignment — dot colors are read
    /// fresh on every load, while coordinates intentionally persist across reassigns (no reflow).
    public func faceSetFingerprint() throws -> String {
        let lvc = lockedVisibilityClause(hashColumn: "faces.hash")
        return try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(id),0) AS m, COALESCE(SUM(id),0) AS s
                FROM faces WHERE dim = \(FaceEmbedder.dimension) \(lvc)
                """)!
            return "a\(Self.faceLayoutAlgoVersion)-\(row["c"] as Int64)-\(row["m"] as Int64)-\(row["s"] as Int64)"
        }
    }

    /// Stored fingerprint of the layout currently in `face_layout` (nil if never computed).
    public func faceLayoutFingerprint() throws -> String? { try meta("faceLayoutFingerprint") }
}
