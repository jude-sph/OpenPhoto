import SwiftUI
import MapKit
import OpenPhotoCore

// MARK: — Cluster model

/// One pin on the map: either a single photo or a cluster of nearby photos.
/// Approach: manual grid-clustering in Swift — we bucket `GeoAsset`s into a lat/lon grid
/// whose cell size is proportional to the visible map region's span, recomputed on pan/zoom
/// (debounced). This gives Apple-Photos-style clustering without the `MKAnnotationView`
/// boilerplate of NSViewRepresentable + MKMapView; the SwiftUI `Map { Annotation }` API on
/// macOS 15 is sufficient for our use (thumbnail bubbles + count badges).
struct MapCluster: Identifiable {
    // Stable identity = the representative photo's hash. A cluster that persists across a recluster
    // (small pan) keeps the SAME identity, so SwiftUI/MapKit reuse its annotation view — and its
    // thumbnail — instead of recycling. (Was `UUID()` regenerated every recluster, which churned
    // identities so MapKit showed other pins' thumbnails until tapped.) Each asset is the rep of at
    // most one bucket, so this is unique within a clustering.
    var id: String { representativeHash }
    let lat: Double
    let lon: Double
    let count: Int
    let representativeHash: String   // newest asset in the cluster (for the thumbnail)
    let hashes: [String]             // all assets in the cluster (for the grid sheet)
}

// MARK: — MapView

struct MapView: View {
    @Bindable var state: AppState

    // All geotagged assets (fetched once + on library change)
    @State private var allAssets: [GeoAsset] = []
    // Current clusters (recomputed from allAssets + region)
    @State private var clusters: [MapCluster] = []
    // The visible map region
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var currentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 160)
    )
    // Debounce handle for clustering on region change
    @State private var clusterTask: Task<Void, Never>?
    // Selected cluster → show grid sheet
    @State private var selectedCluster: MapCluster?
    // Items resolved for the grid sheet
    @State private var sheetItems: [TimelineItem] = []

    private var thumbPixels: Int { gridThumbnailPixels(forCellMin: state.gridMinSize) }

    var body: some View {
        ZStack {
            if allAssets.isEmpty {
                emptyState
            } else {
                mapContent
            }
        }
        .task { await loadAssets() }
        .sheet(item: $selectedCluster) { cluster in
            clusterSheet(cluster)
        }
    }

    // MARK: — Map content

    private var mapContent: some View {
        Map(position: $mapPosition) {
            ForEach(clusters) { cluster in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(latitude: cluster.lat, longitude: cluster.lon),
                    anchor: .center
                ) {
                    clusterBubble(cluster)
                }
            }
        }
        .mapStyle(.standard)
        .onMapCameraChange { context in
            currentRegion = context.region
            scheduleRecluster()
        }
    }

    // MARK: — Cluster bubble annotation

    @ViewBuilder
    private func clusterBubble(_ cluster: MapCluster) -> some View {
        Button {
            handleTap(cluster)
        } label: {
            ZStack(alignment: .topTrailing) {
                // Thumbnail (56×56 rounded square)
                thumbnailBubble(hash: cluster.representativeHash)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                // Count badge (only for clusters with more than 1 photo)
                if cluster.count > 1 {
                    Text("\(cluster.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnailBubble(hash: String) -> some View {
        if let lib = state.library {
            ThumbnailImage(
                id: hash,
                provider: { px in
                    let h = ContentHash(stringValue: hash)
                    // Generate from the file if it isn't cached — map representatives often haven't
                    // been browsed, so nothing's in the store yet (otherwise the pin stays blank).
                    if let item = try? lib.catalog.items(forHashes: [hash], preservingOrder: false).first,
                       let url = lib.absoluteURL(for: item) {
                        let kind = MediaKind(rawValue: item.kind) ?? .photo
                        if let img = try? await lib.thumbnails.displayImage(
                            for: h, sourceURL: url, kind: kind, maxPixel: px) {
                            return img
                        }
                    }
                    return await lib.thumbnails.cachedDisplayImage(for: h, maxPixel: px)
                },
                targetPixel: thumbPixels
            )
        } else {
            Theme.tile.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: — Tap handling

    private func handleTap(_ cluster: MapCluster) {
        if cluster.count == 1 {
            // Single photo → open viewer
            Task {
                if let lib = state.library,
                   let item = try? lib.catalog.items(forHashes: cluster.hashes, preservingOrder: false).first {
                    await MainActor.run {
                        state.openViewer(item, within: [item])
                    }
                }
            }
        } else {
            // Multi-photo cluster → zoom to split it (or show grid if already zoomed in)
            let spanLat = currentRegion.span.latitudeDelta
            if spanLat < 0.5 {
                // Already zoomed in — show the grid sheet for these photos
                openClusterSheet(cluster)
            } else {
                // Zoom into this cluster's bounding region to split it
                zoomIntoCluster(cluster)
            }
        }
    }

    private func zoomIntoCluster(_ cluster: MapCluster) {
        // Compute bounding box of the cluster's assets, then animate to it
        let assets = allAssets.filter { cluster.hashes.contains($0.hash) }
        guard !assets.isEmpty else { return }
        let minLat = assets.map(\.lat).min()!
        let maxLat = assets.map(\.lat).max()!
        let minLon = assets.map(\.lon).min()!
        let maxLon = assets.map(\.lon).max()!
        let padFactor = 2.5
        let spanLat = max(0.01, (maxLat - minLat) * padFactor)
        let spanLon = max(0.01, (maxLon - minLon) * padFactor)
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
        withAnimation(.easeInOut(duration: 0.5)) {
            mapPosition = .region(region)
        }
    }

    private func openClusterSheet(_ cluster: MapCluster) {
        selectedCluster = cluster
        Task {
            guard let lib = state.library else { return }
            let items = (try? lib.catalog.items(forHashes: cluster.hashes, preservingOrder: false)) ?? []
            sheetItems = items.sorted { $0.takenAtMs > $1.takenAtMs }
        }
    }

    // MARK: — Cluster grid sheet

    @ViewBuilder
    private func clusterSheet(_ cluster: MapCluster) -> some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text("\(cluster.count) photos here")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    selectedCluster = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textFaint)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: Theme.toolbarHeight)
            Divider().overlay(Theme.hairline)

            if sheetItems.isEmpty {
                Spacer()
                ProgressView().controlSize(.regular)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: state.gridMinSize), spacing: Theme.gridGap)],
                        spacing: Theme.gridGap
                    ) {
                        ForEach(sheetItems, id: \.instanceID) { item in
                            MediaTile(
                                id: item.instanceID,
                                selectMode: false,
                                selected: false,
                                rubberBandSpace: nil,
                                thumbnail: ThumbnailImage(
                                    timelineItem: item,
                                    library: state.library!,
                                    targetPixel: thumbPixels
                                ),
                                badges: {
                                    TimelineTileBadges(
                                        item: item,
                                        backedUp: state.isBackedUpOnCanonical(item)
                                    )
                                },
                                onTap: {
                                    selectedCluster = nil
                                    state.openViewer(item, within: sheetItems)
                                }
                            )
                        }
                    }
                    .padding(Theme.gridGap)
                }
            }
        }
        .background(Theme.windowBG)
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: — Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text("No photos with location")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Photos with GPS metadata will appear here as a map.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Theme.windowBG)
    }

    // MARK: — Asset loading

    private func loadAssets() async {
        guard let lib = state.library else { return }
        let assets = await Task.detached(priority: .userInitiated) {
            (try? lib.catalog.geotaggedAssets()) ?? []
        }.value
        allAssets = assets
        recluster(region: currentRegion)
        // Set the map to show all assets on first load
        if !assets.isEmpty {
            fitMapToAssets(assets)
        }
    }

    private func fitMapToAssets(_ assets: [GeoAsset]) {
        guard !assets.isEmpty else { return }
        let minLat = assets.map(\.lat).min()!
        let maxLat = assets.map(\.lat).max()!
        let minLon = assets.map(\.lon).min()!
        let maxLon = assets.map(\.lon).max()!
        let padFactor = 1.3
        let spanLat = max(1.0, (maxLat - minLat) * padFactor)
        let spanLon = max(1.0, (maxLon - minLon) * padFactor)
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        mapPosition = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        ))
    }

    // MARK: — Clustering

    /// Debounce region changes and recluster off the main actor.
    private func scheduleRecluster() {
        clusterTask?.cancel()
        clusterTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let region = currentRegion
            let assets = allAssets
            let computed = await Task.detached(priority: .userInitiated) {
                MapView.cluster(assets: assets, region: region)
            }.value
            guard !Task.isCancelled else { return }
            clusters = computed
        }
    }

    private func recluster(region: MKCoordinateRegion) {
        let assets = allAssets
        Task.detached(priority: .userInitiated) {
            let computed = MapView.cluster(assets: assets, region: region)
            await MainActor.run { self.clusters = computed }
        }
    }

    /// Grid-based clustering: divide the visible span into an NxN grid (N = gridDivisions),
    /// bucket each asset into a cell, and produce one `MapCluster` per occupied cell.
    /// The representative is the newest asset (highest takenAtMs) in the bucket.
    /// Assets outside the visible region are also clustered (they remain in the annotation
    /// list so MapKit can show them when panning slightly beyond the region).
    /// `nonisolated` so it can be called from detached tasks without an implicit async hop.
    nonisolated private static func cluster(assets: [GeoAsset], region: MKCoordinateRegion,
                                             gridDivisions: Int = 8) -> [MapCluster] {
        guard !assets.isEmpty else { return [] }
        let cellLat = region.span.latitudeDelta / Double(gridDivisions)
        let cellLon = region.span.longitudeDelta / Double(gridDivisions)
        // Clamp to a reasonable minimum cell so we don't over-split at extreme zooms
        let minCell = 0.001
        let effCellLat = max(minCell, cellLat)
        let effCellLon = max(minCell, cellLon)

        // Bucket: (lat_cell, lon_cell) → [GeoAsset]
        var buckets: [BucketKey: [GeoAsset]] = [:]
        for asset in assets {
            let la = Int(floor(asset.lat / effCellLat))
            let lo = Int(floor(asset.lon / effCellLon))
            let key = BucketKey(la: la, lo: lo)
            buckets[key, default: []].append(asset)
        }

        return buckets.values.map { members in
            // Representative = newest by takenAtMs
            let rep = members.max(by: { $0.takenAtMs < $1.takenAtMs })!
            // Cluster center = centroid of members
            let lat = members.map(\.lat).reduce(0, +) / Double(members.count)
            let lon = members.map(\.lon).reduce(0, +) / Double(members.count)
            return MapCluster(
                lat: lat,
                lon: lon,
                count: members.count,
                representativeHash: rep.hash,
                hashes: members.map(\.hash)
            )
        }
    }

    private struct BucketKey: Hashable {
        let la: Int
        let lo: Int
    }
}
