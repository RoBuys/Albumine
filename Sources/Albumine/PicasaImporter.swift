import Foundation

/// Reads the `.picasa.ini` / `Picasa.ini` files Picasa left in each folder.
///
/// Format (INI):
/// ```
/// [IMG_0107.JPG]
/// star=yes
/// rotate=rotate(1)                       ← clockwise quarter turns
/// caption=By the lake
/// albums=ca5106…,516e50…                 ← album identifiers
/// faces=rect64(2eea21abc6bfca71),cabe15…;rect64(…),…   ← region + person identifier
/// [.album:ca5106…]
/// name=Holidays 2009
/// [Contacts2]
/// cabe1597b2a421f6=First Last;email;     ← person identifier → name
/// ```
enum PicasaImporter {
    static let fileNames = [".picasa.ini", "Picasa.ini", "picasa.ini"]
    /// Picasa identifier of a face that was detected but never named.
    static let unknownFace = "ffffffffffffffff"
    /// Picasa stores faces in the raw image (before EXIF orientation) — see FaceGeometry.
    static let rawCoordinates: Bool? = true

    struct Face {
        var contact: String
        var x, y, w, h: Double
    }

    struct Entry {
        var star = false
        var rotation = 0
        var caption: String?
        var albumIDs: [String] = []
        var faces: [Face] = []
        var edits: PhotoEdits?
    }

    struct FolderFile {
        var folder: String
        var entries: [String: Entry] = [:]   // file name → data
        var albums: [String: String] = [:]   // identifier → album name
        var contacts: [String: String] = [:] // identifier → person name
    }

    /// Data ready to be merged for one photo (full path).
    struct Imported {
        var star = false
        var rotation = 0
        var caption: String?
        var people: [String] = []
        var albums: [String] = []
        var faces: [FaceRegion] = []
        var edits: PhotoEdits?
    }

    /// Picasa files present in these folders.
    static func iniFiles(in folders: [String]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for folder in Set(folders) {
            for name in fileNames {
                let path = (folder as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: path) {
                    result.append(URL(fileURLWithPath: path))
                    break
                }
            }
        }
        return result
    }

    /// Reads all files, then resolves person and album names
    /// (a person may be defined in another folder's file).
    static func load(_ files: [URL]) -> [String: Imported] {
        let parsed = files.compactMap(parse)
        var contacts: [String: String] = [:]
        var albumNames: [String: String] = [:]
        for f in parsed {
            contacts.merge(f.contacts) { old, _ in old }
            albumNames.merge(f.albums) { old, _ in old }
        }

        var result: [String: Imported] = [:]
        for f in parsed {
            for (fileName, e) in f.entries {
                var imp = Imported(star: e.star, rotation: e.rotation, caption: e.caption)
                imp.edits = e.edits
                imp.albums = e.albumIDs.compactMap { albumNames[$0] }
                for face in e.faces where face.contact != unknownFace {
                    let name = contacts[face.contact]
                    if let name, !imp.people.contains(name) { imp.people.append(name) }
                    imp.faces.append(FaceRegion(name: name, x: face.x, y: face.y, w: face.w, h: face.h, raw: rawCoordinates))
                }
                // Faces never named: keep the region, without a name.
                for face in e.faces where face.contact == unknownFace {
                    imp.faces.append(FaceRegion(name: nil, x: face.x, y: face.y, w: face.w, h: face.h, raw: rawCoordinates))
                }
                let path = (f.folder as NSString).appendingPathComponent(fileName)
                result[path] = imp
            }
        }
        return result
    }

    static func parse(_ url: URL) -> FolderFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Recent files are UTF-8; older ones Windows-1252.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        var file = FolderFile(folder: url.deletingLastPathComponent().path)
        var section = ""
        var entry: Entry?

        func flush() {
            if let e = entry, !section.isEmpty { file.entries[section] = e }
            entry = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                section = String(line.dropFirst().dropLast())
                let isSpecial = section == "Picasa" || section == "Contacts" || section == "Contacts2"
                    || section == "encoding" || section.hasPrefix(".album:")
                entry = isSpecial ? nil : Entry()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])

            if section == "Contacts2" {
                // "First Last;email;…" → keep the name.
                let name = value.split(separator: ";", omittingEmptySubsequences: false).first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !name.isEmpty { file.contacts[key] = name }
            } else if section.hasPrefix(".album:") {
                if key == "name", !value.isEmpty { file.albums[String(section.dropFirst(7))] = value }
            } else if entry != nil {
                switch key {
                case "star": entry!.star = value == "yes"
                case "rotate": entry!.rotation = parseRotation(value)
                case "caption": if !value.isEmpty { entry!.caption = value }
                case "albums": entry!.albumIDs = value.split(separator: ",").map(String.init)
                case "faces": entry!.faces = parseFaces(value)
                case "filters": entry!.edits = parseFilters(value)
                default: break
                }
            }
        }
        flush()
        return file
    }

    /// "enhance=1;bw=1;" → equivalent edits (other Picasa filters are ignored).
    static func parseFilters(_ value: String) -> PhotoEdits? {
        var e = PhotoEdits()
        for part in value.split(separator: ";") {
            let name = part.split(separator: "=").first.map(String.init) ?? ""
            switch name {
            case "enhance", "autolight", "autocolor": e.auto = true
            case "bw": e.filter = .blackWhite
            case "sepia": e.filter = .sepia
            case "warm": e.warmth = 0.4
            case "saturate": e.saturation = 0.4
            case "fill": e.shadows = 0.4
            default: break
            }
        }
        return e.isIdentity ? nil : e
    }

    /// "rotate(3)" → 3
    static func parseRotation(_ value: String) -> Int {
        let digits = value.filter(\.isNumber)
        return (Int(digits) ?? 0) % 4
    }

    /// "rect64(2eea21abc6bfca71),cabe1597b2a421f6;rect64(…),…"
    static func parseFaces(_ value: String) -> [Face] {
        value.split(separator: ";").compactMap { part in
            let pieces = part.split(separator: ",")
            guard pieces.count == 2,
                  pieces[0].hasPrefix("rect64("), pieces[0].hasSuffix(")") else { return nil }
            let hex = pieces[0].dropFirst(7).dropLast()
            guard let rect = parseRect64(String(hex)) else { return nil }
            return Face(contact: String(pieces[1]), x: rect.x, y: rect.y, w: rect.w, h: rect.h)
        }
    }

    /// 64 bits = left, top, right, bottom on 16 bits each (fraction of 65535).
    /// Picasa drops leading zeros, hence the padding to 16 characters.
    static func parseRect64(_ hex: String) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard hex.count <= 16, let v = UInt64(String(repeating: "0", count: 16 - hex.count) + hex, radix: 16)
        else { return nil }
        let f = { (shift: UInt64) in Double((v >> shift) & 0xFFFF) / 65535 }
        let left = f(48), top = f(32), right = f(16), bottom = f(0)
        guard right > left, bottom > top else { return nil }
        return (left, top, right - left, bottom - top)
    }
}

/// Summary shown at the end of the import.
struct PicasaImportSummary: Identifiable {
    let id = UUID()
    var files = 0
    var photos = 0
    var stars = 0
    var rotations = 0
    var captions = 0
    var edits = 0
    var namedFaces = 0
    var people = Set<String>()
    var albums = Set<String>()

    var message: String {
        guard photos > 0 else {
            return files == 0
                ? "Aucun fichier Picasa (.picasa.ini) n'a été trouvé dans vos dossiers."
                : "\(files) fichiers Picasa lus, mais aucune photo correspondante dans la bibliothèque."
        }
        var lines = ["\(files.formatted()) fichiers Picasa lus, \(photos.formatted()) photos enrichies :"]
        if namedFaces > 0 { lines.append("• \(namedFaces.formatted()) visages nommés (\(people.count) personnes)") }
        if !albums.isEmpty { lines.append("• \(albums.count) albums") }
        if rotations > 0 { lines.append("• \(rotations.formatted()) rotations") }
        if stars > 0 { lines.append("• \(stars) photos étoilées (→ 5 étoiles)") }
        if captions > 0 { lines.append("• \(captions) légendes") }
        if edits > 0 { lines.append("• \(edits) retouches (correction auto, noir et blanc, sépia…)") }
        lines.append("\nVos fichiers n'ont pas été modifiés.")
        return lines.joined(separator: "\n")
    }
}
