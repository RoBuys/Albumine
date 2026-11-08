import MapKit
import SwiftUI

/// Carte des photos géolocalisées. Les photos proches sont regroupées selon le niveau de zoom ;
/// un clic sur un groupe affiche ses photos en bas (double-clic : visionneuse).
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

    @Etat private var camera: MapCameraPosition = .automatic
    @Etat private var region: MKCoordinateRegion?
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
                    region = context.region
                    recluster()
                }
                .task(id: located.count) { recluster() }

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

    /// Regroupe les photos sur une grille d'environ 10 × 10 cases de la zone visible.
    private func recluster() {
        let list = located
        let span = region?.span ?? MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 300)
        let cellLat = max(span.latitudeDelta / 10, 0.0005)
        let cellLon = max(span.longitudeDelta / 10, 0.0005)
        var buckets: [String: [Photo]] = [:]
        for p in list {
            guard let lat = p.latitude, let lon = p.longitude else { continue }
            if let r = region {
                // Zone visible + une marge, pour ne pas dessiner des milliers d'épingles hors écran.
                guard abs(lat - r.center.latitude) < r.span.latitudeDelta,
                      abs(lon - r.center.longitude) < r.span.longitudeDelta else { continue }
            }
            let key = "\(Int(floor(lat / cellLat)))|\(Int(floor(lon / cellLon)))"
            buckets[key, default: []].append(p)
        }
        clusters = buckets.map { key, items in
            let lat = items.compactMap(\.latitude).reduce(0, +) / Double(items.count)
            let lon = items.compactMap(\.longitude).reduce(0, +) / Double(items.count)
            return Cluster(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           photos: items.sorted { $0.date > $1.date })
        }
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
