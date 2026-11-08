import SwiftUI
import AppKit

/// Panneau de droite : aperçu, note, étiquettes et informations EXIF de la sélection.
struct InspectorView: View {
    @Environment(PhotoLibrary.self) private var library
    let photos: [Photo]

    @Etat private var newTag = ""
    @Etat private var info: PhotoInfo?

    var body: some View {
        if photos.isEmpty {
            ContentUnavailableView("Aucune sélection", systemImage: "photo",
                                   description: Text("Sélectionnez une ou plusieurs photos."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ratingSection
                    tagsSection
                    if photos.count == 1 { infoSection(photos[0]) }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(photos.map(\.url))
                    } label: {
                        Label("Afficher dans le Finder", systemImage: "folder")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var header: some View {
        if photos.count == 1, let photo = photos.first {
            ThumbnailView(url: photo.url)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 220)
            Text(photo.name).font(.headline).textSelection(.enabled)
        } else {
            Label("\(photos.count) photos sélectionnées", systemImage: "square.stack")
                .font(.headline)
        }
    }

    private var ratingSection: some View {
        let ratings = Set(photos.map { library.rating(of: $0) })
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(photos.count > 1 && ratings.count > 1 ? "Note (différente selon les photos)" : "Note")
            StarRatingPicker(rating: ratings.count == 1 ? ratings.first! : 0, size: 18) { n in
                library.setRating(n, for: photos)
            }
        }
    }

    private var tagsSection: some View {
        let perPhoto = photos.map { Set(library.tags(of: $0)) }
        let union = perPhoto.reduce(into: Set<String>()) { $0.formUnion($1) }
        let common = perPhoto.dropFirst().reduce(perPhoto.first ?? []) { $0.intersection($1) }
        let shown = union.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let suggestions = library.allTags.map(\.name).filter { !common.contains($0) }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Étiquettes")
            if !shown.isEmpty {
                FlowLayout {
                    ForEach(shown, id: \.self) { tag in
                        TagChip(name: common.contains(tag) ? tag : "\(tag) (partiel)") {
                            library.removeTag(tag, from: photos)
                        }
                    }
                }
            }
            HStack {
                TextField("Ajouter une étiquette", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { tag in
                            Button(tag) { library.addTag(tag, to: photos) }
                        }
                    } label: {
                        Image(systemName: "tag")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Étiquettes existantes")
                }
            }
            Text("Astuce : séparez plusieurs étiquettes par des virgules.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func infoSection(_ photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Informations")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                row("Date", (info?.dateTaken ?? photo.date).formatted(date: .abbreviated, time: .shortened))
                if let w = info?.pixelWidth, let h = info?.pixelHeight {
                    let mp = Double(w * h) / 1_000_000
                    row("Dimensions", "\(w) × \(h) (\(mp.formatted(.number.precision(.fractionLength(1)))) Mpx)")
                }
                row("Taille", ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))
                if let camera = info?.camera { row("Appareil", camera) }
                if let lens = info?.lens { row("Objectif", lens) }
                if let settings = shootingSettings { row("Réglages", settings) }
                row("Dossier", photo.folderName)
            }
            .font(.callout)

            if let lat = info?.latitude, let lon = info?.longitude {
                Link(destination: URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(photo.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")")!) {
                    Label("Voir le lieu dans Plans", systemImage: "mappin.and.ellipse")
                }
                .font(.callout)
            }
        }
        .task(id: photo.id) {
            info = nil
            let url = photo.url
            info = await Task.detached { ExifReader.info(for: url) }.value
        }
    }

    // MARK: Utilitaires

    private var shootingSettings: String? {
        guard let info else { return nil }
        var parts: [String] = []
        if let f = info.aperture { parts.append("ƒ/\(f.formatted(.number.precision(.fractionLength(0...1))))") }
        if let t = info.exposure {
            parts.append(t >= 1 ? "\(t.formatted(.number.precision(.fractionLength(0...1)))) s"
                                : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = info.iso { parts.append("ISO \(iso)") }
        if let fl = info.focalLength { parts.append("\(Int(fl.rounded())) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func addTag() {
        for tag in newTag.split(separator: ",") { library.addTag(String(tag), to: photos) }
        newTag = ""
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
