import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library

    @Etat private var sidebar: SidebarItem? = .all
    @Etat private var search = ""
    @Etat private var selection: Set<String> = []
    @Etat private var anchor: String?
    @Etat private var thumbSize: Double = 160
    @Etat private var sort: PhotoSort = .newest
    @Etat private var minRating = 0
    @Etat private var showInspector = true
    @Etat private var viewerIndex: Int?
    @Etat private var visible: [Photo] = []
    @FocusState private var gridFocused: Bool

    /// Tout ce qui influence la liste affichée. Elle n'est recalculée que si ceci change.
    private struct FilterKey: Equatable {
        var revision: Int
        var sidebar: SidebarItem?
        var search: String
        var sort: PhotoSort
        var minRating: Int
    }

    private var filterKey: FilterKey {
        FilterKey(revision: library.revision, sidebar: sidebar, search: search, sort: sort, minRating: minRating)
    }

    var body: some View {
        let photos = visible
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail(photos)
                .navigationTitle(title)
                .navigationSubtitle(subtitle(photos))
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Nom, dossier, étiquette, appareil, année")
        .inspector(isPresented: $showInspector) {
            InspectorView(photos: selectedPhotos)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
        }
        .toolbar { toolbar }
        .onChange(of: sidebar) { selection.removeAll(); anchor = nil }
        .overlay {
            if let index = viewerIndex, !photos.isEmpty {
                ViewerView(
                    photos: photos,
                    index: Binding(
                        get: { min(index, photos.count - 1) },
                        set: { newValue in
                            viewerIndex = newValue
                            selection = [photos[newValue].id]
                            anchor = photos[newValue].id
                        }
                    ),
                    onClose: { viewerIndex = nil; gridFocused = true }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewerIndex == nil)
        .task(id: filterKey) {
            // Petite temporisation pendant la frappe dans la recherche.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let start = Date()
            visible = filteredPhotos()
            Debug.log("liste : \(visible.count) photos en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    // MARK: Grille

    @ViewBuilder
    private func detail(_ photos: [Photo]) -> some View {
        if library.roots.isEmpty {
            ContentUnavailableView {
                Label("Aucun dossier", systemImage: "photo.stack")
            } description: {
                Text("Ajoutez un dossier de photos (ou glissez-le ici). Les fichiers restent où ils sont.")
            } actions: {
                Button("Ajouter un dossier…") { library.addFolderWithPanel() }
                    .buttonStyle(.borderedProminent)
            }
            .dropDestination(for: URL.self) { urls, _ in library.addFolders(urls); return true }
        } else if photos.isEmpty {
            if library.isScanning || (library.photoCount > 0 && search.isEmpty && minRating == 0 && sidebar == .all) {
                ProgressView("Analyse des dossiers…")
            } else if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ContentUnavailableView("Aucune photo", systemImage: "photo",
                                       description: Text("Rien à afficher ici pour l'instant."))
            }
        } else {
            grid(photos)
        }
    }

    private func grid(_ photos: [Photo]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.3), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        PhotoCell(
                            photo: photo,
                            size: thumbSize,
                            isSelected: selection.contains(photo.id),
                            rating: library.rating(of: photo)
                        )
                        .id(photo.id)
                        .gesture(TapGesture(count: 2).onEnded { viewerIndex = index })
                        .simultaneousGesture(TapGesture().onEnded { click(photo, in: photos) })
                        .contextMenu { contextMenu(for: photo) }
                    }
                }
                .padding(14)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .return, .space]) { press in
                handleKey(press.key, in: photos, proxy: proxy)
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
                guard !selectedPhotos.isEmpty, let n = Int(press.characters) else { return .ignored }
                library.setRating(n, for: selectedPhotos)
                return .handled
            }
            .dropDestination(for: URL.self) { urls, _ in library.addFolders(urls); return true }
        }
    }

    @ViewBuilder
    private func contextMenu(for photo: Photo) -> some View {
        let targets = selection.contains(photo.id) ? selectedPhotos : [photo]
        Button("Afficher dans le Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Button("Ouvrir avec l'application par défaut") {
            targets.forEach { NSWorkspace.shared.open($0.url) }
        }
        Divider()
        Menu("Note") {
            ForEach(0...5, id: \.self) { n in
                Button(n == 0 ? "Aucune" : String(repeating: "★", count: n)) {
                    library.setRating(n, for: targets)
                }
            }
        }
    }

    // MARK: Sélection et clavier

    private var selectedPhotos: [Photo] {
        selection.compactMap { library.photo(id: $0) }
    }

    private func click(_ photo: Photo, in photos: [Photo]) {
        gridFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
            anchor = photo.id
        } else if flags.contains(.shift), let anchor,
                  let a = photos.firstIndex(where: { $0.id == anchor }),
                  let b = photos.firstIndex(where: { $0.id == photo.id }) {
            selection = Set(photos[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [photo.id]
            anchor = photo.id
        }
    }

    private func handleKey(_ key: KeyEquivalent, in photos: [Photo], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !photos.isEmpty else { return .ignored }
        let current = photos.firstIndex { $0.id == anchor && selection.contains($0.id) }
            ?? photos.firstIndex { selection.contains($0.id) }

        var target: Int?
        if key == .leftArrow {
            target = max(0, (current ?? 1) - 1)
        } else if key == .rightArrow {
            target = min(photos.count - 1, (current ?? -1) + 1)
        } else if key == .return || key == .space {
            guard let current else { return .ignored }
            viewerIndex = current
            return .handled
        }
        guard let target else { return .ignored }
        let photo = photos[target]
        selection = [photo.id]
        anchor = photo.id
        proxy.scrollTo(photo.id)
        return .handled
    }

    // MARK: Filtrage

    private func filteredPhotos() -> [Photo] {
        var list = library.photos
        switch sidebar ?? .all {
        case .all: break
        case .starred: list = list.filter { library.rating(of: $0) > 0 }
        case .folder(let path): list = list.filter { $0.folderPath == path }
        case .tag(let tag): list = list.filter { library.tags(of: $0).contains(tag) }
        }
        if minRating > 0 {
            list = list.filter { library.rating(of: $0) >= minRating }
        }
        let tokens = search.searchFolded.split(separator: " ").map(String.init)
        if !tokens.isEmpty {
            list = list.filter { library.matches($0, tokens: tokens) }
        }
        switch sort {
        case .newest: list.sort { $0.date > $1.date }
        case .oldest: list.sort { $0.date < $1.date }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private var title: String {
        switch sidebar ?? .all {
        case .all: return "Toutes les photos"
        case .starred: return "Étoilées"
        case .folder(let path): return (path as NSString).lastPathComponent
        case .tag(let tag): return tag
        }
    }

    private func subtitle(_ photos: [Photo]) -> String {
        let count = "\(photos.count) photo\(photos.count > 1 ? "s" : "")"
        return selection.isEmpty ? count : "\(count) · \(selection.count) sélectionnée\(selection.count > 1 ? "s" : "")"
    }

    // MARK: Barre d'outils

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Slider(value: $thumbSize, in: 80...320) {
                Text("Taille")
            } minimumValueLabel: {
                Image(systemName: "photo").imageScale(.small)
            } maximumValueLabel: {
                Image(systemName: "photo").imageScale(.large)
            }
            .frame(width: 150)
            .help("Taille des miniatures")

            Menu {
                Picker("Trier par", selection: $sort) {
                    ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Note minimale", selection: $minRating) {
                    Text("Toutes les notes").tag(0)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + " et plus").tag(n)
                    }
                }
            } label: {
                Label("Trier et filtrer", systemImage: minRating > 0
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Trier et filtrer")

            Button { library.addFolderWithPanel() } label: {
                Label("Ajouter un dossier", systemImage: "folder.badge.plus")
            }
            .help("Ajouter un dossier (⌘O)")

            Button { library.rescan() } label: {
                Label("Rescanner", systemImage: "arrow.clockwise")
            }
            .help("Rescanner les dossiers (⌘R)")

            Button { showInspector.toggle() } label: {
                Label("Inspecteur", systemImage: "sidebar.trailing")
            }
            .help("Afficher/masquer l'inspecteur")
        }
    }
}

struct PhotoCell: View {
    let photo: Photo
    let size: Double
    let isSelected: Bool
    let rating: Int

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(url: photo.url)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomLeading) {
                    if rating > 0 { StarBadge(rating: rating).padding(4) }
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
            Text(photo.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: size)
        }
        .contentShape(Rectangle())
        .help(photo.name)
    }
}
