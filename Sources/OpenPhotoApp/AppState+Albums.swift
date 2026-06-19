import AppKit
import OpenPhotoCore

// Album use-cases. Each mutation is read-modify-write on the sovereign JSON file (the source of
// truth), mirrored into the catalog, then the sidebar summaries are refreshed. Members are content
// hashes; dedup is enforced here so the file never stores a hash twice.
extension AppState {

    private var albumsLibraryRoot: URL? { library?.vaults.first?.rootURL }

    /// Reload album summaries from the catalog mirror (honors the current locked-reveal state).
    func refreshAlbums() {
        albums = (try? library?.catalog.albumSummaries()) ?? []
    }

    /// Create an album (optionally seeded with `fromHashes`). Returns its id, or nil on failure.
    @discardableResult
    func createAlbum(name: String, fromHashes hashes: [String] = []) -> String? {
        guard let root = albumsLibraryRoot else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rec = AlbumRecord(id: UUID().uuidString, name: trimmed,
                              createdAtMs: now, modifiedAtMs: now, members: dedupHashes(hashes))
        do {
            try AlbumStore.save(rec, libraryRoot: root)
            try library?.catalog.upsertAlbum(rec)
        } catch { NSAlert(error: error).runModal(); return nil }
        refreshAlbums(); refreshToken += 1
        return rec.id
    }

    func renameAlbum(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateAlbum(id) { $0.name = trimmed }
    }

    func deleteAlbum(id: String) {
        guard let root = albumsLibraryRoot else { return }
        AlbumStore.delete(id: id, libraryRoot: root)
        try? library?.catalog.deleteAlbumMirror(id: id)
        if selectedAlbumID == id { selectedAlbumID = nil }
        refreshAlbums(); refreshToken += 1
    }

    /// Append the given photos (content hashes) to an album, skipping any already present (dedup),
    /// preserving the existing order; new ones are appended in the given order.
    func addToAlbum(hashes: [String], albumID: String) {
        mutateAlbum(albumID) { rec in
            let existing = Set(rec.members)
            rec.members.append(contentsOf: dedupHashes(hashes).filter { !existing.contains($0) })
        }
    }

    func removeFromAlbum(hashes: [String], albumID: String) {
        let drop = Set(hashes)
        mutateAlbum(albumID) { rec in rec.members.removeAll { drop.contains($0) } }
    }

    /// Replace the member order from a drag result (the full ordered hash list).
    func reorderAlbum(id: String, orderedHashes: [String]) {
        mutateAlbum(id) { $0.members = dedupHashes(orderedHashes) }
    }

    func setAlbumCover(id: String, hash: String) {
        mutateAlbum(id) { $0.coverHash = hash }
    }

    // MARK: helpers

    private func dedupHashes(_ hashes: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for h in hashes where seen.insert(h).inserted { out.append(h) }
        return out
    }

    /// Read-modify-write one album: load its JSON, apply `edit`, bump `modifiedAtMs`, save + mirror +
    /// refresh. No-op if the album is missing (defensive).
    private func mutateAlbum(_ id: String, _ edit: (inout AlbumRecord) -> Void) {
        guard let root = albumsLibraryRoot, var rec = AlbumStore.load(id: id, libraryRoot: root) else { return }
        edit(&rec)
        rec.modifiedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try AlbumStore.save(rec, libraryRoot: root)
            try library?.catalog.upsertAlbum(rec)
        } catch { NSAlert(error: error).runModal(); return }
        refreshAlbums(); refreshToken += 1
    }
}
