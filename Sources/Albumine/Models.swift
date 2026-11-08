import Foundation
import ImageIO

/// Une photo trouvée sur le disque. Les fichiers ne sont jamais déplacés ni modifiés.
struct Photo: Identifiable, Hashable {
    let url: URL
    let folderPath: String
    let fileSize: Int64
    let modificationDate: Date
    var captureDate: Date?
    var camera: String?
    /// true quand les EXIF ont été lus (ou repris de l'index).
    var exifChecked = false
    /// Nom + dossier, normalisés pour la recherche (calculé une fois au scan).
    let searchKey: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folderName: String { (folderPath as NSString).lastPathComponent }
    /// Date de prise de vue si connue, sinon date de modification du fichier.
    var date: Date { captureDate ?? modificationDate }
}

/// Données ajoutées par l'utilisateur (ou importées de Picasa), stockées à part : non destructif.
struct PhotoMetadata: Codable, Equatable {
    var rating = 0
    var tags: [String] = []
    var people: [String] = []
    var albums: [String] = []
    var caption = ""
    /// Rotation d'affichage, en quarts de tour dans le sens horaire (0–3).
    var rotation = 0
    /// Zones des visages (coordonnées relatives 0–1), reprises de Picasa.
    var faces: [FaceRegion] = []

    init() {}

    var isEmpty: Bool {
        rating == 0 && tags.isEmpty && people.isEmpty && albums.isEmpty
            && caption.isEmpty && rotation == 0 && faces.isEmpty
    }

    private enum CodingKeys: String, CodingKey { case rating, tags, people, albums, caption, rotation, faces }

    // Champs facultatifs : les anciens fichiers restent lisibles, les champs vides ne sont pas écrits.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        albums = try c.decodeIfPresent([String].self, forKey: .albums) ?? []
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        faces = try c.decodeIfPresent([FaceRegion].self, forKey: .faces) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if rating != 0 { try c.encode(rating, forKey: .rating) }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        if !people.isEmpty { try c.encode(people, forKey: .people) }
        if !albums.isEmpty { try c.encode(albums, forKey: .albums) }
        if !caption.isEmpty { try c.encode(caption, forKey: .caption) }
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if !faces.isEmpty { try c.encode(faces, forKey: .faces) }
    }
}

struct FaceRegion: Codable, Equatable {
    var name: String?
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct FolderSummary: Identifiable, Hashable {
    let path: String
    let name: String
    let count: Int
    let latest: Date
    var id: String { path }
}

enum SidebarItem: Hashable {
    case all
    case starred
    case folder(String)
    case tag(String)
    case person(String)
    case album(String)
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case newest = "Date (récentes d'abord)"
    case oldest = "Date (anciennes d'abord)"
    case name = "Nom"
    var id: String { rawValue }
}

/// Informations EXIF détaillées, lues à la demande pour l'inspecteur.
struct PhotoInfo {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var dateTaken: Date?
    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var exposure: Double?
    var focalLength: Double?
    var latitude: Double?
    var longitude: Double?
}

enum ExifReader {
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func properties(of url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }
        return props
    }

    static func quick(_ props: [String: Any]?) -> (date: Date?, camera: String?) {
        guard let props else { return (nil, nil) }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime as String] as? String)
        let date = dateString.flatMap { exifDateFormatter.date(from: $0) }
        return (date, cameraName(tiff))
    }

    static func info(for url: URL) -> PhotoInfo {
        var info = PhotoInfo()
        guard let props = properties(of: url) else { return info }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any]

        info.pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int
        info.pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int
        info.dateTaken = quick(props).date
        info.camera = cameraName(tiff)
        info.lens = exif?[kCGImagePropertyExifLensModel as String] as? String
        info.iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        info.aperture = exif?[kCGImagePropertyExifFNumber as String] as? Double
        info.exposure = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        info.focalLength = exif?[kCGImagePropertyExifFocalLength as String] as? Double

        if var lat = gps?[kCGImagePropertyGPSLatitude as String] as? Double,
           var lon = gps?[kCGImagePropertyGPSLongitude as String] as? Double {
            if (gps?[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
            if (gps?[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
            info.latitude = lat
            info.longitude = lon
        }
        return info
    }

    private static func cameraName(_ tiff: [String: Any]?) -> String? {
        let make = (tiff?[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces)
        switch (make, model) {
        case let (m?, mo?) where mo.lowercased().hasPrefix(m.lowercased()): return mo
        case let (m?, mo?): return "\(m) \(mo)"
        case let (nil, mo?): return mo
        case let (m?, nil): return m
        default: return nil
        }
    }
}

struct ScanResult {
    var photos: [Photo]
    /// Indices (dans `photos`) dont les EXIF restent à lire.
    var pending: [Int]
}

enum PhotoScanner {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "srw", "pef",
    ]

    /// Phase 1, rapide : liste les fichiers (sans les ouvrir). Les EXIF déjà connus
    /// sont repris de l'index si le fichier n'a pas changé.
    static func scan(_ roots: [URL], index: [String: IndexStore.Entry]) -> ScanResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var photos: [Photo] = []
        var pending: [Int] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keySet),
                      values.isRegularFile == true,
                      seen.insert(url.path).inserted
                else { continue }
                let folder = url.deletingLastPathComponent().path
                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate ?? .distantPast
                var photo = Photo(
                    url: url, folderPath: folder, fileSize: size, modificationDate: mtime,
                    captureDate: nil, camera: nil,
                    searchKey: (url.lastPathComponent + " " + (folder as NSString).lastPathComponent).searchFolded
                )
                if let e = index[url.path], e.s == size, abs(e.m - mtime.timeIntervalSince1970) < 1 {
                    photo.captureDate = e.d.map { Date(timeIntervalSince1970: $0) }
                    photo.camera = e.c
                    photo.exifChecked = true
                } else {
                    pending.append(photos.count)
                }
                photos.append(photo)
            }
        }
        return ScanResult(photos: photos, pending: pending)
    }

    /// Phase 2, lente : lit la date de prise de vue et l'appareil, en parallèle.
    static func readExif(_ urls: [URL]) -> [(date: Date?, camera: String?)] {
        var out = [(date: Date?, camera: String?)](repeating: (nil, nil), count: urls.count)
        out.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                buffer[i] = ExifReader.quick(ExifReader.properties(of: urls[i]))
            }
        }
        return out
    }
}

/// Index persistant (chemin → taille, date de modif., EXIF) pour démarrer instantanément.
enum IndexStore {
    struct Entry: Codable {
        var s: Int64      // taille
        var m: Double     // date de modification
        var d: Double?    // date de prise de vue
        var c: String?    // appareil
    }

    static let url: URL = AppPaths.support.appendingPathComponent("index.json")

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return index
    }

    static func save(_ photos: [Photo]) {
        var index: [String: Entry] = [:]
        index.reserveCapacity(photos.count)
        for p in photos where p.exifChecked {
            index[p.id] = Entry(s: p.fileSize, m: p.modificationDate.timeIntervalSince1970,
                                d: p.captureDate?.timeIntervalSince1970, c: p.camera)
        }
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: url, options: .atomic) }
    }
}

enum AppPaths {
    /// ~/Library/Application Support/Albumine (remplaçable via ALBUMINE_HOME pour les tests).
    static let support: URL = {
        let dir = ProcessInfo.processInfo.environment["ALBUMINE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Albumine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let thumbnails: URL = {
        let base = ProcessInfo.processInfo.environment["ALBUMINE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Albumine", isDirectory: true)
        let dir = base.appendingPathComponent("Miniatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["ALBUMINE_DEBUG"] != nil
    static func log(_ message: @autoclosure () -> String) {
        if enabled { FileHandle.standardError.write((message() + "\n").data(using: .utf8)!) }
    }
}

extension String {
    /// Forme normalisée pour la recherche : minuscules, sans accents.
    var searchFolded: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
