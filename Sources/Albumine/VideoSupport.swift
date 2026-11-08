import AVFoundation
import CoreGraphics
import Foundation

/// Vidéos : métadonnées (date, lieu) et image de prévisualisation, via AVFoundation.
/// Les formats que macOS ne sait pas lire (AVI, WMV…) restent listés, avec une icône.
enum VideoSupport {
    /// Lecture synchrone : appelée uniquement depuis des fils d'arrière-plan.
    static func metadata(of url: URL) -> ExifReader.Quick {
        let asset = AVURLAsset(url: url)
        var quick = ExifReader.Quick()
        quick.date = asset.creationDate?.dateValue
        for item in asset.commonMetadata {
            if item.commonKey == .commonKeyModel, quick.camera == nil { quick.camera = item.stringValue }
            if item.commonKey == .commonKeyLocation, let iso = item.stringValue, let (lat, lon) = parseISO6709(iso) {
                quick.latitude = lat
                quick.longitude = lon
            }
        }
        return quick
    }

    static func frame(of url: URL, maxPixel: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        for seconds in [1.0, 0.0] {
            if let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) {
                return image
            }
        }
        return nil
    }

    /// « +48.8566+002.3522+035.000/ » → (48.8566, 2.3522)
    static func parseISO6709(_ text: String) -> (Double, Double)? {
        var numbers: [Double] = []
        var current = ""
        for ch in text {
            if ch == "+" || ch == "-" || ch == "/" {
                if let v = Double(current) { numbers.append(v) }
                current = ch == "/" ? "" : String(ch)
            } else {
                current.append(ch)
            }
        }
        if let v = Double(current) { numbers.append(v) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180,
              abs(numbers[0]) > 0.0001 || abs(numbers[1]) > 0.0001 else { return nil }
        return (numbers[0], numbers[1])
    }

    static func isPlayable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }
}
