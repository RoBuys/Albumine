import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Limits concurrent decodes (an external hard drive collapses otherwise).
/// Pending requests are served newest first:
/// while scrolling, what is on screen comes first.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    var isIdle: Bool { running == 0 && waiters.isEmpty }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeLast().resume() // the slot goes straight to the next waiter
        }
    }
}

/// Thumbnails: memory cache → disk cache (~/Library/Caches/Albumine) → decoding the original.
enum ImageLoader {
    static let thumbnailPixels = 512
    static let viewerPixels = 3200
    static let limiter = AsyncLimiter(limit: 6)

    /// Waits until no thumbnail is loading, for at most `maxSeconds` (never forever).
    static func waitUntilIdle(maxSeconds: Double) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        while !(await limiter.isIdle), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private static let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4000
        return c
    }()

    private static func key(_ url: URL, _ maxPixel: Int, _ rotation: Int, _ edits: PhotoEdits?) -> NSString {
        "\(maxPixel)|\(rotation)|\(edits?.cacheKey ?? "")|\(url.path)" as NSString
    }

    static func cached(_ url: URL, maxPixel: Int, rotation: Int = 0, edits: PhotoEdits? = nil) -> NSImage? {
        memory.object(forKey: key(url, maxPixel, rotation, edits))
    }

    /// - Parameters:
    /// - rotation: clockwise quarter turns applied for display (Picasa / user rotations).
    /// - urgent: skips the queue (viewer).
    static func load(_ url: URL, maxPixel: Int, rotation: Int = 0, edits: PhotoEdits? = nil,
                     cropping: Bool = true, urgent: Bool = false) async -> NSImage? {
        let edits = (edits?.isIdentity ?? true) ? nil : edits
        if cropping, let hit = cached(url, maxPixel: maxPixel, rotation: rotation, edits: edits) { return hit }
        if !urgent {
            await limiter.acquire()
            // The cell may have scrolled off screen while waiting.
            if Task.isCancelled {
                await limiter.release()
                return nil
            }
        }
        let useDiskCache = maxPixel == thumbnailPixels
        // Time limit: a decoder that never returns must not keep a decoding slot forever.
        let decoded: NSImage?? = await Watchdog.withTimeout(urgent ? 60 : 25, qos: .userInitiated) { () -> NSImage? in
            let cacheFile = useDiskCache ? diskCacheURL(for: url) : nil
            if let cacheFile, let cg = readImage(cacheFile) {
                return nsImage(EditRenderer.render(ImageDecoding.rotate(cg, rotation), edits, cropping: cropping))
            }
            guard let cg = ImageDecoding.decode(url, maxPixel: maxPixel) else {
                Debug.log("échec du décodage : \(url.path)")
                return nil
            }
            // The disk cache keeps the unrotated image: changing the rotation does not re-read the original.
            if let cacheFile { writeJPEG(cg, to: cacheFile) }
            return nsImage(EditRenderer.render(ImageDecoding.rotate(cg, rotation), edits, cropping: cropping))
        }
        let image = decoded ?? nil
        if decoded == nil { Debug.log("miniature : délai dépassé pour \(url.path)") }
        if !urgent { await limiter.release() }
        if let image, cropping { memory.setObject(image, forKey: key(url, maxPixel, rotation, edits)) }
        return image
    }

    /// Unrotated 512 px thumbnail, from the disk cache or created (background thread).
    /// Content analysis thus fills the cache: the grid gets faster afterwards.
    static func diskThumbnail(_ url: URL) -> CGImage? {
        let cacheFile = diskCacheURL(for: url)
        if let cacheFile, let cg = readImage(cacheFile) { return cg }
        guard let cg = ImageDecoding.decode(url, maxPixel: thumbnailPixels) else { return nil }
        if let cacheFile { writeJPEG(cg, to: cacheFile) }
        return cg
    }

    private static func nsImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// File name derived from path, size and date: a modified photo gets a new thumbnail.
    /// Signatures (size, date) known to the library: cached thumbnails stay
    /// findable when the drive is disconnected, and we avoid one disk access per thumbnail.
    private static let signatures = Mutex<[String: String]>([:])

    static func registerSignatures(_ photos: [Photo]) {
        var map: [String: String] = [:]
        map.reserveCapacity(photos.count)
        for p in photos { map[p.id] = "\(p.id)|\(Int(p.fileSize))|\(p.modificationDate.timeIntervalSince1970)" }
        signatures.withLock { $0 = map }
    }

    private static func diskCacheURL(for url: URL) -> URL? {
        let signature: String
        if let known = signatures.withLock({ $0[url.path] }) {
            signature = known
        } else {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            signature = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        let hash = Insecure.MD5.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = AppPaths.thumbnails.appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(hash + ".jpg")
    }

    private static func readImage(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writeJPEG(_ image: CGImage, to file: URL) {
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

struct ThumbnailView: View {
    let url: URL
    var rotation: Int = 0
    var edits: PhotoEdits? = nil
    var maxPixel: Int = ImageLoader.thumbnailPixels
    @Etat private var image: NSImage?
    @Etat private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(systemName: PhotoScanner.videoExtensions.contains(url.pathExtension.lowercased())
                      ? "film" : "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
        }
        .task(id: "\(rotation)|\(edits?.cacheKey ?? "")|\(url.path)") {
            if let hit = ImageLoader.cached(url, maxPixel: maxPixel, rotation: rotation, edits: edits) {
                image = hit
                return
            }
            image = nil
            failed = false
            let loaded = await ImageLoader.load(url, maxPixel: maxPixel, rotation: rotation, edits: edits)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
            Debug.log("miniature \(loaded == nil ? "ÉCHEC" : "OK") : \(url.lastPathComponent)")
        }
    }
}
