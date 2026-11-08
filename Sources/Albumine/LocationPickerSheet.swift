import MapKit
import SwiftUI

/// Choisir le lieu de photos sans GPS : clic sur la carte ou recherche d'un lieu.
struct LocationPickerSheet: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @Etat private var pin: CLLocationCoordinate2D?
    @Etat private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.4),
        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)))
    @Etat private var query = ""
    @Etat private var results: [MKMapItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lieu de \(photos.count) élément\(photos.count > 1 ? "s" : "")").font(.title3.weight(.semibold))
            HStack {
                TextField("Rechercher un lieu (ville, adresse, monument…)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Rechercher", action: search)
            }
            if !results.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(results, id: \.self) { item in
                            Button(item.name ?? "Lieu") { choose(item.placemark.coordinate) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            MapReader { proxy in
                Map(position: $camera) {
                    if let pin { Marker("Ici", coordinate: pin) }
                }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { pin = c }
                }
            }
            .frame(minHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Cliquez sur la carte pour placer le repère. Le lieu est enregistré dans Albumine (et dans les fichiers XMP si l'option est activée) ; les photos ne sont pas modifiées.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Utiliser ce lieu") {
                    if let pin { library.setLocation(photos, latitude: pin.latitude, longitude: pin.longitude) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pin == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .onAppear {
            // Point de départ : une photo voisine dans le temps déjà localisée, sinon la France.
            if let p = photos.first(where: \.hasLocation), let la = p.latitude, let lo = p.longitude {
                choose(CLLocationCoordinate2D(latitude: la, longitude: lo))
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        Task {
            let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            results = Array(items.prefix(6))
            if let first = items.first { choose(first.placemark.coordinate) }
        }
    }

    private func choose(_ c: CLLocationCoordinate2D) {
        pin = c
        camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
    }
}
