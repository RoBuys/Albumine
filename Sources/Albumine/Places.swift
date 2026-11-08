import CoreLocation
import Foundation

/// Place name of an area (about 2 km).
struct Place: Codable, Hashable {
    var locality: String?   // town or village
    var area: String?       // county / region
    var country: String?

    /// "Avoriaz, France"
    var label: String {
        [locality ?? area, country].compactMap { $0 }.joined(separator: ", ")
    }

    var searchText: String {
        [locality, area, country].compactMap { $0 }.joined(separator: " ").searchFolded
    }
}

/// Turns GPS coordinates into place names (Apple reverse geocoding),
/// one area at a time to respect the service limits. Results in places.json.
enum PlaceStore {
    static let url = AppPaths.support.appendingPathComponent("places.json")
    /// Area size: 1/50 of a degree ≈ 2 km.
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
        case nothing          // no place (ocean…)
        case retryLater       // service rate limit or network unavailable
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
