import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Full-screen slideshow: crossfade, slow zoom, optional music.
/// Space: pause · ← →: previous / next · Esc: quit.
struct SlideshowView: View {
    @Environment(PhotoLibrary.self) private var library
    let photos: [Photo]
    let onClose: () -> Void

    @Etat private var index = 0
    @Etat private var shown: (index: Int, image: NSImage)?
    @Etat private var playing = true
    @Etat private var zoomed = false
    @Etat private var interval = 4.0
    @Etat private var player: AVAudioPlayer?
    @Etat private var enteredFullScreen = false
    @Etat private var showControls = true
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let shown {
                Image(nsImage: shown.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoomed ? 1.06 : 1.0)
                    .id(shown.index)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.large)
            }
            if showControls { controls }
        }
        .animation(.easeInOut(duration: 1.0), value: shown?.index)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { showControls = $0 }
        .onKeyPress(.space) { playing.toggle(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear {
            focused = true
            if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                enteredFullScreen = true
            }
        }
        .task(id: index) { await show(index) }
        .task(id: "\(playing)|\(interval)") {
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if playing, !Task.isCancelled { step(1) }
            }
        }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Button { step(-1) } label: { Image(systemName: "backward.fill") }
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Button { step(1) } label: { Image(systemName: "forward.fill") }
                Divider().frame(height: 18)
                Picker("Durée", selection: $interval) {
                    Text("2 s").tag(2.0)
                    Text("4 s").tag(4.0)
                    Text("7 s").tag(7.0)
                    Text("12 s").tag(12.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Button { chooseMusic() } label: {
                    Label(player == nil ? "Musique…" : "Changer de musique", systemImage: "music.note")
                }
                if player != nil {
                    Button { player?.stop(); player = nil } label: { Image(systemName: "speaker.slash.fill") }
                        .help("Couper la musique")
                }
                Text("\(index + 1) / \(photos.count)").monospacedDigit().foregroundStyle(.white.opacity(0.7))
                Button("Quitter") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, 30)
        }
        .transition(.opacity)
    }

    private func step(_ delta: Int) {
        guard !photos.isEmpty else { return }
        index = (index + delta + photos.count) % photos.count
    }

    private func show(_ i: Int) async {
        guard photos.indices.contains(i) else { return }
        let photo = photos[i]
        let rotation = library.rotation(of: photo)
        guard let image = await ImageLoader.load(photo.url, maxPixel: ImageLoader.viewerPixels,
                                                 rotation: rotation, edits: library.edits(of: photo), urgent: true),
              !Task.isCancelled else { return }
        zoomed = false
        shown = (i, image)
        withAnimation(.linear(duration: interval + 1)) { zoomed = true }
        // Preloads the next one.
        let next = photos[(i + 1) % photos.count]
        let nextRotation = library.rotation(of: next)
        let nextEdits = library.edits(of: next)
        Task { _ = await ImageLoader.load(next.url, maxPixel: ImageLoader.viewerPixels, rotation: nextRotation, edits: nextEdits, urgent: true) }
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choisissez un morceau pour accompagner le diaporama"
        panel.prompt = "Choisir"
        if let last = UserDefaults.standard.string(forKey: "slideshowMusicFolder") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "slideshowMusicFolder")
        player?.stop()
        p.numberOfLoops = -1
        p.play()
        player = p
        focused = true
    }

    private func close() {
        player?.stop()
        if enteredFullScreen, let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        onClose()
    }
}
