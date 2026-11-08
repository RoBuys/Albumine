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
