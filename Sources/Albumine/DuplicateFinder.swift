import CryptoKit
import Foundation

/// Recherche des doublons exacts : même taille, puis même empreinte du début et de la fin du fichier.
/// Avant toute mise à la corbeille, les fichiers sont comparés octet par octet.
enum DuplicateFinder {
    static let chunk = 64 * 1024

    /// Empreinte rapide : taille + SHA-256 des 64 premiers et 64 derniers Ko.
    static func quickHash(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return "\(size)-" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Candidats : fichiers de même taille (les seuls qui peuvent être identiques).
    static func sameSizeCandidates(_ photos: [Photo]) -> [Photo] {
        Dictionary(grouping: photos.filter { $0.fileSize > 0 }, by: \.fileSize)
            .values.filter { $0.count > 1 }.flatMap { $0 }
    }

    static func hashes(_ items: [(id: String, url: URL, size: Int64)]) -> [(id: String, hash: String?)] {
        var out = [(id: String, hash: String?)](repeating: ("", nil), count: items.count)
        out.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                buffer[i] = (items[i].id, quickHash(items[i].url, size: items[i].size))
            }
        }
        return out
    }

    static func identical(_ a: URL, _ b: URL) -> Bool {
        FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }
}
