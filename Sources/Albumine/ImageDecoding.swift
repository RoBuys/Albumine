import CoreGraphics
import Foundation
import ImageIO

/// Décodage d'images et de vidéos (sans interface) : utilisé par les miniatures et l'analyse des visages.
enum ImageDecoding {
    static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        if PhotoScanner.videoExtensions.contains(url.pathExtension.lowercased()) {
            return VideoSupport.frame(of: url, maxPixel: maxPixel)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // respecte l'orientation EXIF
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pivote de `quarterTurns` quarts de tour dans le sens horaire.
    static func rotate(_ image: CGImage, _ quarterTurns: Int) -> CGImage {
        let q = ((quarterTurns % 4) + 4) % 4
        guard q != 0 else { return image }
        let w = image.width, h = image.height
        let (newW, newH) = q % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2) // angle négatif = sens horaire (repère CoreGraphics)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }

}
