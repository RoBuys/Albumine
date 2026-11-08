import MapKit
import SwiftUI

/// Map of geotagged photos. Nearby photos are clustered according to the zoom level;
/// clicking a cluster shows its photos at the bottom (double-click: viewer).
struct PhotoMapView: View {
    @Environment(PhotoLibrary.self) private var library
    let photos: [Photo]
    @Binding var selection: Set<String>
    let onOpen: (_ list: [Photo], _ index: Int) -> Void

    struct Cluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let photos: [Photo]
    }

    /// Framing computed only once. Never `.automatic`: the map would reframe on every
    /// new geotagged photo (during discovery) → reframe → recluster → reframe…
    /// until AppKit kills the app (too many layout passes).
    @Etat private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.5, longitude: 2.5),
        span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12)))
    @Etat private var didFrame = false
    @Etat private var region: MKCoordinateRegion?
    @Etat private var reclusterTask: Task<Void, Never>?
    @Etat private var clusters: [Cluster] = []
    @Etat private var selectedCluster: Cluster?

    private var located: [Photo] { photos.filter(\.hasLocation) }

    var body: some View {
        if located.isEmpty {
            ContentUnavailableView {
                Label("Aucune photo géolocalisée", systemImage: "map")
            } description: {
                Text(library.isReadingExif
                     ? "Les coordonnées GPS sont en cours de lecture (\(library.exifDone.formatted()) / \(library.exifTotal.formatted())). Les photos apparaîtront au fur et à mesure."
                     : "Aucune photo de cette vue ne contient de coordonnées GPS.")
            }
        } else {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    ForEach(clusters) { cluster in
                        Annotation("", coordinate: cluster.coordinate, anchor: .bottom) {
                            ClusterPin(cluster: cluster, rotation: library.rotation(of: cluster.photos[0]),
                                       selected: selectedCluster?.id == cluster.id)
                                .onTapGesture {
                                    selectedCluster = cluster
                                    selection = Set(cluster.photos.map(\.id))
                                }
                        }
                    }
                }
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Ignore tiny variations (rounding) that would trigger a useless recluster.
                    if let r = region,
                       abs(r.center.latitude - context.region.center.latitude) < r.span.latitudeDelta / 50,
                       abs(r.center.longitude - context.region.center.longitude) < r.span.longitudeDelta / 50,
                       abs(r.span.latitudeDelta - context.region.span.latitudeDelta) < r.span.latitudeDelta / 50 {
                        return
                    }
                    region = context.region
                    scheduleRecluster()
                }
                .task(id: located.count) {
                    if !didFrame { frameOnce() }
                    scheduleRecluster()
                }

                if let cluster = selectedCluster {
                    strip(cluster)
                }
            }
        }
    }

    private func strip(_ cluster: Cluster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(cluster.photos.count) photo\(cluster.photos.count > 1 ? "s" : "") ici")
                    .font(.headline)
                Spacer()
                Button("Ouvrir") { onOpen(cluster.photos, 0) }
                Button { selectedCluster = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(cluster.photos.enumerated()), id: \.element.id) { i, photo in
                        ThumbnailView(url: photo.url, rotation: library.rotation(of: photo))
                            .frame(width: 96, height: 96)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(selection.contains(photo.id) ? Color.accentColor : .clear, lineWidth: 2))
                            .gesture(TapGesture(count: 2).onEnded { onOpen(cluster.photos, i) })
                            .simultaneousGesture(TapGesture().onEnded { selection = [photo.id] })
                    }
                }
            }
            .frame(height: 100)
        }
        .padding(10)
        .background(.regularMaterial)
    }

    /// Frames the map on the photos, once (afterwards only the user moves it).
    private func frameOnce() {
        let list = located
        guard !list.isEmpty else { return }
        let lats = list.compactMap(\.latitude), lons = list.compactMap(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        let r = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(max((maxLat - minLat) * 1.3, 0.05), 170),
                                   longitudeDelta: min(max((maxLon - minLon) * 1.3, 0.05), 350)))
        didFrame = true
        region = r
        camera = .region(r)
    }

    /// Deferred, coalesced clustering: never during a layout pass.
    private func scheduleRecluster() {
        reclusterTask?.cancel()
        reclusterTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            recluster()
        }
    }

    /// Clusters photos on a grid of about 10 × 10 cells over the visible area.
    private func recluster() {
        let list = located
        let span = region?.span ?? MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 300)
        let cellLat = max(span.latitudeDelta / 10, 0.0005)
        let cellLon = max(span.longitudeDelta / 10, 0.0005)
        var buckets: [String: [Photo]] = [:]
        for p in list {
            guard let lat = p.latitude, let lon = p.longitude else { continue }
            if let r = region {
                // Visible area + a margin, to avoid drawing thousands of off-screen pins.
                guard abs(lat - r.center.latitude) < r.span.latitudeDelta,
                      abs(lon - r.center.longitude) < r.span.longitudeDelta else { continue }
            }
            let key = "\(Int(floor(lat / cellLat)))|\(Int(floor(lon / cellLon)))"
            buckets[key, default: []].append(p)
        }
        let newClusters = buckets.map { key, items in
            let lat = items.compactMap(\.latitude).reduce(0, +) / Double(items.count)
            let lon = items.compactMap(\.longitude).reduce(0, +) / Double(items.count)
            return Cluster(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           photos: items.sorted { $0.date > $1.date })
        }
        .sorted { $0.id < $1.id }
        // Only touch the map if the clusters actually changed.
        let signature = { (c: [Cluster]) in c.map { "\($0.id):\($0.photos.count)" } }
        guard signature(newClusters) != signature(clusters) else { return }
        clusters = newClusters
        if let s = selectedCluster, !clusters.contains(where: { $0.id == s.id }) { selectedCluster = nil }
    }
}

private struct ClusterPin: View {
    let cluster: PhotoMapView.Cluster
    let rotation: Int
    let selected: Bool

    var body: some View {
        ThumbnailView(url: cluster.photos[0].url, rotation: rotation)
            .frame(width: 48, height: 48)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .white, lineWidth: 3))
            .shadow(radius: 3)
            .overlay(alignment: .topTrailing) {
                if cluster.photos.count > 1 {
                    Text(cluster.photos.count.formatted())
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
    }
}
