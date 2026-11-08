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
    @Etat private var grouping: PhotoGrouping = .folder
    @Etat private var minRating = 0
    @Etat private var showInspector = true
    @Etat private var visible: [Photo] = []
    @Etat private var groups: [PhotoGroup] = []
    // Visionneuse : liste affichée (la grille, ou un groupe de la carte) et position.
    @Etat private var viewerList: [Photo]?
    @Etat private var viewerIndex = 0
    // Dialogues
    @Etat private var newAlbumPhotos: [Photo]?
    @Etat private var albumName = ""
    @Etat private var confirmTrashCopies = false
    @Etat private var photosToTrash: [Photo]?
    @FocusState private var gridFocused: Bool

    /// Tout ce qui influence la liste affichée. Elle n'est recalculée que si ceci change.
    private struct FilterKey: Equatable {
        var revision: Int
        var sidebar: SidebarItem?
        var search: String
        var sort: PhotoSort
        var grouping: PhotoGrouping
        var minRating: Int
    }

    private var filterKey: FilterKey {
        FilterKey(revision: library.revision, sidebar: sidebar, search: search, sort: sort,
                  grouping: grouping, minRating: minRating)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar, onDropToAlbum: dropToAlbum)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .alert("Albumine", isPresented: Binding(get: { library.notice != nil },
                                                        set: { if !$0 { library.notice = nil } })) {
                    Button("OK") { library.notice = nil }
                } message: {
                    Text(library.notice ?? "")
                }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Nom, dossier, personne, album, appareil, année")
        .inspector(isPresented: $showInspector) {
            InspectorView(photos: selectedPhotos)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar { toolbar }
        .onChange(of: sidebar) { selection.removeAll(); anchor = nil }
        .overlay { viewer }
        .animation(.easeInOut(duration: 0.15), value: viewerList == nil)
        .alert(
            "Import Picasa terminé",
            isPresented: Binding(get: { library.picasaSummary != nil },
                                 set: { if !$0 { library.picasaSummary = nil } })
        ) {
            Button("OK") { library.picasaSummary = nil }
        } message: {
            Text(library.picasaSummary?.message ?? "")
        }
        .task(id: filterKey) {
            // Petite temporisation pendant la frappe dans la recherche.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let start = Date()
            (visible, groups) = computeList()
            Debug.log("liste : \(visible.count) éléments, \(groups.count) groupes en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    // MARK: Visionneuse

    @ViewBuilder
    private var viewer: some View {
        if let list = viewerList, !list.isEmpty {
            ViewerView(
                photos: list,
                index: Binding(
                    get: { min(viewerIndex, list.count - 1) },
                    set: { newValue in
                        viewerIndex = newValue
                        selection = [list[newValue].id]
                        anchor = list[newValue].id
                    }
                ),
                onClose: { viewerList = nil; gridFocused = true }
            )
            .transition(.opacity)
        }
    }

    private func open(_ list: [Photo], at index: Int) {
        viewerIndex = index
        viewerList = list
    }

    // MARK: Contenu

    @ViewBuilder
    private var detail: some View {
        let item = sidebar ?? .all
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
        } else if item == .map {
            PhotoMapView(photos: visible, selection: $selection, onOpen: open)
        } else if item == .duplicates, library.duplicateGroups == nil || library.isFindingDuplicates {
            duplicatesIntro
        } else if visible.isEmpty {
            emptyState(item)
        } else {
            grid
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        picasaBanner
                        if item == .duplicates { duplicatesBar }
                        if item == .unnamedFaces { facesBar }
                    }
                }
        }
    }

    @ViewBuilder
    private func emptyState(_ item: SidebarItem) -> some View {
        if library.isScanning || (library.photoCount > 0 && search.isEmpty && minRating == 0 && item == .all) {
            ProgressView("Analyse des dossiers…")
        } else if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if item == .duplicates {
            ContentUnavailableView("Aucun doublon", systemImage: "checkmark.circle",
                                   description: Text("Aucune copie identique n'a été trouvée."))
        } else if item == .unnamedFaces {
            ContentUnavailableView {
                Label("Aucun visage à nommer", systemImage: "person.crop.circle.badge.checkmark")
            } description: {
                Text("Lancez « Analyser les visages » (barre d'outils) sur un dossier ou un album pour détecter de nouveaux visages.")
            }
        } else if case .album = item {
            ContentUnavailableView("Album vide", systemImage: "rectangle.stack",
                                   description: Text("Glissez des photos sur l'album dans la barre latérale, ou clic droit › Ajouter à l'album."))
        } else {
            ContentUnavailableView("Aucune photo", systemImage: "photo",
                                   description: Text("Rien à afficher ici pour l'instant."))
        }
    }

    // MARK: Grille

    private var grid: some View {
        let photos = visible
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.3), spacing: 10)],
                    spacing: 10,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.range, id: \.self) { i in
                                cell(photos[i], index: i, in: photos)
                            }
                        } header: {
                            GroupHeader(group: group) {
                                selection = Set(photos[group.range].map(\.id))
                                gridFocused = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
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
            .alert("Nouvel album", isPresented: Binding(get: { newAlbumPhotos != nil },
                                                        set: { if !$0 { newAlbumPhotos = nil } })) {
                TextField("Nom de l'album", text: $albumName)
                Button("Créer") {
                    library.createAlbum(albumName, with: newAlbumPhotos ?? [])
                    newAlbumPhotos = nil
                    albumName = ""
                }
                Button("Annuler", role: .cancel) { newAlbumPhotos = nil }
            } message: {
                Text("\(newAlbumPhotos?.count ?? 0) élément(s) y seront ajoutés. Les fichiers ne sont pas copiés.")
            }
            .confirmationDialog(
                "Mettre \(photosToTrash?.count ?? 0) élément(s) à la corbeille ?",
                isPresented: Binding(get: { photosToTrash != nil }, set: { if !$0 { photosToTrash = nil } })
            ) {
                Button("Mettre à la corbeille", role: .destructive) {
                    library.trash(photosToTrash ?? [])
                    selection.removeAll()
                    photosToTrash = nil
                }
            } message: {
                Text("Les fichiers iront dans la Corbeille du disque : vous pourrez les récupérer tant qu'elle n'est pas vidée.")
            }
        }
    }

    private func cell(_ photo: Photo, index: Int, in photos: [Photo]) -> some View {
        PhotoCell(
            photo: photo,
            size: thumbSize,
            isSelected: selection.contains(photo.id),
            rating: library.rating(of: photo),
            rotation: library.rotation(of: photo),
            badge: badge(for: photo)
        )
        .id(photo.id)
        .gesture(TapGesture(count: 2).onEnded { open(photos, at: index) })
        .simultaneousGesture(TapGesture().onEnded { click(photo, in: photos) })
        .draggable(photo.id)
        .contextMenu { contextMenu(for: photo) }
    }

    private func badge(for photo: Photo) -> String? {
        switch sidebar ?? .all {
        case .duplicates:
            return library.duplicateKeepers.contains(photo.id) ? "À garder" : nil
        case .unnamedFaces:
            let suggestions = library.faces(of: photo).filter { $0.name == nil }.compactMap(\.suggestion)
            return suggestions.isEmpty ? nil : Set(suggestions).sorted().joined(separator: ", ") + " ?"
        default:
            return nil
        }
    }

    @ViewBuilder
    private func contextMenu(for photo: Photo) -> some View {
        let targets = selection.contains(photo.id) ? selectedPhotos : [photo]
        Button("Ouvrir") { open(visible, at: visible.firstIndex(of: photo) ?? 0) }
        Button("Afficher dans le Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Button("Ouvrir avec l'application par défaut") {
            targets.forEach { NSWorkspace.shared.open($0.url) }
        }
        Divider()
        Menu("Ajouter à l'album") {
            ForEach(library.albumNames, id: \.self) { name in
                Button(name) { library.addPhotos(targets, toAlbum: name) }
            }
            if !library.albumNames.isEmpty { Divider() }
            Button("Nouvel album…") { newAlbumPhotos = targets }
        }
        if case .album(let name) = sidebar ?? .all {
            Button("Retirer de l'album « \(name) »") { library.removePhotos(targets, fromAlbum: name) }
        }
        if sidebar == .unnamedFaces {
            Button("Confirmer les noms proposés") { library.acceptSuggestions(in: targets) }
        }
        Button("Analyser les visages") { library.analyzeFaces(in: targets) }
        Divider()
        Button("Pivoter à droite") { library.rotate(targets, by: 1) }
        Button("Pivoter à gauche") { library.rotate(targets, by: -1) }
        Menu("Note") {
            ForEach(0...5, id: \.self) { n in
                Button(n == 0 ? "Aucune" : String(repeating: "★", count: n)) {
                    library.setRating(n, for: targets)
                }
            }
        }
        Divider()
        Button("Mettre à la corbeille…", role: .destructive) { photosToTrash = targets }
    }

    private func dropToAlbum(_ album: String, _ ids: [String]) {
        // Glisser une photo de la sélection = glisser toute la sélection.
        let expanded = ids.count == 1 && selection.contains(ids[0]) ? Array(selection) : ids
        library.addPhotos(expanded.compactMap { library.photo(id: $0) }, toAlbum: album)
    }

    // MARK: Bandeaux

    @ViewBuilder
    private var picasaBanner: some View {
        if library.picasaFilesFound > 0, !library.picasaImported {
            Banner(systemImage: "square.and.arrow.down.on.square") {
                Text("Données Picasa trouvées dans \(library.picasaFilesFound) dossiers").font(.headline)
                Text("Personnes, albums, étoiles, rotations et légendes peuvent être repris. Vos fichiers ne sont pas modifiés.")
                    .font(.caption).foregroundStyle(.secondary)
            } actions: {
                Button("Plus tard") { library.dismissPicasaBanner() }
                Button("Importer") { library.importPicasa() }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.isImportingPicasa)
            }
        }
    }

    private var duplicatesIntro: some View {
        ContentUnavailableView {
            Label("Doublons", systemImage: "square.on.square")
        } description: {
            if library.isFindingDuplicates {
                VStack(spacing: 8) {
                    ProgressView(value: Double(library.duplicateDone), total: Double(max(library.duplicateTotal, 1)))
                        .frame(width: 260)
                    Text("Comparaison de \(library.duplicateDone.formatted()) / \(library.duplicateTotal.formatted()) fichiers de même taille…")
                }
            } else {
                Text("Recherche les copies identiques (même contenu, quel que soit le nom ou le dossier). Rien n'est supprimé sans votre accord.")
            }
        } actions: {
            if !library.isFindingDuplicates {
                Button("Rechercher les doublons") { library.findDuplicates() }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.isScanning)
            }
        }
    }

    private var duplicatesBar: some View {
        let waste = library.duplicateWaste
        return Banner(systemImage: "square.on.square") {
            Text("\(library.duplicateGroups?.count ?? 0) groupes · \(waste.count.formatted()) copies en trop (\(ByteCountFormatter.string(fromByteCount: waste.bytes, countStyle: .file)))")
                .font(.headline)
            Text("Dans chaque groupe, la copie « À garder » est conservée (la plus annotée, sinon la plus ancienne). Les autres vont à la corbeille ; leurs notes, personnes et albums sont reportés.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Relancer") { library.findDuplicates() }
            Button("Mettre les copies à la corbeille…") { confirmTrashCopies = true }
                .buttonStyle(.borderedProminent)
                .disabled(waste.count == 0 || library.isTrashing)
        }
        .confirmationDialog("Mettre \(waste.count.formatted()) copies à la corbeille ?", isPresented: $confirmTrashCopies) {
            Button("Mettre les copies à la corbeille", role: .destructive) { library.trashDuplicateCopies() }
        } message: {
            Text("Chaque copie est d'abord comparée octet par octet à celle gardée. Les fichiers restent récupérables dans la Corbeille du disque.")
        }
    }

    private var facesBar: some View {
        Banner(systemImage: "person.crop.circle.badge.questionmark") {
            Text("Les noms proposés (« Prénom ? ») sont des suggestions à vérifier").font(.headline)
            Text("Sélectionnez des photos puis confirmez, ou nommez chaque visage dans l'inspecteur. Touche F dans la visionneuse : voir les cadres.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Confirmer la sélection") { library.acceptSuggestions(in: selectedPhotos) }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
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
            open(photos, at: current)
            return .handled
        }
        guard let target else { return .ignored }
        let photo = photos[target]
        selection = [photo.id]
        anchor = photo.id
        proxy.scrollTo(photo.id)
        return .handled
    }

    // MARK: Filtrage et regroupement

    private func computeList() -> ([Photo], [PhotoGroup]) {
        let item = sidebar ?? .all
        if item == .duplicates { return duplicateList() }

        var list = library.photos
        switch item {
        case .all, .duplicates: break
        case .starred: list = list.filter { library.rating(of: $0) > 0 }
        case .folder(let path): list = list.filter { $0.folderPath == path }
        case .tag(let tag): list = list.filter { library.tags(of: $0).contains(tag) }
        case .person(let name): list = list.filter { library.people(of: $0).contains(name) }
        case .album(let name): list = list.filter { library.albums(of: $0).contains(name) }
        case .unnamedFaces: list = list.filter { library.faces(of: $0).contains { $0.name == nil } }
        case .videos: list = list.filter(\.isVideo)
        case .map: list = list.filter(\.hasLocation)
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
        if item == .map { return (list, []) }
        if item == .unnamedFaces {
            return group(list) { p in
                let s = library.faces(of: p).first { $0.name == nil }?.suggestion
                return (s ?? "~", s.map { "Proposé : \($0)" } ?? "Sans proposition", nil)
            }
        }

        // Un dossier affiché seul n'a pas besoin d'en-tête de dossier.
        let effective: PhotoGrouping = {
            if case .folder = item, grouping == .folder { return .none }
            return grouping
        }()
        let calendar = Calendar.current
        switch effective {
        case .none:
            return (list, [PhotoGroup(id: "all", title: "", subtitle: "", range: 0..<list.count)])
        case .folder:
            return group(list) { p in (p.folderPath, p.folderName, p.folderPath) }
        case .month:
            return group(list) { p in
                let c = calendar.dateComponents([.year, .month], from: p.date)
                let key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
                return (key, p.date.formatted(.dateTime.month(.wide).year()).capitalized, nil)
            }
        case .year:
            return group(list) { p in
                let y = String(calendar.component(.year, from: p.date))
                return (y, y, nil)
            }
        }
    }

    /// Découpe une liste triée en sections contiguës, dans l'ordre de première apparition.
    private func group(_ list: [Photo], by key: (Photo) -> (key: String, title: String, folder: String?)) -> ([Photo], [PhotoGroup]) {
        var order: [String] = []
        var buckets: [String: [Photo]] = [:]
        var info: [String: (String, String?)] = [:]
        for p in list {
            let k = key(p)
            if buckets[k.key] == nil {
                order.append(k.key)
                info[k.key] = (k.title, k.folder)
            }
            buckets[k.key, default: []].append(p)
        }
        var flat: [Photo] = []
        flat.reserveCapacity(list.count)
        var groups: [PhotoGroup] = []
        for k in order {
            let items = buckets[k]!
            let start = flat.count
            flat += items
            groups.append(PhotoGroup(id: k, title: info[k]!.0, subtitle: groupSubtitle(items),
                                     range: start..<flat.count, folderPath: info[k]!.1))
        }
        return (flat, groups)
    }

    private func groupSubtitle(_ items: [Photo]) -> String {
        let count = "\(items.count.formatted()) élément\(items.count > 1 ? "s" : "")"
        guard let first = items.map(\.date).min(), let last = items.map(\.date).max() else { return count }
        let a = first.formatted(.dateTime.month(.abbreviated).year())
        let b = last.formatted(.dateTime.month(.abbreviated).year())
        return a == b ? "\(count) · \(a)" : "\(count) · \(a) – \(b)"
    }

    private func duplicateList() -> ([Photo], [PhotoGroup]) {
        var list: [Photo] = []
        var groups: [PhotoGroup] = []
        for (n, ids) in (library.duplicateGroups ?? []).enumerated() {
            let items = ids.compactMap { library.photo(id: $0) }
            guard items.count > 1 else { continue }
            let start = list.count
            list += items
            groups.append(PhotoGroup(
                id: "dup\(n)", title: items[0].name,
                subtitle: "\(items.count) copies identiques · \(ByteCountFormatter.string(fromByteCount: items[0].fileSize, countStyle: .file)) chacune",
                range: start..<list.count))
        }
        return (list, groups)
    }

    private var title: String {
        switch sidebar ?? .all {
        case .all: return "Toutes les photos"
        case .starred: return "Étoilées"
        case .folder(let path): return (path as NSString).lastPathComponent
        case .tag(let tag): return tag
        case .person(let name): return name
        case .album(let name): return name
        case .unnamedFaces: return "Visages à nommer"
        case .videos: return "Vidéos"
        case .duplicates: return "Doublons"
        case .map: return "Carte"
        }
    }

    private var subtitle: String {
        let count = "\(visible.count.formatted()) élément\(visible.count > 1 ? "s" : "")"
        return selection.isEmpty ? count : "\(count) · \(selection.count.formatted()) sélectionné\(selection.count > 1 ? "s" : "")"
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
            .frame(width: 140)
            .help("Taille des miniatures")

            Menu {
                Picker("Regrouper", selection: $grouping) {
                    ForEach(PhotoGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
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
                Label("Regrouper, trier et filtrer", systemImage: minRating > 0
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Regrouper, trier et filtrer")

            if library.isAnalyzingFaces || library.facePreparing {
                Button { library.cancelFaceAnalysis() } label: {
                    Label("Arrêter l'analyse des visages", systemImage: "stop.circle")
                }
                .help("Arrêter l'analyse des visages")
            } else {
                Button { library.analyzeFaces(in: visible) } label: {
                    Label("Analyser les visages", systemImage: "person.crop.rectangle.stack")
                }
                .help("Détecter et reconnaître les visages des photos affichées")
                .disabled(visible.isEmpty || sidebar == .map)
            }

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

/// En-tête de section (dossier, mois, année…), épinglé en haut pendant le défilement.
struct GroupHeader: View {
    let group: PhotoGroup
    let onSelectAll: () -> Void

    var body: some View {
        if group.title.isEmpty {
            Color.clear.frame(height: 10)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.title).font(.headline).lineLimit(1)
                Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let folder = group.folderPath {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(folder)
                }
                Button("Tout sélectionner", action: onSelectAll)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(.bar)
        }
    }
}

/// Bandeau d'information au-dessus de la grille.
struct Banner<Content: View, Actions: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) { content }
            Spacer()
            actions
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct PhotoCell: View {
    let photo: Photo
    let size: Double
    let isSelected: Bool
    let rating: Int
    let rotation: Int
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(url: photo.url, rotation: rotation)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomLeading) {
                    if rating > 0 { StarBadge(rating: rating).padding(4) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge { CellBadge(text: badge).padding(4) }
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

/// Petite étiquette en haut à droite d'une miniature (ex. « À garder » dans les doublons).
struct CellBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.85), in: Capsule())
    }
}
