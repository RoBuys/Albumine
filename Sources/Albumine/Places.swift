import CoreLocation
import Foundation

/// Nom de lieu d'une zone (environ 2 km).
struct Place: Codable, Hashable {
    var locality: String?   // ville ou village
    var area: String?       // département / région
    var country: String?

    /// « Avoriaz, France »
    var label: String {
        [locality ?? area, country].compactMap { $0 }.joined(separator: ", ")
    }

    var searchText: String {
        [locality, area, country].compactMap { $0 }.joined(separator: " ").searchFolded
    }
}

/// Traduit les coordonnées GPS en noms de lieux (géocodage inverse d'Apple),
/// une zone à la fois pour respecter les limites du service. Résultats dans places.json.
enum PlaceStore {
    static let url = AppPaths.support.appendingPathComponent("places.json")
    /// Taille d'une zone : 1/50 de degré ≈ 2 km.
    static let cellsPerDegree = 50.0

    static func cell(_ lat: Double, _ lon: Double) -> String {
        "\(Int((lat * cellsPerDegree).rounded()))|\(Int((lon * cellsPerDegree).rounded()))"
    }

    static func center(of cell: String) -> CLLocation? {
        let parts = cell.split(separator: "|").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CLLocation(latitude: parts[0] / cellsPerDegree, longitude: parts[1] / cellsPerDegree)
    }

    static func load() -> [String: Place] {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode([String: Place].self, from: data) else { return [:] }
        return store
    }

    static func save(_ store: [String: Place]) {
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: url, options: .atomic) }
    }

    enum Outcome {
        case found(Place)
        case nothing          // pas de lieu (océan…)
        case retryLater       // limite du service ou réseau indisponible
    }

    static func lookup(_ cell: String) async -> Outcome {
        guard let location = center(of: cell) else { return .nothing }
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "fr_FR"))
            guard let m = marks.first else { return .nothing }
            return .found(Place(locality: m.locality ?? m.subAdministrativeArea,
                                area: m.administrativeArea, country: m.country))
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return .nothing
        } catch {
            return .retryLater
        }
    }
}
