import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ExportOptions {
    /// Longest side in pixels; nil = original size.
    var maxPixel: Int? = 2048
    var quality: Double = 0.85
    var applyRotation = true
    var removeLocation = false
}

/// Exports the selection to a folder (resized JPEGs, videos copied as they are).
struct ExportSheet: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @Etat private var options = ExportOptions()
    @Etat private var done = 0
    @Etat private var running = false
    @Etat private var failures = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporter \(photos.count) élément\(photos.count > 1 ? "s" : "")").font(.title3.weight(.semibold))
            Form {
                Picker("Taille", selection: $options.maxPixel) {
                    Text("Originale").tag(Int?.none)
                    Text("Très grande (3840 px)").tag(Int?.some(3840))
                    Text("Grande (2048 px) — écran, partage").tag(Int?.some(2048))
                    Text("Moyenne (1024 px) — e-mail").tag(Int?.some(1024))
                }
                LabeledContent("Qualité JPEG") {
                    HStack {
                        Slider(value: $options.quality, in: 0.5...1.0, step: 0.05)
                        Text("\(Int(options.quality * 100)) %").monospacedDigit().frame(width: 44)
                    }
                }
                Toggle("Appliquer les rotations et retouches faites dans Albumine", isOn: $options.applyRotation)
                Toggle("Retirer la position GPS", isOn: $options.removeLocation)
            }
            .formStyle(.grouped)
            .disabled(running)

            Text("Les vidéos sont copiées telles quelles. Les originaux ne sont jamais modifiés.")
                .font(.caption).foregroundStyle(.secondary)

            if running {
                ProgressView(value: Double(done), total: Double(max(photos.count, 1))) {
                    Text("Export \(done) / \(photos.count)…")
                }
            }

            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button("Exporter…") { chooseFolderAndExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || photos.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exporter ici"
        panel.message = "Choisissez le dossier de destination"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let items = photos.filter { !$0.offline }.map { ($0, library.rotation(of: $0), library.edits(of: $0)) }
        let opts = options
        running = true
        done = 0
        failures = 0
        Task {
            for (photo, rotation, edits) in items {
                let ok = await Task.detached(priority: .userInitiated) {
                    (try? Exporter.export(photo, rotation: rotation, edits: edits, to: folder, options: opts)) != nil
                }.value
                if !ok { failures += 1 }
                done += 1
            }
            running = false
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            library.notice = "\(done - failures) élément(s) exporté(s) dans « \(folder.lastPathComponent) »."
                + (failures > 0 ? " \(failures) échec(s)." : "")
            dismiss()
        }
    }
}

enum Exporter {
    struct Failure: Error {}

    @discardableResult
    static func export(_ photo: Photo, rotation: Int, edits: PhotoEdits? = nil, to folder: URL, options: ExportOptions) throws -> URL {
        let fm = FileManager.default
        let edited = options.applyRotation && !(edits?.isIdentity ?? true)
        let needsReencode = !photo.isVideo
            && (options.maxPixel != nil || (options.applyRotation && rotation != 0) || edited || options.removeLocation
                || !["jpg", "jpeg"].contains(photo.url.pathExtension.lowercased()))
        if !needsReencode {
            let dest = unique(folder.appendingPathComponent(photo.name))
            try fm.copyItem(at: photo.url, to: dest)
            return dest
        }
        guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, nil) else { throw Failure() }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 4000
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 4000
        let maxSide = options.maxPixel.map { min($0, max(w, h)) } ?? max(w, h)
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else { throw Failure() }
        if options.applyRotation { image = EditRenderer.render(ImageDecoding.rotate(image, rotation), edits) }

        // Original metadata kept (date, camera…), orientation reset to 1.
        var meta = props
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImagePropertyPixelWidth] = nil
        meta[kCGImagePropertyPixelHeight] = nil
        if options.removeLocation { meta[kCGImagePropertyGPSDictionary] = nil }
        meta[kCGImageDestinationLossyCompressionQuality] = options.quality

        let base = (photo.name as NSString).deletingPathExtension
        let dest = unique(folder.appendingPathComponent(base + ".jpg"))
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure() }
        CGImageDestinationAddImage(out, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw Failure() }
        return dest
    }

    /// "photo.jpg" → "photo (2).jpg" if the name is already taken.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
