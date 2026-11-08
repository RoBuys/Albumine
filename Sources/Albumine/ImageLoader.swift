import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Limite le nombre de décodages simultanés (un disque dur externe s'effondre sinon).
/// Les demandes en attente sont servies de la plus récente à la plus ancienne :
/// quand on fait défiler, ce qui est à l'écran passe en premier.
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
            waiters.removeLast().resume() // le créneau passe directement au suivant
        }
    }
}

/// Miniatures : cache mémoire → cache disque (~/Library/Caches/Albumine) → décodage de l'original.
enum ImageLoader {
    static let thumbnailPixels = 512
    static let viewerPixels = 3200
    static let limiter = AsyncLimiter(limit: 6)

    private static let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4000
        return c
    }()

    private static func key(_ url: URL, _ maxPixel: Int, _ rotation: Int) -> NSString {
        "\(maxPixel)|\(rotation)|\(url.path)" as NSString
    }

    static func cached(_ url: URL, maxPixel: Int, rotation: Int = 0) -> NSImage? {
        memory.object(forKey: key(url, maxPixel, rotation))
    }

    /// - Parameters:
    ///   - rotation: quarts de tour horaires appliqués à l'affichage (rotations Picasa / utilisateur).
    ///   - urgent: ignore la file d'attente (visionneuse).
    static func load(_ url: URL, maxPixel: Int, rotation: Int = 0, urgent: Bool = false) async -> NSImage? {
        if let hit = cached(url, maxPixel: maxPixel, rotation: rotation) { return hit }
        if !urgent {
            await limiter.acquire()
            // La cellule a pu disparaître de l'écran pendant l'attente.
            if Task.isCancelled {
                await limiter.release()
                return nil
            }
        }
        let useDiskCache = maxPixel == thumbnailPixels
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let cacheFile = useDiskCache ? diskCacheURL(for: url) : nil
            if let cacheFile, let cg = readImage(cacheFile) { return nsImage(ImageDecoding.rotate(cg, rotation)) }
            guard let cg = ImageDecoding.decode(url, maxPixel: maxPixel) else {
                Debug.log("échec du décodage : \(url.path)")
                return nil
            }
            // Le cache disque garde l'image non pivotée : changer la rotation ne relit pas l'original.
            if let cacheFile { writeJPEG(cg, to: cacheFile) }
            return nsImage(ImageDecoding.rotate(cg, rotation))
        }.value
        if !urgent { await limiter.release() }
        if let image { memory.setObject(image, forKey: key(url, maxPixel, rotation)) }
        return image
    }

    private static func nsImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Nom de fichier dérivé du chemin, de la taille et de la date : une photo modifiée est régénérée.
    private static func diskCacheURL(for url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
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
        .task(id: "\(rotation)|\(url.path)") {
            if let hit = ImageLoader.cached(url, maxPixel: maxPixel, rotation: rotation) {
                image = hit
                return
            }
            image = nil
            failed = false
            let loaded = await ImageLoader.load(url, maxPixel: maxPixel, rotation: rotation)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
            Debug.log("miniature \(loaded == nil ? "ÉCHEC" : "OK") : \(url.lastPathComponent)")
        }
    }
}
