import Foundation

/// How many distinct assets the canonical has that a backup is missing — the backup's "behind by N".
/// Pure set difference over content hashes; the actual files to copy come from the `planClone` diff.
public func backupBehindCount(canonicalHashes: Set<String>, backupHashes: Set<String>) -> Int {
    canonicalHashes.subtracting(backupHashes).count
}
