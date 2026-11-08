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
    var latitude: Double?
    var longitude: Double?
    /// Orientation EXIF (1–8) du fichier.
    var orientation = 1
    let isVideo: Bool
    /// Disque débranché : la photo vient de l'index (miniature en cache seulement).
    var offline = false
    /// true quand les EXIF ont été lus (ou repris de l'index).
    var exifChecked = false
    /// Nom + dossier, normalisés pour la recherche (calculé une fois au scan).
    let searchKey: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folderName: String { (folderPath as NSString).lastPathComponent }
    /// Date de prise de vue si connue, sinon date de modification du fichier.
    var date: Date { captureDate ?? modificationDate }
    var hasLocation: Bool { latitude != nil && longitude != nil }
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
    /// La détection des visages a déjà été faite sur cette photo.
    var facesAnalyzed = false
    /// L'utilisateur a indiqué que la photo n'est pas ratée.
    var qualityOK = false
    /// Lieu ajouté à la main (photo sans GPS).
    var lat: Double?
    var lon: Double?
    /// Retouches non destructives.
    var edits: PhotoEdits?

    init() {}

    var isEmpty: Bool {
        rating == 0 && tags.isEmpty && people.isEmpty && albums.isEmpty
            && caption.isEmpty && rotation == 0 && faces.isEmpty && !facesAnalyzed && !qualityOK && lat == nil && (edits?.isIdentity ?? true)
    }

    /// Nombre d'informations saisies (sert à choisir quelle copie garder parmi des doublons).
    var richness: Int { rating + tags.count + people.count * 2 + albums.count + (caption.isEmpty ? 0 : 1) }

    var hasUnnamedFaces: Bool { faces.contains { $0.name == nil } }

    private enum CodingKeys: String, CodingKey { case rating, tags, people, albums, caption, rotation, faces, facesAnalyzed, qualityOK, lat, lon, edits }

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
        facesAnalyzed = try c.decodeIfPresent(Bool.self, forKey: .facesAnalyzed) ?? false
        qualityOK = try c.decodeIfPresent(Bool.self, forKey: .qualityOK) ?? false
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        edits = try c.decodeIfPresent(PhotoEdits.self, forKey: .edits)
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
        if facesAnalyzed { try c.encode(true, forKey: .facesAnalyzed) }
        if qualityOK { try c.encode(true, forKey: .qualityOK) }
        try c.encodeIfPresent(lat, forKey: .lat)
        try c.encodeIfPresent(lon, forKey: .lon)
        if let edits, !edits.isIdentity { try c.encode(edits, forKey: .edits) }
    }

    /// Fusion d'une copie dans la photo gardée (doublons).
    mutating func merge(_ other: PhotoMetadata) {
        rating = max(rating, other.rating)
        for t in other.tags where !tags.contains(t) { tags.append(t) }
        for p in other.people where !people.contains(p) { people.append(p) }
        for a in other.albums where !albums.contains(a) { albums.append(a) }
        if caption.isEmpty { caption = other.caption }
        if rotation == 0 { rotation = other.rotation }
        if faces.isEmpty { faces = other.faces; facesAnalyzed = facesAnalyzed || other.facesAnalyzed }
        if lat == nil { lat = other.lat; lon = other.lon }
        if edits == nil { edits = other.edits }
    }
}

struct FaceRegion: Codable, Equatable {
    var name: String?
    /// Coordonnées relatives (0–1), origine en haut à gauche, sur l'image sans rotation d'affichage.
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// Nom proposé par la reconnaissance (à confirmer).
    var suggestion: String?
    /// Distance à la personne proposée (plus petit = plus sûr).
    var score: Double?
    /// true : coordonnées Picasa, exprimées dans l'image brute (avant orientation EXIF).
    var raw: Bool?

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

enum FaceGeometry {
    /// Rectangle de l'image brute → image affichée selon l'orientation EXIF (1–8).
    static func applyOrientation(_ r: CGRect, _ orientation: Int) -> CGRect {
        switch orientation {
        case 2: return CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)       // miroir horizontal
        case 3: return rotate(r, by: 2)
        case 4: return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)       // miroir vertical
        case 5: return CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)           // transposition
        case 6: return rotate(r, by: 1)
        case 7: return CGRect(x: 1 - r.maxY, y: 1 - r.maxX, width: r.height, height: r.width)   // transversale
        case 8: return rotate(r, by: 3)
        default: return r
        }
    }

    /// Rectangle relatif après `quarterTurns` quarts de tour horaires de l'image.
    static func rotate(_ r: CGRect, by quarterTurns: Int) -> CGRect {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case 2: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        case 3: return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        default: return r
        }
    }
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
    case unnamedFaces
    case videos
    case duplicates
    case map
    case similar
    case rejects
    case place(String)
    case memories
}

enum PhotoGrouping: String, CaseIterable, Identifiable {
    case none = "Sans regroupement"
    case folder = "Par dossier"
    case month = "Par mois"
    case year = "Par année"
    case event = "Par événement"
    var id: String { rawValue }
}

/// Section de la grille : une plage contiguë de la liste affichée.
struct PhotoGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let range: Range<Int>
    var folderPath: String?
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

    struct Quick {
        var date: Date?
        var camera: String?
        var latitude: Double?
        var longitude: Double?
        var orientation = 1
    }

    static func quick(_ props: [String: Any]?) -> Quick {
        guard let props else { return Quick() }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime as String] as? String)
        let date = dateString.flatMap { exifDateFormatter.date(from: $0) }
        let gps = gpsCoordinates(props[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        return Quick(date: date, camera: cameraName(tiff), latitude: gps?.0, longitude: gps?.1,
                     orientation: props[kCGImagePropertyOrientation as String] as? Int ?? 1)
    }

    static func gpsCoordinates(_ gps: [String: Any]?) -> (Double, Double)? {
        guard var lat = gps?[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps?[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        if (gps?[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
        if (gps?[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
        // (0,0) = GPS non renseigné sur certains appareils
        guard abs(lat) > 0.0001 || abs(lon) > 0.0001, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
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

        if let (lat, lon) = gpsCoordinates(gps) {
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
    /// Fichiers XMP rencontrés (sidecars d'autres logiciels ou d'Albumine).
    var sidecars: [String] = []
}

enum PhotoScanner {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "srw", "pef",
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "3gp", "avi", "mts", "m2ts", "mpg", "mpeg", "wmv", "mkv",
    ]
    static let allExtensions = extensions.union(videoExtensions)

    /// Phase 1, rapide : liste les fichiers (sans les ouvrir). Les EXIF déjà connus
    /// sont repris de l'index si le fichier n'a pas changé.
    static func scan(_ roots: [URL], index: [String: IndexStore.Entry]) -> ScanResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var photos: [Photo] = []
        var pending: [Int] = []
        var sidecars: [String] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if ext == "xmp" { sidecars.append(url.path); continue }
                guard allExtensions.contains(ext),
                      let values = try? url.resourceValues(forKeys: keySet),
                      values.isRegularFile == true,
                      seen.insert(url.path).inserted
                else { continue }
                let folder = url.deletingLastPathComponent().path
                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate ?? .distantPast
                var photo = Photo(
                    url: url, folderPath: folder, fileSize: size, modificationDate: mtime,
                    captureDate: nil, camera: nil, isVideo: videoExtensions.contains(ext),
                    searchKey: (url.lastPathComponent + " " + (folder as NSString).lastPathComponent).searchFolded
                )
                if let e = index[url.path], e.v == IndexStore.version, e.s == size, abs(e.m - mtime.timeIntervalSince1970) < 1 {
                    photo.captureDate = e.d.map { Date(timeIntervalSince1970: $0) }
                    photo.camera = e.c
                    photo.orientation = e.o ?? 1
                    photo.latitude = e.la
                    photo.longitude = e.lo
                    photo.exifChecked = true
                } else {
                    pending.append(photos.count)
                }
                photos.append(photo)
            }
        }
        return ScanResult(photos: photos, pending: pending, sidecars: sidecars)
    }

    /// Photos d'un disque débranché, reconstituées depuis l'index.
    static func offlinePhotos(under root: URL, index: [String: IndexStore.Entry]) -> [Photo] {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return index.compactMap { path, e -> Photo? in
            guard path.hasPrefix(prefix) else { return nil }
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let folder = url.deletingLastPathComponent().path
            var p = Photo(url: url, folderPath: folder, fileSize: e.s, modificationDate: Date(timeIntervalSince1970: e.m),
                          captureDate: e.d.map { Date(timeIntervalSince1970: $0) }, camera: e.c,
                          isVideo: videoExtensions.contains(ext),
                          searchKey: (url.lastPathComponent + " " + (folder as NSString).lastPathComponent).searchFolded)
            p.latitude = e.la
            p.longitude = e.lo
            p.orientation = e.o ?? 1
            p.exifChecked = true
            p.offline = true
            return p
        }
    }

    /// Phase 2, lente : lit la date de prise de vue et l'appareil, en parallèle.
    static func readExif(_ urls: [URL]) -> [ExifReader.Quick] {
        var out = [ExifReader.Quick](repeating: ExifReader.Quick(), count: urls.count)
        out.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                let url = urls[i]
                buffer[i] = videoExtensions.contains(url.pathExtension.lowercased())
                    ? VideoSupport.metadata(of: url)
                    : ExifReader.quick(ExifReader.properties(of: url))
            }
        }
        return out
    }
}

/// Index persistant (chemin → taille, date de modif., EXIF) pour démarrer instantanément.
enum IndexStore {
    /// Incrémenté quand on lit de nouvelles informations : les entrées plus anciennes sont relues.
    static let version = 2

    struct Entry: Codable {
        var s: Int64      // taille
        var m: Double     // date de modification
        var d: Double?    // date de prise de vue
        var c: String?    // appareil
        var la: Double?   // latitude
        var lo: Double?   // longitude
        var o: Int?       // orientation EXIF
        var v: Int?       // version
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
                                d: p.captureDate?.timeIntervalSince1970, c: p.camera,
                                la: p.latitude, lo: p.longitude, o: p.orientation == 1 ? nil : p.orientation, v: version)
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
