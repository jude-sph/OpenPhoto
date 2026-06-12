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
        public let skipped: Int    // files skipped due to read errors
    }

    public static func scan(vault: Vault, catalog: Catalog,
                            progress: (Progress) -> Void = { _ in }) async throws -> Result {
        let fm = FileManager.default

        // 1. Walk — skip .openphoto dirs, hidden files, non-media.
        progress(Progress(stage: .walking, done: 0, total: 0))
        // size is optional: URLResourceKey.fileSizeKey may be nil on some filesystems (Fix 1).
        var found: [(rel: String, url: URL, size: Int64?, mtime: Date, kind: MediaKind)] = []
        var skipped = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = fm.enumerator(at: vault.rootURL, includingPropertiesForKeys: keys,
                                       options: [.skipsHiddenFiles])!
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true {
                    if url.lastPathComponent == Vault.stateDirName { enumerator.skipDescendants() }
                    continue
                }
                guard let kind = MediaKind.of(filename: url.lastPathComponent) else { continue }
                // Capture size as optional — nil forces rehash later (Fix 1).
                let size: Int64? = values.fileSize.map { Int64($0) }
                found.append((vault.relativePath(of: url), url,
                              size,
                              values.contentModificationDate ?? Date(), kind))
            } catch {
                // Unreadable attributes — skip this file, don't abort the scan (Fix 2).
                skipped += 1
                continue
            }
        }

        // 2. Fast-path against the manifest: reuse hash when size+mtime match (format §4).
        //    nil size always forces rehash (Fix 1).
        //    An unreadable file is skipped and not added to entries (Fix 2).
        //    We collect (ManifestEntry, found-tuple) as aligned pairs to avoid index drift.
        let oldByPath = Dictionary(uniqueKeysWithValues:
            try Manifest.read(from: vault.manifestURL).map { ($0.path, $0) })
        var aligned: [(entry: ManifestEntry, f: (rel: String, url: URL, size: Int64?, mtime: Date, kind: MediaKind))] = []
        var hashedCount = 0
        for (i, f) in found.enumerated() {
            let mtimeStr = ISO8601Millis.string(from: f.mtime)
            // Fast-path only when we have a real size AND it matches the manifest (Fix 1).
            if let s = f.size, let old = oldByPath[f.rel], old.size == s, old.mtime == mtimeStr {
                aligned.append((old, f))
            } else {
                progress(Progress(stage: .hashing, done: i, total: found.count))
                do {
                    let hash = try ContentHash.ofFile(at: f.url)
                    // Resolve a real size: prefer the walk value, then stat, then 0.
                    let realSize: Int64 = f.size
                        ?? ((try? fm.attributesOfItem(atPath: f.url.path)[.size] as? Int64) ?? nil)
                        ?? 0
                    aligned.append((ManifestEntry(hash: hash, path: f.rel,
                                                  size: realSize, mtime: mtimeStr), f))
                    hashedCount += 1
                } catch {
                    // Unreadable file body — skip, don't append to entries (Fix 2).
                    skipped += 1
                    continue
                }
            }
        }

        // 3. Extract metadata for hashes the catalog doesn't know yet.
        let known = try catalog.knownHashes()
        var newAssets: [AssetRecord] = []
        var pairCandidates: [LivePhotoPairer.Candidate] = []
        for (idx, (entry, f)) in aligned.enumerated() {
            let isNew = !known.contains(entry.hash.stringValue)
            var meta: MediaMetadata?
            if isNew {
                progress(Progress(stage: .extracting, done: idx, total: aligned.count))
                let m = await MetadataExtractor.extract(from: f.url, kind: f.kind)
                meta = m
                // Base layer: human metadata embedded in the file (Takeout/Apple imports,
                // or any file dragged in with embedded XMP). The `.openphoto/` sidecar
                // ingested after the scan still overrides this (sidecar > embedded).
                let embedded = (f.kind == .photo) ? EmbeddedMetadata.read(from: f.url) : nil
                let embeddedTagsJSON = embedded.flatMap {
                    try? String(data: JSONEncoder().encode($0.tags), encoding: .utf8) ?? "[]"
                } ?? "[]"
                newAssets.append(AssetRecord(
                    hash: entry.hash.stringValue, kind: f.kind.rawValue,
                    takenAtMs: Int64(m.takenAt.timeIntervalSince1970 * 1000),
                    pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                    latitude: m.latitude, longitude: m.longitude,
                    cameraModel: m.cameraModel, lensModel: m.lensModel,
                    durationSeconds: m.durationSeconds,
                    livePairHash: nil, isLivePairedVideo: false,
                    favorite: embedded?.favorite ?? false,
                    rating: embedded?.rating ?? 0,
                    caption: embedded?.caption,
                    tagsJSON: embeddedTagsJSON))
            }
            // Every file participates in pairing (contentIdentifier only known for new files).
            pairCandidates.append(.init(
                hash: entry.hash, relPath: entry.path, kind: f.kind,
                takenAt: meta?.takenAt ?? f.mtime, contentIdentifier: meta?.contentIdentifier))
        }

        // 4. Pair Live Photos and persist: upsert plain assets first, then setLivePair for
        //    ALL pairs so healing works even when both halves were already cataloged (Fix 3).
        //    setLivePair is idempotent — calling it for already-paired assets is a cheap no-op.
        try catalog.upsert(assets: newAssets)
        for pair in LivePhotoPairer.pair(candidates: pairCandidates) {
            try catalog.setLivePair(photoHash: pair.photoHash.stringValue,
                                    videoHash: pair.videoHash.stringValue)
        }

        // 5. Persist: instances (wholesale replace), manifest (atomic).
        let instances = aligned.map { entry, f in
            InstanceRecord(hash: entry.hash.stringValue, vaultID: vault.descriptor.vaultID,
                           relPath: entry.path,
                           dirPath: (entry.path as NSString).deletingLastPathComponent,
                           size: entry.size,
                           mtimeMs: Int64((ISO8601Millis.date(from: entry.mtime) ?? Date())
                               .timeIntervalSince1970 * 1000))
        }
        try catalog.replaceInstances(inVault: vault.descriptor.vaultID, with: instances)
        try Manifest.write(aligned.map(\.entry), to: vault.manifestURL)
        // Single .finishing emission after manifest is written (Fix 4 — removed the earlier one).
        progress(Progress(stage: .finishing, done: found.count, total: found.count))
        return Result(total: found.count, hashed: hashedCount, skipped: skipped)
    }
}
