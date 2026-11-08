import AVFoundation
import Foundation
import ImageIO

/// What is left to copy for the backup to be up to date.
struct BackupPlan {
    struct File {
        let source: URL
        let destination: URL
        let size: Int64
    }
    var files: [File]
    var totalBytes: Int64
    /// Files already present and up to date in the backup.
    var upToDate: Int
}

/// Incremental backup to a folder (ideally on another drive):
/// `destination/<watched folder name>/<relative path>`. Nothing is ever deleted from the backup.
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
            // Up to date: same size and not older than the original (the copy keeps the original date).
            if let attrs = try? fm.attributesOfItem(atPath: dest.path),
               (attrs[.size] as? NSNumber)?.int64Value == size {
                // Read directly (URLs cache their old resource values).
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

    /// Copies a file (through a temporary file: never a half-written copy).
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

    /// Also copies Albumine's data (ratings, people, albums, analyses) into the backup.
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

/// Integrity check: empty, unreadable or truncated JPEG, undecodable image or video.
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
            // A JPEG ends with FF D9 (data may follow it, so we search near the end).
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
            // Only formats macOS can read are checkable (not AVI/WMV…).
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
