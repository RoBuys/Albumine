import CoreGraphics
import Foundation
import Vision

/// Result of a photo's analysis (stored in analysis.json).
struct AnalysisEntry: Codable {
    var s: Int64          // file size
    var m: Double         // modification date
    var l: [String]?      // Vision categories (identifiers)
    var a: Float?         // Vision aesthetic score (-1 … 1)
    var u: Bool?          // "utility" image (screenshot, document…)
    var b: Float?         // sharpness (variance of the Laplacian)
    var y: Float?         // mean brightness (0 … 1)
    var h: UInt64?        // perceptual hash (64-bit dHash)
    var t: String?        // text read in the image (OCR)
    var v: Int?           // analysis version
}

/// Content analysis, entirely on the Mac: categories, quality, sharpness, brightness, fingerprint.
enum ContentAnalyzer {
    static let minConfidence: Float = 0.3
    /// Version 2: adds text recognition.
    static let version = 2

    static func analyze(_ photo: Photo) -> AnalysisEntry {
        var entry = AnalysisEntry(s: photo.fileSize, m: photo.modificationDate.timeIntervalSince1970, v: version)
        guard !photo.isVideo, let image = ImageLoader.diskThumbnail(photo.url) else { return entry }

        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.recognitionLanguages = ["fr-FR", "en-US"]
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.02
        var requests: [VNRequest] = [classify, text]
        var aesthetics: VNRequest?
        if #available(macOS 15.0, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            aesthetics = r
            requests.append(r)
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? handler.perform(requests)) != nil {
            let labels = (classify.results ?? [])
                .filter { $0.confidence >= minConfidence && !ContentLabels.ignored.contains($0.identifier) }
                .sorted { $0.confidence > $1.confidence }
                .prefix(10)
                .map(\.identifier)
            entry.l = labels.isEmpty ? nil : Array(labels)
            // Readable text (signs, documents, screenshots…): confident words of at least 3 letters.
            let words = (text.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence >= 0.4 }
                .map(\.string)
                .joined(separator: " ")
                .split(separator: " ")
                .filter { $0.count >= 3 && $0.contains(where: \.isLetter) }
            if !words.isEmpty { entry.t = String(words.joined(separator: " ").prefix(500)) }
            if #available(macOS 15.0, *), let obs = (aesthetics as? VNCalculateImageAestheticsScoresRequest)?.results?.first {
                entry.a = obs.overallScore
                entry.u = obs.isUtility ? true : nil
            }
        }
        let gray = grayscale(image, maxSide: 256)
        entry.b = gray.map(sharpness)
        entry.y = gray.map(brightness)
        entry.h = dHash(image)
        return entry
    }

    // MARK: Image measurements

    struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    static func grayscale(_ image: CGImage, maxSide: Int) -> Gray? {
        let scale = Double(maxSide) / Double(max(image.width, image.height))
        let w = max(Int(Double(image.width) * min(scale, 1)), 8)
        let h = max(Int(Double(image.height) * min(scale, 1)), 8)
        return grayscale(image, width: w, height: h)
    }

    static func grayscale(_ image: CGImage, width w: Int, height h: Int) -> Gray? {
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Gray(width: w, height: h, pixels: pixels) : nil
    }

    /// Variance of the Laplacian: low = blurry image.
    static func sharpness(_ g: Gray) -> Float {
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(g.height - 1) {
            for x in 1..<(g.width - 1) {
                let i = y * g.width + x
                let v = 4 * Double(g.pixels[i]) - Double(g.pixels[i - 1]) - Double(g.pixels[i + 1])
                    - Double(g.pixels[i - g.width]) - Double(g.pixels[i + g.width])
                sum += v
                sumSq += v * v
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return Float(sumSq / n - mean * mean)
    }

    static func brightness(_ g: Gray) -> Float {
        guard !g.pixels.isEmpty else { return 0 }
        return Float(g.pixels.reduce(0) { $0 + Int($1) }) / Float(g.pixels.count) / 255
    }

    /// dHash: compares each pixel with its right neighbor on a 9 × 8 image.
    static func dHash(_ image: CGImage) -> UInt64? {
        guard let g = grayscale(image, width: 9, height: 8) else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash <<= 1
                if g.pixels[y * 9 + x] > g.pixels[y * 9 + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}

enum AnalysisStore {
    static let url = AppPaths.support.appendingPathComponent("analysis.json")

    static func load() -> [String: AnalysisEntry] {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode([String: AnalysisEntry].self, from: data) else { return [:] }
        return store
    }

    static func save(_ store: [String: AnalysisEntry]) {
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: url, options: .atomic) }
    }
}

/// Reasons why a photo looks like a failure.
enum RejectReason: String, CaseIterable {
    case blurry = "Floues"
    case dark = "Trop sombres"
    case bright = "Surexposées"
    case utility = "Captures d'écran et documents"
    case poor = "Peu réussies"

    /// Thresholds calibrated on 400 photos of a real library (≈ 1–2 % of photos per criterion).
    static var blurThreshold: Float = 65
    static var darkThreshold: Float = 0.09
    static var brightThreshold: Float = 0.94
    static var aestheticThreshold: Float = -0.75
    static let documentLabels: Set<String> = [
        "document", "printed_page", "receipt", "handwriting", "diagram", "chart", "whiteboard", "screenshot",
    ]

    static func reason(for e: AnalysisEntry) -> RejectReason? {
        let labels = Set(e.l ?? [])
        if labels.contains("screenshot") { return .utility }
        // Vision flags many photos as "utility": only poor-quality documents are kept.
        if e.u == true, !labels.isDisjoint(with: documentLabels), (e.a ?? 0) < 0 { return .utility }
        if let y = e.y, y < darkThreshold { return .dark }
        if let y = e.y, y > brightThreshold { return .bright }
        if let b = e.b, b < blurThreshold { return .blurry }
        if let a = e.a, a < aestheticThreshold { return .poor }
        return nil
    }
}

/// Groups nearly identical photos (bursts, edited or resized versions).
enum SimilarFinder {
    static var maxDistance = 10
    /// Time window for bursts and successive shots.
    static var window: TimeInterval = 180

    struct Item {
        let id: String
        let date: Date
        let hash: UInt64
    }

    static func groups(_ items: [Item]) -> [[String]] {
        let sorted = items.sorted { $0.date < $1.date }
        var parent = Array(0..<sorted.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        // 1. Shots close in time and visually similar.
        for i in sorted.indices {
            var j = i + 1
            while j < sorted.count, sorted[j].date.timeIntervalSince(sorted[i].date) <= window {
                if ContentAnalyzer.distance(sorted[i].hash, sorted[j].hash) <= maxDistance { union(i, j) }
                j += 1
            }
        }
        // 2. Same image whatever the date (resized or re-exported copy…).
        var byHash: [UInt64: Int] = [:]
        for (i, item) in sorted.enumerated() where item.hash != 0 {
            if let j = byHash[item.hash] { union(i, j) } else { byHash[item.hash] = i }
        }

        var clusters: [Int: [String]] = [:]
        for i in sorted.indices { clusters[find(i), default: []].append(sorted[i].id) }
        return clusters.values.filter { $0.count > 1 }
    }
}
