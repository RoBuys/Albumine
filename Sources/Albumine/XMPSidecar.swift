import Foundation
import ImageIO

/// Fichiers XMP « à côté » des photos (sidecars), lus et écrits par Lightroom, digiKam, Mylio…
///
/// Écriture : on **fusionne** dans le fichier existant (les données des autres logiciels sont
/// conservées) et on ne touche qu'aux champs gérés par Albumine. Nouveau fichier : `photo.JPG.xmp`
/// (pas d'ambiguïté si `photo.JPG` et `photo.MOV` coexistent).
enum XMPSidecar {
    static let albumineNS = "https://github.com/RoBuys/Albumine/ns/1.0/"
    static let iptcExtNS = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"

    struct Content: Equatable {
        var rating = 0
        var tags: [String] = []
        var people: [String] = []
        var caption = ""
        var latitude: Double?
        var longitude: Double?
        /// Date de prise de vue corrigée dans Albumine.
        var date: Date?
        /// Zones nommées (lecture seulement : MWG Regions, centre + taille).
        var regions: [FaceRegion] = []
    }

    /// Sidecar existant : `photo.JPG.xmp`, sinon `photo.xmp` s'il n'existe qu'un fichier de ce nom.
    static func existing(for url: URL) -> URL? {
        let fm = FileManager.default
        let full = url.appendingPathExtension("xmp")
        if fm.fileExists(atPath: full.path) { return full }
        let base = url.deletingPathExtension().appendingPathExtension("xmp")
        guard fm.fileExists(atPath: base.path) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let siblings = (try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        let media = siblings.filter {
            ($0 as NSString).deletingPathExtension == stem
                && PhotoScanner.allExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        return media.count <= 1 ? base : nil
    }

    // MARK: Lecture (Mylio, Lightroom, digiKam…)

    static func read(_ sidecar: URL) -> Content? {
        guard let data = try? Data(contentsOf: sidecar),
              let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        var c = Content()
        if let r = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?, let v = Int(r) {
            c.rating = max(0, min(5, v))
        }
        c.tags = strings(meta, "dc:subject")
        c.people = strings(meta, "Iptc4xmpExt:PersonInImage")
        if let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:description" as CFString),
           let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag],
           let first = values.first, let s = CGImageMetadataTagCopyValue(first) as? String {
            c.caption = s
        } else if let s = CGImageMetadataCopyStringValueWithPath(meta, nil, "dc:description" as CFString) as String? {
            c.caption = s
        }
        if let lat = CGImageMetadataCopyStringValueWithPath(meta, nil, "exif:GPSLatitude" as CFString) as String?,
           let lon = CGImageMetadataCopyStringValueWithPath(meta, nil, "exif:GPSLongitude" as CFString) as String? {
            c.latitude = parseCoordinate(lat)
            c.longitude = parseCoordinate(lon)
        }
        c.regions = regions(in: String(decoding: data, as: UTF8.self))
        for r in c.regions { if let n = r.name, !c.people.contains(n) { c.people.append(n) } }
        // Albumine écrit aussi les personnes dans les mots-clés : on ne les compte pas comme étiquettes.
        c.tags.removeAll { c.people.contains($0) }
        return c
    }

    private static func strings(_ meta: CGImageMetadata, _ path: String) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }.filter { !$0.isEmpty }
    }

    /// « 45,52.4172N » (format XMP) → 45.8736 ; « -12.5 » accepté aussi.
    static func parseCoordinate(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return nil }
        let sign: Double = (last == "S" || last == "W") ? -1 : 1
        let body = "NSEW".contains(last) ? String(trimmed.dropLast()) : trimmed
        let parts = body.split(separator: ",").compactMap { Double($0) }
        switch parts.count {
        case 1: return sign * parts[0]
        case 2: return sign * (parts[0] + parts[1] / 60)
        case 3: return sign * (parts[0] + parts[1] / 60 + parts[2] / 3600)
        default: return nil
        }
    }

    /// Régions MWG nommées (Mylio, Lightroom, digiKam) : centre (x, y) + taille (w, h), relatives,
    /// exprimées dans l'image brute (avant orientation EXIF, vérifié sur une photothèque Mylio).
    /// Gère les deux écritures XML : attributs (`mwg-rs:Name="…"`) et éléments (`<mwg-rs:Name>…</…>`).
    static func regions(in xml: String) -> [FaceRegion] {
        guard let list = xml.range(of: "mwg-rs:RegionList") else { return [] }
        var out: [FaceRegion] = []
        for chunk in xml[list.upperBound...].components(separatedBy: "<rdf:li").dropFirst() {
            guard let name = field("mwg-rs:Name", in: chunk).map(xmlUnescape), !name.isEmpty else { continue }
            let num = { (k: String) in field("stArea:\(k)", in: chunk).flatMap(Double.init) }
            if let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h"), w > 0, h > 0 {
                out.append(FaceRegion(name: name, x: x - w / 2, y: y - h / 2, w: w, h: h, raw: true))
            } else {
                out.append(FaceRegion(name: name, x: 0, y: 0, w: 0, h: 0))
            }
        }
        return out
    }

    private static func field(_ key: String, in text: String) -> String? {
        let k = NSRegularExpression.escapedPattern(for: key)
        guard let re = try? NSRegularExpression(pattern: "\(k)=\"([^\"]*)\"|<\(k)>([^<]*)</\(k)>"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for i in 1...2 {
            if let r = Range(m.range(at: i), in: text) { return String(text[r]) }
        }
        return nil
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: Écriture (fusion)

    enum WriteResult { case written, unchanged }

    /// Écrit (ou met à jour) le sidecar d'une photo. Les champs vides ne sont retirés
    /// que si Albumine les avait écrits lui-même.
    @discardableResult
    static func write(_ c: Content, for url: URL) throws -> WriteResult {
        let target = existing(for: url) ?? url.appendingPathExtension("xmp")
        let oldData = try? Data(contentsOf: target)
        let base = oldData.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
        guard let meta = base.flatMap({ CGImageMetadataCreateMutableCopy($0) }) ?? CGImageMetadataCreateMutable() as CGMutableImageMetadata? else {
            throw CocoaError(.fileWriteUnknown)
        }
        let ours = oldData == nil || CGImageMetadataCopyStringValueWithPath(meta, nil, "albumine:version" as CFString) != nil
        CGImageMetadataRegisterNamespaceForPrefix(meta, albumineNS as CFString, "albumine" as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(meta, iptcExtNS as CFString, "Iptc4xmpExt" as CFString, nil)

        func setOrClear(_ path: String, _ hasValue: Bool, _ set: () -> Void) {
            if hasValue { set() } else if ours { CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) }
        }
        setOrClear("xmp:Rating", c.rating > 0) {
            CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, c.rating as CFNumber)
        }
        let keywords = c.tags + c.people
        setOrClear("dc:subject", !keywords.isEmpty) {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, keywords as CFArray)
        }
        setOrClear("Iptc4xmpExt:PersonInImage", !c.people.isEmpty) {
            if let tag = CGImageMetadataTagCreate(iptcExtNS as CFString, "Iptc4xmpExt" as CFString, "PersonInImage" as CFString,
                                                  .arrayUnordered, c.people as CFArray) {
                CGImageMetadataSetTagWithPath(meta, nil, "Iptc4xmpExt:PersonInImage" as CFString, tag)
            }
        }
        setOrClear("dc:description", !c.caption.isEmpty) {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, c.caption as CFString)
        }
        if let lat = c.latitude, let lon = c.longitude {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(lat) as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (lat < 0 ? "S" : "N") as CFString)
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(lon) as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (lon < 0 ? "W" : "E") as CFString)
        }
        if let date = c.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyExifDictionary,
                                                         kCGImagePropertyExifDateTimeOriginal, f.string(from: date) as CFString)
        }
        CGImageMetadataSetValueWithPath(meta, nil, "albumine:version" as CFString, "1" as CFString)

        guard let data = CGImageMetadataCreateXMPData(meta, nil) as Data? else { throw CocoaError(.fileWriteUnknown) }
        if let oldData, oldData == data { return .unchanged }
        try data.write(to: target, options: .atomic)
        return .written
    }
}
