import Foundation
import GRDB

extension Catalog {
    /// All current-model faces (assigned + unassigned) that have a real embedding — the projection input.
    public func facesForLayout() throws -> [(id: Int64, personID: Int64?, vector: [Float])] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, personID, dim, embedding FROM faces
                WHERE dim = \(FaceEmbedder.dimension)
                """).map { row in
                    let blob: Data = row["embedding"]
                    return (id: row["id"], personID: row["personID"],
                            vector: Float16Codec.unpack(blob, dim: row["dim"]))
                }
        }
    }

    /// Replace the entire layout table with these coordinates and stamp the fingerprint.
    public func writeFaceLayout(_ points: [(faceID: Int64, x: Double, y: Double)], version: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM face_layout")
            for p in points {
                try db.execute(sql: "INSERT INTO face_layout (faceID, x, y, layoutVersion) VALUES (?,?,?,?)",
                               arguments: [p.faceID, p.x, p.y, version])
            }
        }
        try setMeta("faceLayoutFingerprint", try faceSetFingerprint())
    }

    public func readFaceLayout() throws -> [(faceID: Int64, x: Double, y: Double)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT faceID, x, y FROM face_layout").map {
                (faceID: $0["faceID"], x: $0["x"], y: $0["y"])
            }
        }
    }

    /// Cheap signature of the contributing face set: count + max id + sum of ids.
    /// Changes on any insert/delete/reassign that adds or removes an embedded face.
    public func faceSetFingerprint() throws -> String {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(id),0) AS m, COALESCE(SUM(id),0) AS s
                FROM faces WHERE dim = \(FaceEmbedder.dimension)
                """)!
            return "\(row["c"] as Int64)-\(row["m"] as Int64)-\(row["s"] as Int64)"
        }
    }

    /// Stored fingerprint of the layout currently in `face_layout` (nil if never computed).
    public func faceLayoutFingerprint() throws -> String? { try meta("faceLayoutFingerprint") }
}
