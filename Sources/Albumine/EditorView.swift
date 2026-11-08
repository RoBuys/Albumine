import AppKit
import SwiftUI

/// Non-destructive photo editor (opened from the viewer, key E).
struct EditorView: View {
    @Environment(PhotoLibrary.self) private var library
    let photo: Photo
    let onDone: () -> Void

    @Etat private var draft = PhotoEdits()
    @Etat private var base: CGImage?
    @Etat private var preview: NSImage?
    @Etat private var cropping = false
    @Etat private var aspect: CropAspect = .free
    @Etat private var renderTask: Task<Void, Never>?
    @Etat private var showOriginal = false

    enum CropAspect: String, CaseIterable, Identifiable {
        case free = "Libre", original = "Original", square = "Carré", r43 = "4:3", r32 = "3:2", r169 = "16:9", portrait = "Portrait 3:4"
        var id: String { rawValue }
        func ratio(original: Double) -> Double? {
            switch self {
            case .free: return nil
            case .original: return original
            case .square: return 1
            case .r43: return 4.0 / 3
            case .r32: return 3.0 / 2
            case .r169: return 16.0 / 9
            case .portrait: return 3.0 / 4
            }
        }
    }

    private var imageAspect: Double {
        guard let base else { return 1.5 }
        return Double(base.width) / Double(base.height)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            if cropping {
                                CropOverlay(crop: $draft.crop, ratio: aspect.ratio(original: imageAspect), imageAspect: imageAspect)
                            }
                        }
                        .padding(40)
                } else {
                    ProgressView().controlSize(.large)
                }
                if showOriginal {
                    Text("Original").font(.caption.bold()).padding(6)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 12)
                }
            }
            panel
                .frame(width: 300)
                .background(.regularMaterial)
        }
        .task {
            draft = library.edits(of: photo) ?? PhotoEdits()
            let url = photo.url, rotation = library.rotation(of: photo)
            base = await Task.detached(priority: .userInitiated) {
                ImageDecoding.decode(url, maxPixel: 1600).map { ImageDecoding.rotate($0, rotation) }
            }.value
            rerender()
        }
        .onChange(of: draft) { rerender() }
        .onChange(of: cropping) { rerender() }
        .onChange(of: showOriginal) { rerender() }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Retoucher").font(.title3.weight(.semibold))
                        Spacer()
                        Button { showOriginal.toggle() } label: {
                            Image(systemName: showOriginal ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help("Comparer avec l'original")
                    }
                    Toggle(isOn: $draft.auto) {
                        Label("J'ai de la chance", systemImage: "wand.and.stars")
                    }
                    .toggleStyle(.button)
                    .help("Corrections automatiques (exposition, couleurs, contraste)")

                    group("Lumière") {
                        slider("Exposition", $draft.exposure, -2...2)
                        slider("Contraste", $draft.contrast, -1...1)
                        slider("Hautes lumières", $draft.highlights, -1...1)
                        slider("Ombres", $draft.shadows, -1...1)
                    }
                    group("Couleur") {
                        slider("Saturation", $draft.saturation, -1...1)
                        slider("Chaleur", $draft.warmth, -1...1)
                    }
                    group("Filtre") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                            ForEach(PhotoEdits.Filter.allCases) { f in
                                Button(f.rawValue) { draft.filter = f }
                                    .buttonStyle(.bordered)
                                    .tint(draft.filter == f ? .accentColor : nil)
                                    .controlSize(.small)
                            }
                        }
                    }
                    group("Cadrage") {
                        slider("Redresser", $draft.straighten, -15...15, format: "%.1f°")
                        Toggle("Recadrer", isOn: $cropping)
                        if cropping {
                            Picker("Format", selection: $aspect) {
                                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .onChange(of: aspect) { applyAspect() }
                        }
                        if draft.hasCrop {
                            Button("Annuler le recadrage") { draft.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Tout réinitialiser") { draft = PhotoEdits() }
                    .disabled(draft.isIdentity)
                Spacer()
                Button("Annuler") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    library.setEdits(draft, for: photo)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            Text("L'original n'est jamais modifié : les retouches s'appliquent à l'affichage et à l'export.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 12)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String = "%+.2f") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .onTapGesture(count: 2) { value.wrappedValue = 0 }
                .help("Double-clic : remettre à zéro")
        }
    }

    // MARK: Rendering

    private func rerender() {
        guard let base else { return }
        let edits = showOriginal ? nil : draft
        let crop = !cropping
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(30)) // coalesces slider movements
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { EditRenderer.render(base, edits, cropping: crop) }.value
            guard !Task.isCancelled else { return }
            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    /// Largest centered rectangle with the chosen aspect ratio.
    private func applyAspect() {
        guard let ratio = aspect.ratio(original: imageAspect) else { return }
        var w = 1.0, h = imageAspect / ratio
        if h > 1 { w = ratio / imageAspect; h = 1 }
        draft.crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

/// Movable crop frame with corner handles and a rule-of-thirds grid.
struct CropOverlay: View {
    @Binding var crop: CGRect
    /// Forced aspect ratio (width / height in pixels), nil = free.
    let ratio: Double?
    let imageAspect: Double

    @Etat private var start: CGRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let r = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                           width: crop.width * size.width, height: crop.height * size.height)
            ZStack(alignment: .topLeading) {
                // Darkens the area outside the frame.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(r)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))

                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.4), lineWidth: 0.5)

                Rectangle()
                    .stroke(.white, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .offset(x: r.minX, y: r.minY)
                    .gesture(drag(size: size) { s, dx, dy in
                        CGRect(x: min(max(s.minX + dx, 0), 1 - s.width), y: min(max(s.minY + dy, 0), 1 - s.height),
                               width: s.width, height: s.height)
                    })

                ForEach(0..<4, id: \.self) { corner in
                    let point = CGPoint(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 2)
                        .position(point)
                        .gesture(drag(size: size) { s, dx, dy in resize(s, corner: corner, dx: dx, dy: dy) })
                }
            }
        }
    }

    private func drag(size: CGSize, _ transform: @escaping (CGRect, Double, Double) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if start == nil { start = crop }
                guard let s = start else { return }
                crop = transform(s, v.translation.width / size.width, v.translation.height / size.height)
            }
            .onEnded { _ in start = nil }
    }

    /// Moves a corner; the opposite corner stays fixed. Keeps the aspect ratio if one is forced.
    private func resize(_ s: CGRect, corner: Int, dx: Double, dy: Double) -> CGRect {
        let left = corner % 2 == 0, top = corner < 2
        let fixedX = left ? s.maxX : s.minX, fixedY = top ? s.maxY : s.minY
        var x = min(max((left ? s.minX : s.maxX) + dx, 0), 1)
        var y = min(max((top ? s.minY : s.maxY) + dy, 0), 1)
        var w = max(abs(x - fixedX), 0.05)
        var h = max(abs(y - fixedY), 0.05)
        if let ratio {
            // h (relative) = w (relative) × image aspect / ratio
            h = w * imageAspect / ratio
            let maxH = top ? fixedY : 1 - fixedY
            if h > maxH { h = maxH; w = h * ratio / imageAspect }
        }
        x = left ? fixedX - w : fixedX
        y = top ? fixedY - h : fixedY
        return CGRect(x: max(0, x), y: max(0, y), width: min(w, 1), height: min(h, 1))
    }
}
