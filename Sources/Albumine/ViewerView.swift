import SwiftUI
import AppKit
import AVKit

/// Visionneuse plein cadre : ← → pour naviguer, 0–5 pour noter, F pour les visages, Échap pour fermer.
struct ViewerView: View {
    @Environment(PhotoLibrary.self) private var library
    let photos: [Photo]
    @Binding var index: Int
    let onClose: () -> Void

    @Etat private var image: NSImage?
    @Etat private var showFaces = false
    @FocusState private var focused: Bool

    private var photo: Photo { photos[index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            if photo.isVideo {
                VideoPane(url: photo.url)
                    .padding(.horizontal, 70)
                    .padding(.vertical, 60)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        if showFaces {
                            FaceOverlay(faces: library.faces(of: photo).map { face in
                                var f = face
                                let r = library.faceRect(face, in: photo)
                                (f.x, f.y, f.w, f.h) = (r.minX, r.minY, r.width, r.height)
                                return f
                            }, rotation: library.rotation(of: photo))
                        }
                    }
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
                    if !photo.isVideo {
                        Button { showFaces.toggle() } label: {
                            Image(systemName: showFaces ? "person.crop.square.fill" : "person.crop.square")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help("Afficher les visages (F)")
                        .padding(.trailing, 8)
                    }
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
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in
            showFaces.toggle()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
            guard let n = Int(press.characters) else { return .ignored }
            library.setRating(n, for: [photo])
            return .handled
        }
        .task(id: "\(library.rotation(of: photo))|\(photo.id)") {
            let url = photo.url
            let rotation = library.rotation(of: photo)
            if photo.isVideo { image = nil; return }
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

/// Lecture d'une vidéo dans la visionneuse.
struct VideoPane: View {
    let url: URL
    @Etat private var player: AVPlayer?
    @Etat private var playable: Bool?

    var body: some View {
        Group {
            if let player, playable == true {
                VideoPlayer(player: player)
            } else if playable == false {
                VStack(spacing: 12) {
                    Image(systemName: "film").font(.system(size: 48))
                    Text("Ce format vidéo n'est pas lisible par macOS (\(url.pathExtension.uppercased())).")
                    Button("Ouvrir avec l'application par défaut") { NSWorkspace.shared.open(url) }
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: url) {
            player?.pause()
            player = nil
            playable = nil
            let ok = await VideoSupport.isPlayable(url)
            guard !Task.isCancelled else { return }
            playable = ok
            if ok {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Cadres des visages par-dessus la photo (coordonnées relatives, rotation d'affichage appliquée).
struct FaceOverlay: View {
    let faces: [FaceRegion]
    let rotation: Int

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                let r = FaceGeometry.rotate(face.rect, by: rotation)
                let frame = CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height,
                                   width: r.width * geo.size.width, height: r.height * geo.size.height)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(face.name == nil ? Color.orange : Color.white, lineWidth: 2)
                    .frame(width: frame.width, height: frame.height)
                    .overlay(alignment: .bottom) {
                        Text(face.name ?? face.suggestion.map { "\($0) ?" } ?? "?")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                            .offset(y: 20)
                    }
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
    }
}
