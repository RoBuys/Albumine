import CryptoKit
import Foundation

/// Exact duplicate search: same size, then same fingerprint of the file's start and end.
/// Before anything is moved to the Trash, files are compared byte by byte.
enum DuplicateFinder {
    static let chunk = 64 * 1024

    /// Quick fingerprint: size + SHA-256 of the first and last 64 KB.
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

    /// Candidates: files of the same size (the only ones that can be identical).
    static func sameSizeCandidates(_ photos: [Photo]) -> [Photo] {
        Dictionary(grouping: photos.filter { $0.fileSize > 0 }, by: \.fileSize)
            .values.filter { $0.count > 1 }.flatMap { $0 }
    }

    static func identical(_ a: URL, _ b: URL) -> Bool {
        FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }
}

/// Fingerprints already computed, keyed by path and valid while size and modification date are
/// unchanged: a new search only reads files that are new or modified (essential on a large drive).
struct DuplicateHashCache: Codable {
    struct Entry: Codable { let s: Int64; let m: Double; let h: String }
    var entries: [String: Entry] = [:]

    static var url: URL { AppPaths.support.appendingPathComponent("duplicate-hashes.json") }

    static func load() -> DuplicateHashCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(DuplicateHashCache.self, from: data) else { return DuplicateHashCache() }
        return cache
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    func hash(path: String, size: Int64, mtime: Date) -> String? {
        guard let e = entries[path], e.s == size, abs(e.m - mtime.timeIntervalSince1970) < 1 else { return nil }
        return e.h
    }
}
