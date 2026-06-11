import Foundation
import GRDB

extension Catalog {
    /// Pack/unpack L2-normalized vectors as little-endian Float16 (half the footprint; cosine==dot).
    private static func packFloat16(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 2)
        for f in v { var h = Float16(f); withUnsafeBytes(of: &h) { data.append(contentsOf: $0) } }
        return data
    }
    private static func unpackFloat16(_ data: Data, dim: Int) -> [Float] {
        var out = [Float](); out.reserveCapacity(dim)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let halves = raw.bindMemory(to: Float16.self)
            for i in 0..<min(dim, halves.count) { out.append(Float(halves[i])) }
        }
        return out
    }

    /// Replace the embedding for an asset (idempotent upsert).
    public func upsertEmbedding(hash: String, model: String, dim: Int, vector: [Float]) throws {
        let blob = Self.packFloat16(vector)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO embeddings (hash, model, dim, vector) VALUES (?, ?, ?, ?)
                ON CONFLICT(hash) DO UPDATE SET model=excluded.model, dim=excluded.dim,
                    vector=excluded.vector
                """, arguments: [hash, model, dim, blob])
        }
    }

    public func embedding(forHash hash: String) -> (model: String, dim: Int, vector: [Float])? {
        try? dbQueue.read { db -> (String, Int, [Float])? in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT model, dim, vector FROM embeddings WHERE hash = ?", arguments: [hash])
            else { return nil }
            let dim: Int = row["dim"]
            return (row["model"], dim, Self.unpackFloat16(row["vector"], dim: dim))
        }.flatMap { $0 }
    }

    public func embeddingCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0 }
    }

    /// All (hash, vector) pairs for the in-memory index, for the current model only.
    public func allEmbeddings(model: String) throws -> [(hash: String, dim: Int, vector: [Float])] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT hash, dim, vector FROM embeddings WHERE model = ?",
                             arguments: [model]).map { row in
                let dim: Int = row["dim"]
                return (row["hash"], dim, Self.unpackFloat16(row["vector"], dim: dim))
            }
        }
    }

    /// (hash, takenAtMs, vector) for `model` — embeddings joined to assets. Feeds BurstGrouper.
    public func embeddingsWithTakenAt(model: String) throws -> [(hash: String, takenAtMs: Int64, vector: [Float])] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.hash AS hash, a.takenAtMs AS takenAtMs, e.dim AS dim, e.vector AS vector
                FROM embeddings e JOIN assets a ON a.hash = e.hash
                WHERE e.model = ?
                """, arguments: [model]).map { row in
                let dim: Int = row["dim"]
                return (row["hash"], row["takenAtMs"], Self.unpackFloat16(row["vector"], dim: dim))
            }
        }
    }

    /// On a model swap, drop stale-model embeddings + their `embed` jobs so the pipeline re-derives.
    /// No-op in v1's single-model world, but the mechanism must exist.
    public func reconcileEmbeddingModel(current: String) throws {
        try dbQueue.write { db in
            let stale = try String.fetchAll(db,
                sql: "SELECT hash FROM embeddings WHERE model <> ?", arguments: [current])
            guard !stale.isEmpty else { return }
            try db.execute(sql: "DELETE FROM embeddings WHERE model <> ?", arguments: [current])
            for h in stale {
                try db.execute(sql: "DELETE FROM derivation_jobs WHERE hash = ? AND stage = 'embed'",
                               arguments: [h])
            }
        }
    }
}
