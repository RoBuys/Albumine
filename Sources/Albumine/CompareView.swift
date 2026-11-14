import SwiftUI
import AppKit

/// Side-by-side comparison of the photos of a series, with a zoom shared by all panes.
/// Keys: 1–9 keep / discard a photo, Return applies and moves on, ← → change series,
/// Z zooms, A keeps everything, Esc closes.
struct CompareView: View {
    @Environment(PhotoLibrary.self) private var library
    /// Series to go through (similar photos), or a single one (a selection).
    let series: [[Photo]]
    let start: Int
    /// true: series of similar photos (the first one is the suggested best).
    let isSeries: Bool
    let onResolve: (_ keep: [Photo], _ remove: [Photo]) -> Void
    let onClose: () -> Void

    @Etat private var remaining: [[Photo]] = []
    @Etat private var position = 0
    @Etat private var keep: Set<String> = []
    @Etat private var zoom: CGFloat = 1
    @Etat private var zoomBase: CGFloat = 1
    /// Offset of the zoomed image, as a fraction of the pane size (same detail in every pane).
    @Etat private var offset: CGSize = .zero
    @Etat private var offsetBase: CGSize = .zero
    @FocusState private var focused: Bool

    private var current: [Photo] { remaining.indices.contains(position) ? remaining[position] : [] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 10) {
                header
                GeometryReader { geo in
                    let photos = current
                    let columns = photos.count <= 3 ? max(photos.count, 1) : min(Int(ceil(Double(photos.count) / 2)), 4)
                    let rows = Int(ceil(Double(max(photos.count, 1)) / Double(columns)))
                    let visibleRows = min(rows, 2)
                    let spacing: CGFloat = 8
                    let w = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                    let h = (geo.size.height - spacing * CGFloat(visibleRows - 1)) / CGFloat(visibleRows)
                    ScrollView(rows > 2 ? .vertical : []) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: spacing), count: columns), spacing: spacing) {
                            ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                                pane(photo, number: i + 1, size: CGSize(width: w, height: h))
                            }
                        }
                    }
                }
                footer
            }
            .padding(16)
        }
        .foregroundStyle(.white)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            remaining = series.filter { $0.count > 1 || !isSeries }
            position = min(max(start, 0), max(remaining.count - 1, 0))
            resetMarks()
            focused = true
        }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { apply(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            guard let n = Int(press.characters), current.indices.contains(n - 1) else { return .ignored }
            toggle(current[n - 1])
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ")) { _ in toggleZoom(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in setZoom(zoom * 1.5); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "-")) { _ in setZoom(zoom / 1.5); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { _ in keep = Set(current.map(\.id)); return .handled }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isSeries ? "Série \(position + 1) sur \(remaining.count) · \(current.count) photos" : "Comparaison de \(current.count) photos")
                    .font(.headline)
                Text("1–9 : garder ou jeter une photo · Entrée : valider\(isSeries ? " et passer à la série suivante · ← → : changer de série" : "") · Z : zoom · A : tout garder")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain).help("Dézoomer (-)")
            Text("\(Int(zoom * 100)) %").monospacedDigit().frame(width: 54)
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain).help("Zoomer (+) — le zoom et le déplacement s'appliquent à toutes les photos")
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.plain).help("Fermer (Échap)").padding(.leading, 8)
        }
    }

    private var footer: some View {
        let removed = current.filter { !keep.contains($0.id) }.count
        return HStack(spacing: 12) {
            if isSeries {
                Button { move(-1) } label: { Label("Série précédente", systemImage: "chevron.left") }
                    .disabled(position == 0)
                Button { move(1) } label: { Label("Passer", systemImage: "chevron.right") }
                    .disabled(position >= remaining.count - 1)
            }
            Spacer()
            Text(removed == 0 ? "Tout est gardé" : "\(keep.count) gardée\(keep.count > 1 ? "s" : "") · \(removed) à la corbeille")
                .foregroundStyle(.white.opacity(0.7))
            Button(removed == 0 ? (isSeries ? "Tout garder, série suivante" : "Fermer")
                                : "Mettre \(removed) photo\(removed > 1 ? "s" : "") à la corbeille") { apply() }
                .buttonStyle(.borderedProminent)
                .disabled(keep.isEmpty)
        }
        .foregroundStyle(.primary)
        .environment(\.colorScheme, .dark)
    }

    private func pane(_ photo: Photo, number: Int, size: CGSize) -> some View {
        let kept = keep.contains(photo.id)
        return VStack(spacing: 4) {
            ComparePane(photo: photo, zoom: zoom, offset: offset)
                .frame(width: size.width, height: max(size.height - 46, 60))
                .clipped()
                .contentShape(Rectangle())
                .opacity(kept ? 1 : 0.35)
                .overlay(alignment: .topLeading) {
                    Text(kept ? "\(number) · Garder" : "\(number) · À jeter")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(kept ? Color.green.opacity(0.85) : Color.red.opacity(0.85), in: Capsule())
                        .padding(8)
                }
                .overlay { Rectangle().strokeBorder(kept ? Color.green : Color.red.opacity(0.6), lineWidth: 2) }
                .gesture(TapGesture(count: 2).onEnded { toggleZoom() })
                .simultaneousGesture(TapGesture().onEnded { toggle(photo) })
                .gesture(DragGesture()
                    .onChanged { v in
                        guard zoom > 1 else { return }
                        offset = clamp(CGSize(width: offsetBase.width + v.translation.width / size.width,
                                              height: offsetBase.height + v.translation.height / max(size.height - 46, 60)))
                    }
                    .onEnded { _ in offsetBase = offset })
                .gesture(MagnifyGesture()
                    .onChanged { v in setZoom(zoomBase * v.magnification, commit: false) }
                    .onEnded { _ in zoomBase = zoom })
            HStack(spacing: 6) {
                Text(photo.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let s = library.analysis[photo.id]?.b {
                    Text("netteté \(Int(s))").help("Mesure de netteté : plus le nombre est grand, plus la photo est nette")
                }
                Text(ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))
                if library.rating(of: photo) > 0 { Text(String(repeating: "★", count: library.rating(of: photo))).foregroundStyle(.yellow) }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: size.width - 8, height: 18)
            Text(photo.date.formatted(date: .abbreviated, time: .standard) + " · " + photo.folderName)
                .font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                .frame(width: size.width - 8, height: 14)
        }
    }

    // MARK: Actions

    private func resetMarks() {
        // Similar series: the suggested best is kept by default. Selection: everything is kept.
        keep = isSeries ? Set(current.prefix(1).map(\.id)) : Set(current.map(\.id))
        zoom = 1; zoomBase = 1; offset = .zero; offsetBase = .zero
    }

    private func toggle(_ photo: Photo) {
        if keep.contains(photo.id) { keep.remove(photo.id) } else { keep.insert(photo.id) }
    }

    private func move(_ delta: Int) {
        let next = position + delta
        guard isSeries, remaining.indices.contains(next) else { return }
        position = next
        resetMarks()
    }

    private func apply() {
        let photos = current
        guard !photos.isEmpty, !keep.isEmpty else { return }
        // The kept photo that comes first (the best one) receives the annotations of the others.
        onResolve(photos.filter { keep.contains($0.id) }, photos.filter { !keep.contains($0.id) })
        guard isSeries else { onClose(); return }
        remaining.remove(at: position)
        if remaining.isEmpty { onClose(); return }
        position = min(position, remaining.count - 1)
        resetMarks()
    }

    private func toggleZoom() { setZoom(zoom > 1 ? 1 : 3) }

    private func setZoom(_ z: CGFloat, commit: Bool = true) {
        zoom = min(max(z, 1), 12)
        if commit { zoomBase = zoom }
        if zoom == 1 { offset = .zero; offsetBase = .zero } else { offset = clamp(offset); offsetBase = offset }
    }

    private func clamp(_ o: CGSize) -> CGSize {
        let limit = (zoom - 1) / 2
        return CGSize(width: min(max(o.width, -limit), limit), height: min(max(o.height, -limit), limit))
    }
}

/// One photo of the comparison, zoomed and moved like the others.
private struct ComparePane: View {
    @Environment(PhotoLibrary.self) private var library
    let photo: Photo
    let zoom: CGFloat
    let offset: CGSize
    @Etat private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(x: offset.width * geo.size.width, y: offset.height * geo.size.height)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: photo.id) {
            let rotation = library.rotation(of: photo), edits = library.edits(of: photo)
            image = ImageLoader.cached(photo.url, maxPixel: ImageLoader.viewerPixels, rotation: rotation, edits: edits)
                ?? ImageLoader.cached(photo.url, maxPixel: ImageLoader.thumbnailPixels, rotation: rotation, edits: edits)
            let size = photo.offline ? ImageLoader.thumbnailPixels : ImageLoader.viewerPixels
            let full = await ImageLoader.load(photo.url, maxPixel: size, rotation: rotation, edits: edits, urgent: !photo.offline)
            if !Task.isCancelled, let full { image = full }
        }
    }
}
