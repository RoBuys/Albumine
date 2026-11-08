import CoreGraphics
import Foundation
import Vision

/// Face detection and recognition with Apple's Vision framework (everything stays on the Mac).
///
/// Principle: already named faces (Picasa import, confirmations) serve as examples.
/// For each new face we compute a "fingerprint" (VNFeaturePrint) and suggest
/// the person whose examples are closest. The suggestion must be confirmed.
enum FaceEngine {
    static let analysisPixels = 1600
    /// Faces smaller than this fraction of the width are ignored (too blurry to recognize).
    static let minFaceWidth = 0.035

    /// Image oriented as on screen (EXIF + display rotation).
    static func uprightImage(_ url: URL, rotation: Int) -> CGImage? {
        guard let cg = ImageDecoding.decode(url, maxPixel: analysisPixels) else { return nil }
        return ImageDecoding.rotate(cg, rotation)
    }

    /// Relative rectangles, origin at the top left, in the given image.
    static func detectFaces(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox // origin at the bottom left
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
        .filter { $0.width >= minFaceWidth }
    }

    /// Crops a face (with a margin) out of an image.
    static func crop(_ image: CGImage, face: CGRect, margin: Double = 0.25) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        var r = CGRect(x: face.minX * w, y: face.minY * h, width: face.width * w, height: face.height * h)
        r = r.insetBy(dx: -r.width * margin, dy: -r.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 16, r.height >= 16 else { return nil }
        return image.cropping(to: r.integral)
    }

    static func featurePrint(of faceImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: faceImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    /// Fingerprint of a known face (`rect`: stored coordinates, without display rotation).
    static func referencePrint(url: URL, rotation: Int, rect: CGRect) -> VNFeaturePrintObservation? {
        guard let image = uprightImage(url, rotation: rotation),
              let crop = crop(image, face: FaceGeometry.rotate(rect, by: rotation)) else { return nil }
        return featurePrint(of: crop)
    }

    /// Detects a photo's faces and suggests a name for each one.
    static func analyze(url: URL, rotation: Int, references: FaceReferences) -> [FaceRegion] {
        guard let image = uprightImage(url, rotation: rotation) else { return [] }
        return detectFaces(in: image).map { upright in
            // Stored without the display rotation, like Picasa faces.
            let r = FaceGeometry.rotate(upright, by: (4 - rotation) % 4)
            var region = FaceRegion(name: nil, x: r.minX, y: r.minY, w: r.width, h: r.height)
            if let c = crop(image, face: upright), let fp = featurePrint(of: c), let m = references.bestMatch(for: fp) {
                region.suggestion = m.name
                region.score = m.distance
            }
            return region
        }
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double {
        var d: Float = .greatestFiniteMagnitude
        try? a.computeDistance(&d, to: b)
        return Double(d)
    }
}

/// Reference fingerprints per person, saved in `faceprints.dat`.
final class FaceReferences: @unchecked Sendable {
    /// Number of examples kept per person.
    static let samplesPerPerson = 24
    /// Below this distance a name is suggested (calibrated on Picasa faces).
    static var threshold = 0.62

    private(set) var prints: [String: [VNFeaturePrintObservation]] = [:]
    private let lock = NSLock()

    static let fileURL = AppPaths.support.appendingPathComponent("faceprints.dat")

    var people: Set<String> { lock.withLock { Set(prints.keys) } }

    func add(_ print: VNFeaturePrintObservation, for name: String) {
        lock.withLock {
            var list = prints[name] ?? []
            if list.count >= Self.samplesPerPerson * 2 { list.removeFirst() }
            list.append(print)
            prints[name] = list
        }
    }

    func remove(_ name: String) { lock.withLock { prints[name] = nil } }

    /// Merges one person's examples into another's (rename / merge).
    func rename(_ old: String, to new: String) {
        lock.withLock {
            guard let moved = prints.removeValue(forKey: old) else { return }
            prints[new, default: []] += moved
        }
    }

    /// Closest person: (name, distance), if below the threshold.
    func bestMatch(for print: VNFeaturePrintObservation) -> (name: String, distance: Double)? {
        let snapshot = lock.withLock { prints }
        var best: (String, Double)?
        for (name, samples) in snapshot {
            // Mean of the 3 closest examples: more robust than a single one.
            let ds = samples.map { FaceEngine.distance(print, $0) }.sorted().prefix(3)
            guard !ds.isEmpty else { continue }
            let d = ds.reduce(0, +) / Double(ds.count)
            if best == nil || d < best!.1 { best = (name, d) }
        }
        guard let best, best.1 < Self.threshold else { return nil }
        return best
    }

    func save() {
        let snapshot = lock.withLock { prints }
        let dict = NSMutableDictionary()
        for (k, v) in snapshot { dict[k] = v as NSArray }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: true) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    static func load() -> FaceReferences {
        let refs = FaceReferences()
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSDictionary.self, NSArray.self, NSString.self, VNFeaturePrintObservation.self],
                  from: data) as? [String: [VNFeaturePrintObservation]]
        else { return refs }
        refs.prints = dict
        return refs
    }
}
