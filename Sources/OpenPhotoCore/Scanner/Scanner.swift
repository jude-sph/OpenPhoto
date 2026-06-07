import Foundation

public enum Scanner {
    public struct Progress: Sendable {
        public enum Stage: String, Sendable { case walking, hashing, extracting, finishing }
        public let stage: Stage
        public let done: Int
        public let total: Int
    }

    public struct Result: Sendable {
        public let total: Int      // media files seen
        public let hashed: Int     // files that needed hashing (new/changed)
    }

    public static func scan(vault: Vault, catalog: Catalog,
                            progress: (Progress) -> Void = { _ in }) async throws -> Result {
        let fm = FileManager.default

        // 1. Walk — skip .openphoto dirs, hidden files, non-media.
        progress(Progress(stage: .walking, done: 0, total: 0))
        var found: [(rel: String, url: URL, size: Int64, mtime: Date, kind: MediaKind)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = fm.enumerator(at: vault.rootURL, includingPropertiesForKeys: keys,
                                       options: [.skipsHiddenFiles])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if url.lastPathComponent == Vault.stateDirName { enumerator.skipDescendants() }
                continue
            }
            guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
            found.append((vault.relativePath(of: url), url,
                          Int64(values.fileSize ?? 0),
                          values.contentModificationDate ?? Date(), kind))
        }

        // 2. Fast-path against the manifest: reuse hash when size+mtime match (format §4).
        let oldByPath = Dictionary(uniqueKeysWithValues:
            try Manifest.read(from: vault.manifestURL).map { ($0.path, $0) })
        var entries: [ManifestEntry] = []
        var hashedCount = 0
        for (i, f) in found.enumerated() {
            let mtimeStr = ISO8601Millis.string(from: f.mtime)
            if let old = oldByPath[f.rel], old.size == f.size, old.mtime == mtimeStr {
                entries.append(old)
            } else {
                progress(Progress(stage: .hashing, done: i, total: found.count))
                entries.append(ManifestEntry(hash: try ContentHash.ofFile(at: f.url),
                                             path: f.rel, size: f.size, mtime: mtimeStr))
                hashedCount += 1
            }
        }

        // 3. Extract metadata for hashes the catalog doesn't know yet.
        let known = try catalog.knownHashes()
        var newAssets: [AssetRecord] = []
        var pairCandidates: [LivePhotoPairer.Candidate] = []
        for (i, (entry, f)) in zip(entries, found).enumerated() {
            let isNew = !known.contains(entry.hash.stringValue)
            var meta: MediaMetadata?
            if isNew {
                progress(Progress(stage: .extracting, done: i, total: found.count))
                let m = await MetadataExtractor.extract(from: f.url, kind: f.kind)
                meta = m
                newAssets.append(AssetRecord(
                    hash: entry.hash.stringValue, kind: f.kind.rawValue,
                    takenAtMs: Int64(m.takenAt.timeIntervalSince1970 * 1000),
                    pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                    latitude: m.latitude, longitude: m.longitude,
                    cameraModel: m.cameraModel, lensModel: m.lensModel,
                    durationSeconds: m.durationSeconds,
                    livePairHash: nil, isLivePairedVideo: false,
                    favorite: false, rating: 0, caption: nil, tagsJSON: "[]"))
            }
            // Every file participates in pairing (CID only known for new files).
            pairCandidates.append(.init(
                hash: entry.hash, relPath: entry.path, kind: f.kind,
                takenAt: meta?.takenAt ?? f.mtime, contentIdentifier: meta?.contentIdentifier))
        }

        // 4. Pair Live Photos among this vault's files (pairing is established the
        //    first time both halves are seen; existing pairs persist in the catalog).
        var assetsByHash = Dictionary(uniqueKeysWithValues: newAssets.map { ($0.hash, $0) })
        for pair in LivePhotoPairer.pair(candidates: pairCandidates) {
            assetsByHash[pair.photoHash.stringValue]?.livePairHash = pair.videoHash.stringValue
            assetsByHash[pair.videoHash.stringValue]?.isLivePairedVideo = true
        }

        // 5. Persist: assets, instances (wholesale replace), manifest (atomic).
        progress(Progress(stage: .finishing, done: found.count, total: found.count))
        try catalog.upsert(assets: Array(assetsByHash.values))
        let instances = zip(entries, found).map { entry, f in
            InstanceRecord(hash: entry.hash.stringValue, vaultID: vault.descriptor.vaultID,
                           relPath: entry.path,
                           dirPath: (entry.path as NSString).deletingLastPathComponent,
                           size: entry.size,
                           mtimeMs: Int64((ISO8601Millis.date(from: entry.mtime) ?? Date())
                               .timeIntervalSince1970 * 1000))
        }
        try catalog.replaceInstances(inVault: vault.descriptor.vaultID, with: instances)
        try Manifest.write(entries, to: vault.manifestURL)
        progress(Progress(stage: .finishing, done: found.count, total: found.count))
        return Result(total: found.count, hashed: hashedCount)
    }
}
