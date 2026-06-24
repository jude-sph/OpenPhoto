import Foundation
import CryptoKit

public enum CopyOutcome: Sendable, Equatable { case copied, cancelled, failed(SyncFailureReason) }

public enum VerifiedCopy {
    /// Stream-copy `source` → `dest`: chunk read → temp write → incremental SHA-256, with per-byte
    /// progress and ~chunk-granular cancellation. Atomic (temp → fsync → rename); the destination is
    /// never left partial; an existing dest is never overwritten. The streamed digest is identical to
    /// `ContentHash.ofFile` (SHA-256 over the whole byte stream).
    @discardableResult
    public static func copy(from source: URL, to dest: URL, expectedHash: String,
                            chunkBytes: Int = 4 << 20,
                            onBytes: (@Sendable (Int64) -> Void)? = nil,
                            shouldCancel: (@Sendable () -> Bool)? = nil) -> CopyOutcome {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return .failed(.conflict) }  // caller pre-checks; defensive
        do { try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return .failed(.copyFailed) }
        guard let inFH = try? FileHandle(forReadingFrom: source) else { return .failed(.sourceMissing) }
        defer { try? inFH.close() }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        guard fm.createFile(atPath: tmp.path, contents: nil),
              let outFH = try? FileHandle(forWritingTo: tmp) else { return .failed(.copyFailed) }
        var keepTemp = false
        defer { try? outFH.close(); if !keepTemp { try? fm.removeItem(at: tmp) } }

        var hasher = SHA256()
        var written: Int64 = 0
        while true {
            if shouldCancel?() == true { return .cancelled }
            let chunk: Data
            do { chunk = try autoreleasepool { try inFH.read(upToCount: chunkBytes) } ?? Data() }
            catch { return .failed(.sourceMissing) }
            if chunk.isEmpty { break }
            do { try outFH.write(contentsOf: chunk) } catch { return .failed(.copyFailed) }
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            onBytes?(written)
        }
        do { try outFH.synchronize() } catch { return .failed(.copyFailed) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + hex == expectedHash else { return .failed(.hashMismatch) }
        do { try fm.moveItem(at: tmp, to: dest) } catch { return .failed(.copyFailed) }
        keepTemp = true
        return .copied
    }
}
