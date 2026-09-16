import AppKit
import OpenPhotoCore

/// Travels use-cases. The sovereign files under `.openphoto/travels/` are the source of truth; every
/// mutation is read-modify-write on one record (or settings.json), then `refreshTravels()` re-derives
/// the summaries from the catalog. Discovered trips (no file yet) are materialised on first edit.
/// Nothing here touches originals — only JSON under the state directory.
extension AppState {

    private var travelsRoot: URL? { library?.vaults.first?.rootURL }

    // MARK: - Derive

    /// Reload settings + records, resolve against the folder tree, derive stats/places per trip.
    func refreshTravels() {
        guard let root = travelsRoot, let cat = library?.catalog else { travels = []; return }
        travelSettings = TravelStore.loadSettings(libraryRoot: root)
        let defs = TravelResolver.resolve(settings: travelSettings,
                                          records: TravelStore.loadAll(libraryRoot: root),
                                          folderTree: folderTree)
        let search = loadedPlaceSearch   // non-forcing: the warm-up fills it in a moment
        let sums = defs.compactMap { def -> TravelSummary? in
            let stats = (try? cat.travelStats(dirPaths: def.folders))
                ?? TravelStats(count: 0, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil)
            guard stats.count > 0 else { return nil }   // a trip with no visible photos isn't shown
            let detected = ((try? cat.travelPlaces(dirPaths: def.folders)) ?? []).map { d in
                search?.place(matching: d)
                    ?? TravelPlace(name: d.city, region: d.region.isEmpty ? nil : d.region,
                                   country: d.country.isEmpty ? nil : d.country, countryCode: d.countryCode)
            }
            return TravelResolver.summarise(def, stats: stats, detectedPlaces: detected)
        }
        travels = TravelResolver.sorted(sums)
        if let sel = selectedTravelID, !travels.contains(where: { $0.id == sel }) { selectedTravelID = nil }
        if selectedTravelID == nil { selectedTravelID = travels.first?.id }
    }

    /// The detected (derived) places for a trip, regardless of any override — for "Use detected".
    func travelDetectedPlaces(_ s: TravelSummary) -> [TravelPlace] {
        let search = loadedPlaceSearch   // non-forcing (see refreshTravels)
        return ((try? library?.catalog.travelPlaces(dirPaths: s.folders)) ?? []).map { d in
            search?.place(matching: d)
                ?? TravelPlace(name: d.city, region: d.region.isEmpty ? nil : d.region,
                               country: d.country.isEmpty ? nil : d.country, countryCode: d.countryCode)
        }
    }

    /// The trip's photos, oldest first (the Travels detail grid).
    func travelItems(_ s: TravelSummary) -> [TimelineItem] {
        (try? library?.catalog.travelItems(dirPaths: s.folders)) ?? []
    }

    /// Aggregate facts for one folder — used by the folder picker before a trip exists.
    func travelStatsForFolder(_ path: String) -> TravelStats {
        (try? library?.catalog.travelStats(dirPaths: [path]))
            ?? TravelStats(count: 0, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil)
    }

    /// The trip (if any) whose folders cover `path` — for the folder context menu.
    func travelID(forFolder path: String) -> String? {
        travels.first { $0.folders.contains { path == $0 || path.hasPrefix($0 + "/") } }?.id
    }

    // MARK: - Mutations

    func setTravelName(id: String, _ name: String?) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateTravel(id) { $0.name = (t?.isEmpty ?? true) ? nil : t }
    }

    func addTravelFolder(id: String, _ path: String) {
        mutateTravel(id) { $0.folders = TravelResolver.normalise(folders: $0.folders + [path]) }
    }

    /// Removing a trip's last folder would leave nothing to show, so it removes the trip instead.
    func removeTravelFolder(id: String, _ path: String) {
        guard let s = travels.first(where: { $0.id == id }) else { return }
        if s.folders.count <= 1 { removeTravel(id: id); return }
        mutateTravel(id) { $0.folders.removeAll { $0 == path } }
    }

    func setTravelDates(id: String, start: String?, end: String?) {
        mutateTravel(id) { r in
            r.startDate = start
            r.endDate = end
            if let s = r.startDate, let e = r.endDate, s > e { r.endDate = s }
        }
    }

    func setTravelPlaces(id: String, _ places: [TravelPlace]?) { mutateTravel(id) { $0.places = places } }

    func setTravelCover(id: String, _ hash: String?) { mutateTravel(id) { $0.coverHash = hash } }

    /// Remove from Travels only: a record is deleted (its file), a discovered trip is hidden. Files on
    /// disk are never touched.
    func removeTravel(id: String) {
        guard let root = travelsRoot, let s = travels.first(where: { $0.id == id }) else { return }
        if let r = s.definition.record {
            // A record folder that is a direct child of the Travels folder would simply be
            // re-discovered on the next refresh (with derived name/dates, losing the user's edits),
            // so hide those folders before the file goes — "removed" has to stay removed.
            var st = travelSettings
            if let tf = travelSettings.travelsFolder {
                for f in r.folders where (f as NSString).deletingLastPathComponent == tf && !st.hidden.contains(f) {
                    st.hidden.append(f)
                }
            }
            if st != travelSettings {
                do { try TravelStore.saveSettings(st, libraryRoot: root) } catch { NSAlert(error: error).runModal(); return }
            }
            TravelStore.delete(id: r.id, libraryRoot: root)
        } else if case .discovered(let p) = s.definition.source {
            var st = travelSettings
            if !st.hidden.contains(p) { st.hidden.append(p) }
            do { try TravelStore.saveSettings(st, libraryRoot: root) } catch { NSAlert(error: error).runModal(); return }
        }
        if selectedTravelID == id { selectedTravelID = nil }
        if openedTravelID == id { openedTravelID = nil }
        refreshTravels(); refreshToken += 1
    }

    /// New trip from any folder. Returns the record id (nil on failure or if already covered).
    @discardableResult
    func createTravel(folder path: String) -> String? {
        guard let root = travelsRoot, travelID(forFolder: path) == nil else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let r = TravelRecord(id: UUID().uuidString, name: nil, folders: [path], startDate: nil, endDate: nil,
                             places: nil, coverHash: nil, createdAtMs: now, modifiedAtMs: now)
        do { try TravelStore.save(r, libraryRoot: root) } catch { NSAlert(error: error).runModal(); return nil }
        refreshTravels(); refreshToken += 1
        selectedTravelID = r.id
        return r.id
    }

    /// Choose the Travels folder (nil = none). Changing the folder clears `hidden` (it was per-folder).
    func setTravelsFolder(_ path: String?, auto: Bool) {
        guard let root = travelsRoot else { return }
        var s = travelSettings
        if s.travelsFolder != path { s.hidden = [] }
        s.travelsFolder = path
        s.autoDiscover = auto
        do { try TravelStore.saveSettings(s, libraryRoot: root) } catch { NSAlert(error: error).runModal(); return }
        refreshTravels(); refreshToken += 1
    }

    /// From the folder tree: jump to Travels with this folder's trip focused.
    func showInTravels(folder path: String) {
        selection = .travels
        openedDevice = nil
        if let id = travelID(forFolder: path) { selectedTravelID = id }
    }

    /// After a folder move/rename, keep trips pointing at their folders (records + settings).
    func rewriteTravelPaths(from src: String, to dst: String) {
        guard let root = travelsRoot else { return }
        let out = TravelResolver.rewritePaths(records: TravelStore.loadAll(libraryRoot: root),
                                              settings: TravelStore.loadSettings(libraryRoot: root),
                                              from: src, to: dst)
        for r in out.records where out.changedRecordIDs.contains(r.id) { try? TravelStore.save(r, libraryRoot: root) }
        if out.settings != travelSettings { try? TravelStore.saveSettings(out.settings, libraryRoot: root) }
        refreshTravels()   // the post-move rescan refreshed before these rewrites landed
    }

    // MARK: - Helpers

    /// Read-modify-write one trip. A discovered trip is first materialised as a record with its one
    /// folder; the selection follows the new id.
    private func mutateTravel(_ id: String, _ edit: (inout TravelRecord) -> Void) {
        guard let root = travelsRoot, let s = travels.first(where: { $0.id == id }) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var rec: TravelRecord
        if let existing = s.definition.record, let fresh = TravelStore.load(id: existing.id, libraryRoot: root) {
            rec = fresh
        } else {
            rec = TravelRecord(id: UUID().uuidString, name: nil, folders: s.folders, startDate: nil, endDate: nil,
                               places: nil, coverHash: nil, createdAtMs: now, modifiedAtMs: now)
        }
        edit(&rec)
        rec.folders = TravelResolver.normalise(folders: rec.folders)
        rec.modifiedAtMs = now
        do { try TravelStore.save(rec, libraryRoot: root) } catch { NSAlert(error: error).runModal(); return }
        if selectedTravelID == id { selectedTravelID = rec.id }
        if openedTravelID == id { openedTravelID = rec.id }
        refreshTravels(); refreshToken += 1
    }
}
