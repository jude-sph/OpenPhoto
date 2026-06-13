import Foundation
import CoreGraphics
import GRDB

public struct FaceRow: Sendable, Equatable {
    public var id: Int64?
    public var hash: String
    public var rect: CGRect            // Vision normalized boundingBox (bottom-left origin)
    public var embedding: [Float]
    public var confidence: Float
    public var source: String          // "auto" | "confirmed"
    public var personID: Int64?
    public var quality: Float          // clusterability: capture quality if gated-in, else 0
    public init(id: Int64?, hash: String, rect: CGRect, embedding: [Float],
                confidence: Float, source: String, personID: Int64?, quality: Float = 1) {
        self.id = id; self.hash = hash; self.rect = rect; self.embedding = embedding
        self.confidence = confidence; self.source = source; self.personID = personID
        self.quality = quality
    }
}

public struct PersonRow: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let faceCount: Int
    public let representativeFaceID: Int64?   // highest-confidence confirmed face
}

extension Catalog {
    // MARK: Float16 pack/unpack for face embeddings
    // (mirrors Catalog+Embeddings.swift's private helpers — kept private here to avoid collision)
    private static func packF16(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 2)
        for f in v { var h = Float16(f); withUnsafeBytes(of: &h) { data.append(contentsOf: $0) } }
        return data
    }
    private static func unpackF16(_ data: Data, dim: Int) -> [Float] {
        var out = [Float](); out.reserveCapacity(dim)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let halves = raw.bindMemory(to: Float16.self)
            for i in 0..<min(dim, halves.count) { out.append(Float(halves[i])) }
        }
        return out
    }

    // MARK: CRUD

    /// Low-level insert; returns the new ids in order.
    public func insertFaces(_ rows: [FaceRow]) throws -> [Int64] {
        try dbQueue.write { db in
            var ids: [Int64] = []
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO faces (hash, rectX, rectY, rectW, rectH, embedding, dim,
                                       personID, confidence, source, quality)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [r.hash, r.rect.minX, r.rect.minY, r.rect.width, r.rect.height,
                                     Self.packF16(r.embedding), r.embedding.count,
                                     r.personID, r.confidence, r.source, r.quality])
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    /// Idempotent re-detection: replace the asset's AUTO faces, KEEP confirmed (and their regions).
    /// A new auto face that overlaps an existing confirmed face (IoU > 0.4) is skipped, so a full
    /// re-derivation never inserts a duplicate auto face on top of one the user already named.
    public func replaceFaces(forHash hash: String, with rows: [FaceRow]) throws {
        try dbQueue.write { db in
            let confirmedRects: [CGRect] = try Row.fetchAll(db, sql:
                "SELECT rectX, rectY, rectW, rectH FROM faces WHERE hash = ? AND source = 'confirmed'",
                arguments: [hash]).map {
                    CGRect(x: $0["rectX"] as Double, y: $0["rectY"] as Double,
                           width: $0["rectW"] as Double, height: $0["rectH"] as Double)
                }
            try db.execute(sql: "DELETE FROM faces WHERE hash = ? AND source = 'auto'",
                           arguments: [hash])
            for r in rows where !confirmedRects.contains(where: { Self.iou($0, r.rect) > 0.4 }) {
                try db.execute(sql: """
                    INSERT INTO faces (hash, rectX, rectY, rectW, rectH, embedding, dim,
                                       personID, confidence, source, quality)
                    VALUES (?,?,?,?,?,?,?,NULL,?,?,?)
                    """, arguments: [hash, r.rect.minX, r.rect.minY, r.rect.width, r.rect.height,
                                     Self.packF16(r.embedding), r.embedding.count,
                                     r.confidence, r.source, r.quality])
            }
        }
    }

    /// Intersection-over-union of two boxes (0 = disjoint, 1 = identical).
    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    /// Fetch a single face row by its primary-key id.  Returns nil when the id is not found.
    public func face(forID id: Int64) throws -> FaceRow? {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT id, hash, rectX, rectY, rectW, rectH, embedding, dim,
                           personID, confidence, source, quality
                    FROM faces WHERE id = ?
                    """,
                arguments: [id])
            return rows.first.map { Self.faceRow(from: $0) }
        }
    }

    public func faces(forHash hash: String) throws -> [FaceRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db,
                sql: "SELECT id, hash, rectX, rectY, rectW, rectH, embedding, dim, personID, confidence, source, quality FROM faces WHERE hash = ?",
                arguments: [hash]).map { Self.faceRow(from: $0) }
        }
    }

    public func faces(forPerson personID: Int64) throws -> [FaceRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db,
                sql: "SELECT id, hash, rectX, rectY, rectW, rectH, embedding, dim, personID, confidence, source, quality FROM faces WHERE personID = ?",
                arguments: [personID]).map { Self.faceRow(from: $0) }
        }
    }

    /// (id, vector) for every detected-but-unassigned auto face that is CLUSTERABLE — current-model
    /// dimension and quality-gated in. Stale v1 vectors (dim ≠ 512) and gated-out faces are excluded.
    public func unassignedFacesWithEmbeddings() throws -> [(id: Int64, vector: [Float])] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, dim, embedding FROM faces
                WHERE personID IS NULL AND source = 'auto' AND dim = \(FaceEmbedder.dimension) AND quality > 0
                """).map { row -> (id: Int64, vector: [Float]) in
                    let id: Int64 = row["id"]
                    let dim: Int = row["dim"]
                    let blob: Data = row["embedding"]
                    return (id, Self.unpackF16(blob, dim: dim))
                }
        }
    }

    public func createPerson(name: String) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO people (name, createdAtMs) VALUES (?, ?)",
                           arguments: [name, Int64(Date().timeIntervalSince1970 * 1000)])
            return db.lastInsertedRowID
        }
    }

    /// Rename a person. Human metadata — the App pairs this with a sidecar rewrite of the person's
    /// confirmed regions (writeSidecarRegions) so the on-disk MWG region name stays in sync.
    public func renamePerson(_ id: Int64, to name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE people SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func people() throws -> [PersonRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, COUNT(f.id) AS cnt,
                       COALESCE(
                         (SELECT f3.id FROM faces f3
                          WHERE f3.id = p.coverFaceID AND f3.personID = p.id),
                         (SELECT f2.id FROM faces f2 WHERE f2.personID = p.id
                          ORDER BY f2.confidence DESC LIMIT 1)
                       ) AS rep
                FROM people p LEFT JOIN faces f ON f.personID = p.id
                GROUP BY p.id ORDER BY cnt DESC, p.name
                """).map { row -> PersonRow in
                    let rep: Int64? = row["rep"]
                    return PersonRow(id: row["id"], name: row["name"],
                                     faceCount: row["cnt"],
                                     representativeFaceID: rep)
                }
        }
    }

    /// Set (or clear with nil) a person's chosen cover face for the People screen.
    /// The cover is a Mac-local display preference — it persists until cleared or the face is
    /// reassigned to another person, at which point `people()` falls back automatically via COALESCE.
    public func setPersonCover(personID: Int64, faceID: Int64?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE people SET coverFaceID = ? WHERE id = ?",
                           arguments: [faceID, personID])
        }
    }

    /// Assign faces to a person + flip them to "confirmed" (the App pairs this with a sidecar write).
    public func assignFaces(_ ids: [Int64], to personID: Int64) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: ids.count)
            try db.execute(sql: """
                UPDATE faces SET personID = ?, source = 'confirmed' WHERE id IN (\(marks))
                """, arguments: StatementArguments([personID] + ids))
        }
    }

    /// Reassign one face. nil → unassign (personID NULL, source back to 'auto').
    public func reassignFace(_ id: Int64, to personID: Int64?) throws {
        try dbQueue.write { db in
            if let personID {
                try db.execute(
                    sql: "UPDATE faces SET personID = ?, source = 'confirmed' WHERE id = ?",
                    arguments: [personID, id])
            } else {
                try db.execute(
                    sql: "UPDATE faces SET personID = NULL, source = 'auto' WHERE id = ?",
                    arguments: [id])
            }
        }
    }

    /// Move src's faces to dst, delete src person.
    public func mergePerson(_ src: Int64, into dst: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE faces SET personID = ? WHERE personID = ?",
                           arguments: [dst, src])
            try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [src])
        }
    }

    /// Delete a person; its faces revert to unassigned/auto (re-enter the clusterable pool).
    public func deletePerson(_ id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE faces SET personID = NULL, source = 'auto' WHERE personID = ?",
                arguments: [id])
            try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Private helpers

    private static func faceRow(from row: Row) -> FaceRow {
        let dim: Int = row["dim"]
        let blob: Data = row["embedding"]
        let id: Int64 = row["id"]
        let personID: Int64? = row["personID"]
        return FaceRow(
            id: id,
            hash: row["hash"],
            rect: CGRect(x: row["rectX"] as Double, y: row["rectY"] as Double,
                         width: row["rectW"] as Double, height: row["rectH"] as Double),
            embedding: unpackF16(blob, dim: dim),
            confidence: Float(row["confidence"] as Double),
            source: row["source"],
            personID: personID,
            quality: Float((row["quality"] as Double?) ?? 1))
    }

    // MARK: Model versioning + rescan support

    /// Read a `catalog_meta` value (nil if absent).
    public func meta(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM catalog_meta WHERE key = ?", arguments: [key])
        }
    }

    /// Upsert a `catalog_meta` value.
    public func setMeta(_ key: String, _ value: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO catalog_meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }

    /// Drop every AUTO face (confirmed/named faces are kept). Used by the face rescan to clear the
    /// stale-model clusterable pool before re-derivation repopulates it.
    public func resetAutoFaces() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM faces WHERE source = 'auto'")
        }
    }
}
