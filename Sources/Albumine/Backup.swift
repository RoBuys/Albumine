import AVFoundation
import Foundation
import ImageIO

/// Ce qu'il reste à copier pour que la sauvegarde soit à jour.
struct BackupPlan {
    struct File {
        let source: URL
        let destination: URL
        let size: Int64
    }
    var files: [File]
    var totalBytes: Int64
    /// Fichiers déjà présents et à jour dans la sauvegarde.
    var upToDate: Int
}

/// Sauvegarde incrémentale vers un dossier (idéalement sur un autre disque) :
/// `destination/<nom du dossier suivi>/<chemin relatif>`. Rien n'est jamais supprimé de la sauvegarde.
enum BackupEngine {
    static func plan(_ sources: [(URL, Int64)], roots: [URL], destination: URL) -> BackupPlan {
        let fm = FileManager.default
        var files: [BackupPlan.File] = []
        var total: Int64 = 0
        var upToDate = 0
        for (url, knownSize) in sources {
            guard let root = roots.first(where: { url.path.hasPrefix($0.path + "/") }) else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let dest = destination.appendingPathComponent(root.lastPathComponent).appendingPathComponent(relative)
            let size = knownSize >= 0 ? knownSize
                : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // À jour : même taille et pas plus ancienne que l'original (la copie garde la date d'origine).
            if let attrs = try? fm.attributesOfItem(atPath: dest.path),
               (attrs[.size] as? NSNumber)?.int64Value == size {
                // Lecture directe (les URL gardent en cache leurs anciennes valeurs).
                let srcDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                let dstDate = attrs[.modificationDate] as? Date ?? .distantPast
                if srcDate.timeIntervalSince(dstDate) < 2 {
                    upToDate += 1
                    continue
                }
            }
            files.append(.init(source: url, destination: dest, size: size))
            total += size
        }
        return BackupPlan(files: files, totalBytes: total, upToDate: upToDate)
    }

    /// Copie un fichier (via un fichier temporaire : jamais de copie à moitié écrite).
    static func copy(_ f: BackupPlan.File) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: f.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = f.destination.deletingLastPathComponent()
                .appendingPathComponent(".albumine-\(UUID().uuidString)-\(f.destination.lastPathComponent)")
            try fm.copyItem(at: f.source, to: temp)
            if fm.fileExists(atPath: f.destination.path) {
                _ = try fm.replaceItemAt(f.destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: f.destination)
            }
            return true
        } catch {
            Debug.log("sauvegarde : échec pour \(f.source.path) — \(error.localizedDescription)")
            return false
        }
    }

    /// Copie aussi les données d'Albumine (notes, personnes, albums, analyses) dans la sauvegarde.
    static func copyLibraryData(to destination: URL) {
        let fm = FileManager.default
        let target = destination.appendingPathComponent("Albumine (données)")
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: AppPaths.support.path)) ?? [] where name.hasSuffix(".json") || name.hasSuffix(".dat") {
            let src = AppPaths.support.appendingPathComponent(name)
            let dst = target.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }
}

/// Contrôle d'intégrité : fichier vide, illisible, JPEG tronqué, image ou vidéo indécodable.
enum IntegrityChecker {
    static func problem(_ photo: Photo) -> String? {
        let url = photo.url
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "Illisible (accès impossible)" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size == 0 { return "Fichier vide" }
        let ext = url.pathExtension.lowercased()

        if ext == "jpg" || ext == "jpeg" {
            try? handle.seek(toOffset: 0)
            let head = (try? handle.read(upToCount: 3)) ?? Data()
            if head != Data([0xFF, 0xD8, 0xFF]) { return "Pas un JPEG valide" }
            // La fin d'un JPEG est marquée par FF D9 (des données peuvent suivre : on cherche dans la fin).
            let tailSize = min(UInt64(65536), size)
            try? handle.seek(toOffset: size - tailSize)
            let tail = (try? handle.read(upToCount: Int(tailSize))) ?? Data()
            let hasEnd = tail.withUnsafeBytes { raw -> Bool in
                let b = raw.bindMemory(to: UInt8.self)
                guard b.count >= 2 else { return false }
                for i in stride(from: b.count - 2, through: 0, by: -1) where b[i] == 0xFF && b[i + 1] == 0xD9 { return true }
                return false
            }
            return hasEnd ? nil : "Fichier tronqué (fin manquante)"
        }

        if PhotoScanner.videoExtensions.contains(ext) {
            // Seuls les formats lus par macOS sont vérifiables (pas AVI/WMV…).
            guard ["mov", "mp4", "m4v", "3gp"].contains(ext) else { return nil }
            return AVURLAsset(url: url).tracks.isEmpty ? "Vidéo illisible" : nil
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "Format illisible" }
        if CGImageSourceGetCount(source) == 0 { return "Format illisible" }
        let status = CGImageSourceGetStatus(source)
        if status != .statusComplete { return status == .statusIncomplete ? "Fichier tronqué" : "Format illisible" }
        return nil
    }
}
