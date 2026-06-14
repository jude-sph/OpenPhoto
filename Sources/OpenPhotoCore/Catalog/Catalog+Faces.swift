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
                                     Float16Codec.pack(r.embedding), r.embedding.count,
                                     r.personID, r.confidence, r.source, r.quality])
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    /// Idempotent re-detection: replace the asset's AUTO faces, KEEP confirmed (and their regions).
    /// A new detection that overlaps an existing confirmed face (IoU > 0.4) does NOT become a duplicate
    /// auto face — instead it REFRESHES that named face's embedding/quality (keeping its person, source,
    /// and rect) when the new detection is clusterable. This lets a rescan re-embed named people with the
    /// current model, not just the unassigned pool.
    public func replaceFaces(forHash hash: String, with rows: [FaceRow]) throws {
        try dbQueue.write { db in
            let confirmed: [(id: Int64, rect: CGRect)] = try Row.fetchAll(db, sql:
                "SELECT id, rectX, rectY, rectW, rectH FROM faces WHERE hash = ? AND source = 'confirmed'",
                arguments: [hash]).map {
                    (id: $0["id"],
                     rect: CGRect(x: $0["rectX"] as Double, y: $0["rectY"] as Double,
                                  width: $0["rectW"] as Double, height: $0["rectH"] as Double))
                }
            try db.execute(sql: "DELETE FROM faces WHERE hash = ? AND source = 'auto'",
                           arguments: [hash])
            var refreshed = Set<Int64>()
            for r in rows {
                if let match = confirmed.first(where: {
                    !refreshed.contains($0.id) && Self.iou($0.rect, r.rect) > 0.4
                }) {
                    refreshed.insert(match.id)
                    if !r.embedding.isEmpty {   // only refresh from a clusterable (embedded) detection
                        try db.execute(sql: """
                            UPDATE faces SET embedding = ?, dim = ?, quality = ?, confidence = ?
                            WHERE id = ?
                            """, arguments: [Float16Codec.pack(r.embedding), r.embedding.count,
                                             r.quality, r.confidence, match.id])
                    }
                    continue   // never insert an auto duplicate over a named face
                }
                try db.execute(sql: """
                    INSERT INTO faces (hash, rectX, rectY, rectW, rectH, embedding, dim,
                                       personID, confidence, source, quality)
                    VALUES (?,?,?,?,?,?,?,NULL,?,?,?)
                    """, arguments: [hash, r.rect.minX, r.rect.minY, r.rect.width, r.rect.height,
                                     Float16Codec.pack(r.embedding), r.embedding.count,
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
        let lvc = lockedVisibilityClause(hashColumn: "faces.hash")
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, hash, rectX, rectY, rectW, rectH, embedding, dim, personID, confidence, source, quality
                FROM faces WHERE personID = ? \(lvc)
                """, arguments: [personID]).map { Self.faceRow(from: $0) }
        }
    }

    /// (id, vector) for every detected-but-unassigned auto face that is CLUSTERABLE — current-model
    /// dimension and quality-gated in. Stale v1 vectors (dim ≠ 512) and gated-out faces are excluded.
    /// Hidden faces are also excluded (they've been ignored by the user).
    public func unassignedFacesWithEmbeddings() throws -> [(id: Int64, vector: [Float])] {
        let lvc = lockedVisibilityClause(hashColumn: "faces.hash")
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, dim, embedding FROM faces
                WHERE personID IS NULL AND source = 'auto' AND dim = \(FaceEmbedder.dimension) AND quality > 0 AND hidden = 0
                \(lvc)
                """).map { row -> (id: Int64, vector: [Float]) in
                    let id: Int64 = row["id"]
                    let dim: Int = row["dim"]
                    let blob: Data = row["embedding"]
                    return (id, Float16Codec.unpack(blob, dim: dim))
                }
        }
    }

    /// Every unassigned AUTO face id (ANY quality), best-quality first. The Other-faces bucket uses
    /// this so gated faces (small / blurry / profile — stored with an empty embedding and quality 0,
    /// hence excluded from clustering) are still reachable for manual assignment, instead of invisible.
    /// Hidden faces are excluded — use `hiddenAutoFaceIDs()` to surface them in a "Show hidden" view.
    public func unassignedAutoFaceIDs() throws -> [Int64] {
        let lvc = lockedVisibilityClause(hashColumn: "faces.hash")
        return try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM faces WHERE personID IS NULL AND source = 'auto' AND hidden = 0
                \(lvc)
                ORDER BY quality DESC, id
                """)
        }
    }

    /// Auto faces the user has hidden from the Other bucket (reversible). Drives the "Show hidden" view.
    public func hiddenAutoFaceIDs() throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM faces WHERE personID IS NULL AND source = 'auto' AND hidden = 1
                ORDER BY quality DESC, id
                """)
        }
    }

    /// Hide or restore (un-hide) the given faces — a reversible "ignore". No-op for an empty list.
    public func setFacesHidden(_ ids: [Int64], hidden: Bool) throws {
        guard !ids.isEmpty else { return }
        let marks = databaseQuestionMarks(count: ids.count)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE faces SET hidden = ? WHERE id IN (\(marks))",
                           arguments: StatementArguments([hidden ? 1 : 0] + ids))
        }
    }

    /// (personID, vector) for every CONFIRMED face carrying a current-model embedding — the input for
    /// per-person centroids. Faces with stale (dim ≠ 512) vectors are excluded, so a person whose faces
    /// haven't been re-embedded yet simply contributes no centroid until a rescan refreshes them.
    public func assignedFacesWithEmbeddings() throws -> [(personID: Int64, vector: [Float])] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT personID, dim, embedding FROM faces
                WHERE personID IS NOT NULL AND source = 'confirmed' AND dim = \(FaceEmbedder.dimension)
                """).map { row -> (personID: Int64, vector: [Float]) in
                    let pid: Int64 = row["personID"]
                    let dim: Int = row["dim"]
                    let blob: Data = row["embedding"]
                    return (pid, Float16Codec.unpack(blob, dim: dim))
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
        // When locked, count only visible faces and prefer a visible cover. Drive the cover
        // selection through the same "has a non-locked instance" EXISTS check so a locked-photo
        // face is never shown as the person's cover while the folder is hidden.
        // NOTE (v1): if ALL of a person's faces are locked, faceCount will be 0 and rep nil —
        //            the person row still appears (without a cover); hiding them entirely is deferred.
        let lvc = lockedVisibilityClause(hashColumn: "f.hash")
        let lvcCover = lockedVisibilityClause(hashColumn: "f3.hash")
        let lvcRep   = lockedVisibilityClause(hashColumn: "f2.hash")
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, COUNT(f.id) AS cnt,
                       COALESCE(
                         (SELECT f3.id FROM faces f3
                          WHERE f3.id = p.coverFaceID AND f3.personID = p.id \(lvcCover)),
                         (SELECT f2.id FROM faces f2 WHERE f2.personID = p.id \(lvcRep)
                          ORDER BY f2.confidence DESC LIMIT 1)
                       ) AS rep
                FROM people p LEFT JOIN faces f ON f.personID = p.id \(lvc)
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

    /// Reassign one face. nil → unassign (personID NULL, source back to 'auto'). A MANUAL tag (no real
    /// detected face) is deleted on unassign instead of returned to the pool — it has no embedding and
    /// only existed as a hand-added membership.
    public func reassignFace(_ id: Int64, to personID: Int64?) throws {
        try dbQueue.write { db in
            if let personID {
                try db.execute(
                    sql: "UPDATE faces SET personID = ?, source = 'confirmed' WHERE id = ?",
                    arguments: [personID, id])
            } else if try String.fetchOne(db, sql: "SELECT source FROM faces WHERE id = ?",
                                          arguments: [id]) == "manual" {
                try db.execute(sql: "DELETE FROM faces WHERE id = ?", arguments: [id])
            } else {
                try db.execute(
                    sql: "UPDATE faces SET personID = NULL, source = 'auto' WHERE id = ?",
                    arguments: [id])
            }
        }
    }

    /// Manually tag a person as present in a photo WITHOUT a detected face (for obscured faces).
    /// Stored as a `source='manual'` row: full-image rect (so it displays the whole photo and writes a
    /// valid sidecar region), no embedding (dim 0), quality 0, confidence 0 — so it is EXCLUDED from
    /// clustering (personID set) and from centroids (`assignedFacesWithEmbeddings` needs source
    /// 'confirmed' + dim 512), i.e. it never informs the recognition algorithm. Idempotent: a no-op if
    /// the person is already linked to this photo (any source). Returns the new face id, or nil if skipped.
    @discardableResult
    public func addManualPersonTag(hash: String, personID: Int64) throws -> Int64? {
        try dbQueue.write { db in
            let already = try Int.fetchOne(db,
                sql: "SELECT 1 FROM faces WHERE hash = ? AND personID = ? LIMIT 1",
                arguments: [hash, personID]) != nil
            if already { return nil }
            try db.execute(sql: """
                INSERT INTO faces (hash, rectX, rectY, rectW, rectH, embedding, dim,
                                   personID, confidence, source, quality)
                VALUES (?, 0, 0, 1, 1, ?, 0, ?, 0, 'manual', 0)
                """, arguments: [hash, Data(), personID])
            return db.lastInsertedRowID
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
            embedding: Float16Codec.unpack(blob, dim: dim),
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

    /// One-time face re-derivation when the embedding model changes (mirrors `reconcileEmbeddingModel`).
    /// If the stored `faceModelVersion` differs from `current`, atomically drop AUTO faces (named faces
    /// are kept), clear the face derivation jobs so every photo re-embeds with the new model, and record
    /// the new version. Returns true if a reset happened. Called on library open.
    @discardableResult
    public func reconcileFaceModel(current: String) throws -> Bool {
        let stored = try meta("faceModelVersion")
        guard stored != current else { return false }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM faces WHERE source = 'auto'")
            try db.execute(sql: "DELETE FROM derivation_jobs WHERE stage = 'faces'")
            try db.execute(sql: """
                INSERT INTO catalog_meta (key, value) VALUES ('faceModelVersion', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [current])
        }
        return true
    }
}
