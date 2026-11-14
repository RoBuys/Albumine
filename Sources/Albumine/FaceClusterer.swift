import Accelerate
import Foundation
import Vision

/// Groups faces that look alike, so that a whole group can be named at once.
/// Works on the raw vectors of Vision's feature prints.
enum FaceClusterer {
    /// Faces closer than this to a group's centre join it (calibrated on named Picasa faces:
    /// groups stay almost always a single person, at the price of several groups per person).
    static let threshold: Float = 0.5

    static func vector(_ print: VNFeaturePrintObservation) -> [Float]? {
        guard print.elementType == .float else { return nil }
        return print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var d: Float = 0
        vDSP_distancesq(a, 1, b, 1, &d, vDSP_Length(a.count))
        return d.squareRoot()
    }

    /// Indices of the vectors, grouped. Largest groups first; single faces come last.
    static func cluster(_ vectors: [[Float]], threshold: Float = threshold) -> [[Int]] {
        var centres: [[Float]] = []
        var members: [[Int]] = []
        func nearest(_ v: [Float], excluding: Int? = nil) -> (Int, Float)? {
            var best: (Int, Float)?
            for (c, centre) in centres.enumerated() where c != excluding && !members[c].isEmpty {
                let d = distance(v, centre)
                if best == nil || d < best!.1 { best = (c, d) }
            }
            return best
        }
        func recentre(_ c: Int) {
            guard let first = members[c].first else { return }
            var sum = [Float](repeating: 0, count: vectors[first].count)
            for i in members[c] { vDSP_vadd(sum, 1, vectors[i], 1, &sum, 1, vDSP_Length(sum.count)) }
            var n = Float(members[c].count)
            vDSP_vsdiv(sum, 1, &n, &sum, 1, vDSP_Length(sum.count))
            centres[c] = sum
        }
        // Pass 1: each face joins the nearest group, or starts a new one.
        for (i, v) in vectors.enumerated() {
            if let (c, d) = nearest(v), d < threshold {
                members[c].append(i)
                recentre(c)
            } else {
                centres.append(v)
                members.append([i])
            }
        }
        // Pass 2: with the final centres, each face goes to its nearest group.
        var assignment = [Int](repeating: 0, count: vectors.count)
        for (c, list) in members.enumerated() { for i in list { assignment[i] = c } }
        for (i, v) in vectors.enumerated() {
            if let (c, d) = nearest(v), d < threshold, c != assignment[i] {
                members[assignment[i]].removeAll { $0 == i }
                members[c].append(i)
                assignment[i] = c
            }
        }
        return members.filter { !$0.isEmpty }.sorted { ($0.count, $1[0]) > ($1.count, $0[0]) }
    }
}

/// Vectors of the unnamed faces already computed (face identifier → vector), so that
/// grouping again only reads the new faces. An empty vector marks an unreadable face.
struct FaceVectorCache {
    var vectors: [String: [Float]] = [:]

    static var url: URL { AppPaths.support.appendingPathComponent("face-vectors.plist") }

    static func load() -> FaceVectorCache {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return FaceVectorCache() }
        return FaceVectorCache(vectors: raw.mapValues { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } })
    }

    func save() {
        let raw = vectors.mapValues { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(raw) { try? data.write(to: Self.url, options: .atomic) }
    }
}
