import Foundation

/// Live Photo = still + video pairing — vault-format-v1 §6.
public enum LivePhotoPairer {
    public struct Candidate: Sendable {
        public let hash: ContentHash
        public let relPath: String
        public let kind: MediaKind
        public let takenAt: Date
        public let contentIdentifier: String?
        public init(hash: ContentHash, relPath: String, kind: MediaKind,
                    takenAt: Date, contentIdentifier: String?) {
            self.hash = hash; self.relPath = relPath; self.kind = kind
            self.takenAt = takenAt; self.contentIdentifier = contentIdentifier
        }
    }
    public struct Pair: Equatable, Sendable {
        public let photoHash: ContentHash
        public let videoHash: ContentHash
        public let photoRelPath: String
        public let videoRelPath: String
    }

    public static func pair(candidates: [Candidate]) -> [Pair] {
        let photos = candidates.filter { $0.kind == .photo }
        let videos = candidates.filter { $0.kind == .video }
        var pairedVideos = Set<String>()
        var result: [Pair] = []

        // 1. Content identifier match (authoritative).
        var videosByCid: [String: Candidate] = [:]
        for v in videos { if let c = v.contentIdentifier { videosByCid[c] = v } }
        var unpaired: [Candidate] = []
        for p in photos {
            if let c = p.contentIdentifier, let v = videosByCid[c] {
                result.append(Pair(photoHash: p.hash, videoHash: v.hash,
                                   photoRelPath: p.relPath, videoRelPath: v.relPath))
                pairedVideos.insert(v.relPath)
            } else {
                unpaired.append(p)
            }
        }

        // 2. Fallback: a still + .mov sharing the exact basename in the same folder
        //    is Apple's Live Photo signature. No capture-time check — an imported
        //    .mov's metadata time is often unreliable (can be years off the photo's
        //    EXIF date), which is why time-gated pairing missed imported Live Photos.
        func dir(_ s: String) -> String { (s as NSString).deletingLastPathComponent }
        func base(_ s: String) -> String {
            ((s as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        }
        var videosByKey: [String: Candidate] = [:]
        for v in videos where !pairedVideos.contains(v.relPath) {
            videosByKey[dir(v.relPath) + "|" + base(v.relPath)] = v
        }
        var usedVideos = Set<String>()
        for p in unpaired {
            let key = dir(p.relPath) + "|" + base(p.relPath)
            guard let v = videosByKey[key], !usedVideos.contains(v.relPath) else { continue }
            usedVideos.insert(v.relPath)
            result.append(Pair(photoHash: p.hash, videoHash: v.hash,
                               photoRelPath: p.relPath, videoRelPath: v.relPath))
        }
        return result
    }
}
