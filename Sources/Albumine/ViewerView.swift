import SwiftUI
import AppKit

/// Visionneuse plein cadre : ← → pour naviguer, 0–5 pour noter, Échap pour fermer.
struct ViewerView: View {
    @Environment(PhotoLibrary.self) private var library
    let photos: [Photo]
    @Binding var index: Int
    let onClose: () -> Void

    @Etat private var image: NSImage?
    @FocusState private var focused: Bool

    private var photo: Photo { photos[index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 70)
                    .padding(.vertical, 60)
            } else {
                ProgressView().controlSize(.large)
            }

            HStack {
                navButton("chevron.left", enabled: index > 0) { go(-1) }
                Spacer()
                navButton("chevron.right", enabled: index < photos.count - 1) { go(1) }
            }
            .padding(.horizontal, 14)

            VStack {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(photo.name).font(.headline)
                        Text((library.photo(id: photo.id)?.date ?? photo.date).formatted(date: .long, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        if !library.caption(of: photo).isEmpty {
                            Text(library.caption(of: photo)).font(.callout).italic()
                        }
                        if !library.people(of: photo).isEmpty {
                            Label(library.people(of: photo).joined(separator: ", "), systemImage: "person.2")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    Spacer()
                    Text("\(index + 1) / \(photos.count)")
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Fermer (Échap)")
                    .padding(.leading, 12)
                }
                Spacer()
                StarRatingPicker(rating: library.rating(of: photo), size: 20) { n in
                    library.setRating(n, for: [photo])
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.space) { go(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
            guard let n = Int(press.characters) else { return .ignored }
            library.setRating(n, for: [photo])
            return .handled
        }
        .task(id: "\(library.rotation(of: photo))|\(photo.id)") {
            let url = photo.url
            let rotation = library.rotation(of: photo)
            // Affiche d'abord la miniature en cache, puis l'image haute définition.
            image = ImageLoader.cached(url, maxPixel: ImageLoader.viewerPixels, rotation: rotation)
                ?? ImageLoader.cached(url, maxPixel: ImageLoader.thumbnailPixels, rotation: rotation)
            let full = await ImageLoader.load(url, maxPixel: ImageLoader.viewerPixels, rotation: rotation, urgent: true)
            guard !Task.isCancelled else { return }
            if let full { image = full }
            preloadNeighbours()
        }
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard photos.indices.contains(next) else { return }
        index = next
    }

    private func preloadNeighbours() {
        for i in [index + 1, index - 1] where photos.indices.contains(i) {
            let url = photos[i].url
            let rotation = library.rotation(of: photos[i])
            Task { _ = await ImageLoader.load(url, maxPixel: ImageLoader.viewerPixels, rotation: rotation, urgent: true) }
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 44, height: 80)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.15))
        .disabled(!enabled)
    }
}
