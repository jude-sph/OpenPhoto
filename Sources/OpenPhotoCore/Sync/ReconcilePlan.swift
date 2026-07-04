import Foundation

/// A content placement — a hash that should (DESIRED) or does (ACTUAL) live at one drive-relative path.
/// Reconcile is keyed by content, so identity is (hash, path).
public struct Placement: Hashable, Sendable {
    public let hash: String
    public let path: String
    public init(hash: String, path: String) { self.hash = hash; self.path = path }
}

/// The set-difference between what a drive HAS (ACTUAL) and what the library WANTS (DESIRED), expressed
/// as concrete actions. Pure output of `computeReconcilePlan` — no I/O. Executing it (copy/relocate/
/// remove/delete) is a separate, later step. See docs/superpowers/specs/2026-07-04-drive-reconcile-by-state-design.md.
public struct ReconcilePlan: Equatable, Sendable {
    /// A same-hash move on the drive: the bytes are already present at `from`, the library wants them
    /// at `to`. Content-preserving — always safe to auto-apply.
    public struct Relocation: Hashable, Sendable {
        public let hash: String
        public let from: String
        public let to: String
        public init(hash: String, from: String, to: String) { self.hash = hash; self.from = from; self.to = to }
    }

    /// Desired placements the drive lacks, with no on-drive copy to move → bring the bytes in (from a
    /// local original or another drive; source resolved at execution).
    public var copies: [Placement]
    /// Same-hash moves for content present at the wrong path.
    public var relocations: [Relocation]
    /// Placements the library doesn't want, whose hash survives at a desired path → drop (content safe
    /// elsewhere). This is what cleans up move-orphan phantoms. Auto-applicable.
    public var staleRemovals: [Placement]
    /// Placements whose hash is GONE from the library entirely → a genuine deletion. NEVER auto-removed;
    /// surfaced for review.
    public var reviewDeletions: [Placement]

    public init(copies: [Placement], relocations: [Relocation],
                staleRemovals: [Placement], reviewDeletions: [Placement]) {
        self.copies = copies; self.relocations = relocations
        self.staleRemovals = staleRemovals; self.reviewDeletions = reviewDeletions
    }

    public var isEmpty: Bool {
        copies.isEmpty && relocations.isEmpty && staleRemovals.isEmpty && reviewDeletions.isEmpty
    }

    /// Fraction of the drive's files this plan would REMOVE (stale removals + review deletions). The
    /// blast-radius guard: a catalog accident that made half the library "disappear" would show up as a
    /// high fraction, so a caller can demand confirmation above a threshold before applying.
    public func removalFraction(actualCount: Int) -> Double {
        guard actualCount > 0 else { return 0 }
        return Double(staleRemovals.count + reviewDeletions.count) / Double(actualCount)
    }
}

/// Compute what to do to make a drive (`actual`) match the library (`desired`), keyed by content hash.
/// Pure and total; deterministic (results ordered by hash then path). Per hash `h`, with desired paths
/// `D` and actual paths `A`:
///  - `D` empty  → the library no longer wants this content: every actual path is a **review deletion**.
///  - `A` empty  → the drive doesn't have it: every desired path is a **copy**.
///  - otherwise  → pair the wrong paths (`A−D`) with the needed paths (`D−A`) as **relocations**; any
///                 needed paths left over are **copies**; any wrong paths left over are **stale removals**
///                 (the hash still lives at a retained path). Paths in `D∩A` are already correct — no-ops.
public func computeReconcilePlan(desired: Set<Placement>, actual: Set<Placement>) -> ReconcilePlan {
    var desiredByHash: [String: Set<String>] = [:]
    var actualByHash: [String: Set<String>] = [:]
    for p in desired { desiredByHash[p.hash, default: []].insert(p.path) }
    for p in actual { actualByHash[p.hash, default: []].insert(p.path) }

    var copies: [Placement] = []
    var relocations: [ReconcilePlan.Relocation] = []
    var staleRemovals: [Placement] = []
    var reviewDeletions: [Placement] = []

    for h in Set(desiredByHash.keys).union(actualByHash.keys).sorted() {
        let D = desiredByHash[h] ?? []
        let A = actualByHash[h] ?? []

        if D.isEmpty {                                   // hash gone from the library entirely
            for p in A.sorted() { reviewDeletions.append(Placement(hash: h, path: p)) }
            continue
        }
        if A.isEmpty {                                   // content not on the drive at all
            for p in D.subtracting(A).sorted() { copies.append(Placement(hash: h, path: p)) }
            continue
        }

        let needed = D.subtracting(A).sorted()           // desired paths not present
        let surplus = A.subtracting(D).sorted()          // present paths not desired
        let paired = min(needed.count, surplus.count)
        for i in 0..<paired {
            relocations.append(.init(hash: h, from: surplus[i], to: needed[i]))
        }
        if needed.count > paired {                       // remaining needed placements → duplicate in
            for i in paired..<needed.count { copies.append(Placement(hash: h, path: needed[i])) }
        }
        if surplus.count > paired {                      // remaining wrong paths → stale (hash retained)
            for i in paired..<surplus.count { staleRemovals.append(Placement(hash: h, path: surplus[i])) }
        }
    }

    return ReconcilePlan(copies: copies, relocations: relocations,
                         staleRemovals: staleRemovals, reviewDeletions: reviewDeletions)
}
