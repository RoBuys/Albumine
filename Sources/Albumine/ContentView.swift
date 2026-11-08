import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library

    /// ALBUMINE_START_VIEW=map: opens the map directly (tests).
    @Etat private var sidebar: SidebarItem? = ProcessInfo.processInfo.environment["ALBUMINE_START_VIEW"] == "map" ? .map : .all
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
    // Viewer: displayed list (the grid, or a map cluster) and position.
    @Etat private var viewerList: [Photo]?
    @Etat private var viewerIndex = 0
    // Dialogs
    @Etat private var newAlbumPhotos: [Photo]?
    @Etat private var albumName = ""
    @Etat private var confirmTrashCopies = false
    @Etat private var photosToTrash: [Photo]?
    @Etat private var confirmTrashSimilar = false
    @Etat private var slideshowPhotos: [Photo]?
    @Etat private var exportPhotos: [Photo]?
    @Etat private var locationPhotos: [Photo]?
    @Etat private var dateFixPhotos: [Photo]?
    @Etat private var yearFrom: Int?
    @Etat private var yearTo: Int?
    @Etat private var yearAnchors: [(year: Int, id: String)] = []
    @FocusState private var gridFocused: Bool

    /// Everything that affects the displayed list. It is recomputed only when this changes.
    private struct FilterKey: Equatable {
        var revision: Int
        var metadataRevision: Int
        var analysisRevision: Int
        var mapTick: Int
        var memoryCount: Int
        var yearFrom: Int?
        var yearTo: Int?
        var sidebar: SidebarItem?
        var search: String
        var sort: PhotoSort
        var grouping: PhotoGrouping
        var minRating: Int
    }

    private var filterKey: FilterKey {
        FilterKey(revision: library.revision,
                  metadataRevision: dependsOnMetadata ? library.metadataRevision : 0,
                  analysisRevision: dependsOnAnalysis ? library.analysisRevision &+ library.similarRevision &* 7919 : 0,
                  mapTick: sidebar == .map ? library.exifDone / 2000 : 0,
                  memoryCount: sidebar == .memories ? library.memoryIDs.count : 0,
                  yearFrom: yearFrom, yearTo: yearTo,
                  sidebar: sidebar, search: search, sort: sort, grouping: grouping, minRating: minRating)
    }

    /// The list depends on ratings/tags/people only in some views:
    /// elsewhere, rating a photo recomputes nothing.
    private var dependsOnMetadata: Bool {
        if minRating > 0 || !search.isEmpty { return true }
        switch sidebar ?? .all {
        case .starred, .tag, .person, .album, .unnamedFaces, .duplicates, .similar, .rejects: return true
        default: return false
        }
    }

    private var dependsOnAnalysis: Bool {
        if !search.isEmpty || grouping == .event { return true }
        switch sidebar ?? .all {
        case .similar, .rejects, .place: return true
        default: return false
        }
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
        .searchable(text: $search, placement: .toolbar, prompt: "Personne, lieu, contenu, année, album…")
        .searchSuggestions { searchSuggestions }
        .inspector(isPresented: $showInspector) {
            InspectorView(photos: selectedPhotos)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar { toolbar }
        .onChange(of: sidebar) { selection.removeAll(); anchor = nil }
        .overlay { viewer }
        .overlay {
            if let list = slideshowPhotos {
                SlideshowView(photos: list) { slideshowPhotos = nil; gridFocused = true }
            }
        }
        .sheet(isPresented: Binding(get: { exportPhotos != nil }, set: { if !$0 { exportPhotos = nil } })) {
            ExportSheet(photos: exportPhotos ?? [])
        }
        .sheet(isPresented: Binding(get: { locationPhotos != nil }, set: { if !$0 { locationPhotos = nil } })) {
            LocationPickerSheet(photos: locationPhotos ?? [])
        }
        .sheet(isPresented: Binding(get: { dateFixPhotos != nil }, set: { if !$0 { dateFixPhotos = nil } })) {
            DateFixSheet(photos: dateFixPhotos ?? [])
        }
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
            // Short debounce while typing in the search field.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let start = Date()
            (visible, groups) = computeList()
            yearAnchors = computeYearAnchors(visible)
            Debug.log("liste : \(visible.count) éléments, \(groups.count) groupes en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    // MARK: Viewer

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

    // MARK: Content

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
        } else if item == .similar, library.similarGroups == nil || library.isFindingSimilar {
            similarIntro
        } else if visible.isEmpty {
            emptyState(item)
        } else {
            grid
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        offlineBanner
                        picasaBanner
                        xmpBanner
                        if item == .all { memoriesBanner }
                        if item == .duplicates { duplicatesBar }
                        if item == .unnamedFaces { facesBar }
                        if item == .similar { similarBar }
                        if item == .rejects { rejectsBar }
                        if item == .damaged { damagedBar }
                        if item == .all || item == .rejects || item == .similar { analysisBanner }
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

    // MARK: Grid

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
            .overlay(alignment: .trailing) {
                if yearAnchors.count > 1 {
                    TimelineBar(anchors: yearAnchors) { id in
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .padding(.trailing, 2)
                    .padding(.vertical, 40)
                }
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
            edits: library.edits(of: photo),
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
        case .similar:
            return library.similarBest.contains(photo.id) ? "Meilleure" : nil
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
        if sidebar == .rejects {
            Button("Ce n'est pas raté") { library.markQualityOK(targets) }
        }
        Button("Analyser les visages") { library.analyzeFaces(in: targets) }
        Divider()
        Button("Diaporama") { startSlideshow(targets.count > 1 ? targets : visible, from: photo) }
        Button("Exporter…") { exportPhotos = targets }
        Divider()
        Button("Corriger la date…") { dateFixPhotos = targets }
        Menu("Lieu") {
            Button("Définir le lieu…") { locationPhotos = targets }
            Button("D'après les photos prises juste avant ou après") { library.fillLocationsFromNeighbors(targets) }
            if targets.contains(where: { library.hasManualLocation($0) }) {
                Button("Retirer le lieu ajouté") { library.setLocation(targets.filter { library.hasManualLocation($0) }, latitude: nil, longitude: nil) }
            }
        }
        if targets.contains(where: { library.edits(of: $0) != nil }) {
            Button("Annuler les retouches") { targets.forEach { library.setEdits(nil, for: $0) } }
        }
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
        // Dragging a selected photo drags the whole selection.
        let expanded = ids.count == 1 && selection.contains(ids[0]) ? Array(selection) : ids
        library.addPhotos(expanded.compactMap { library.photo(id: $0) }, toAlbum: album)
    }

    // MARK: Banners

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

    private var similarIntro: some View {
        ContentUnavailableView {
            Label("Photos similaires", systemImage: "square.stack.3d.down.right")
        } description: {
            if library.isFindingSimilar {
                ProgressView("Comparaison des photos…")
            } else {
                Text("Rafales, prises successives et versions redimensionnées d'une même photo. Nécessite l'analyse du contenu (\(analysisProgressText)).")
            }
        } actions: {
            if !library.isFindingSimilar {
                Button("Rechercher les photos similaires") { library.findSimilar() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var analysisProgressText: String {
        library.isAnalyzingContent
            ? "\(library.contentDone.formatted()) / \(library.contentTotal.formatted()) photos analysées"
            : "terminée"
    }

    private var similarBar: some View {
        Banner(systemImage: "square.stack.3d.down.right") {
            Text("\((library.similarGroups ?? []).count.formatted()) séries · \(library.similarExtras.formatted()) photos en plus de la meilleure")
                .font(.headline)
            Text("« Meilleure » = la plus réussie selon l'analyse (netteté, composition) et vos annotations. Vérifiez avant de trier.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Relancer") { library.findSimilar() }
            Button("Garder la meilleure de chaque série…") { confirmTrashSimilar = true }
                .buttonStyle(.borderedProminent)
                .disabled(library.similarExtras == 0 || library.isTrashing)
        }
        .confirmationDialog("Mettre \(library.similarExtras.formatted()) photos à la corbeille ?", isPresented: $confirmTrashSimilar) {
            Button("Garder la meilleure de chaque série", role: .destructive) { library.trashSimilarExtras() }
        } message: {
            Text("Les autres photos de chaque série vont dans la Corbeille du disque (récupérables). Leurs notes, personnes et albums sont reportés sur la photo gardée.")
        }
    }

    private var rejectsBar: some View {
        Banner(systemImage: "hand.thumbsdown") {
            Text("Photos probablement ratées : floues, trop sombres, surexposées, captures d'écran…").font(.headline)
            Text("Sélectionnez puis mettez à la corbeille, ou « Ce n'est pas raté » pour les retirer de cette liste.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Ce n'est pas raté") { library.markQualityOK(selectedPhotos); selection.removeAll() }
                .disabled(selection.isEmpty)
            Button("Mettre la sélection à la corbeille…") { photosToTrash = selectedPhotos }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
        }
    }

    @ViewBuilder
    private var analysisBanner: some View {
        if library.isAnalyzingContent || library.contentPaused {
            Banner(systemImage: "sparkles") {
                Text(library.contentPaused ? "Analyse du contenu en pause"
                     : "Analyse du contenu : \(library.contentDone.formatted()) / \(library.contentTotal.formatted())")
                    .font(.headline)
                Text("Permet la recherche par contenu (« plage », « neige », « chien »…), les photos similaires et les photos ratées. Tout reste sur votre Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } actions: {
                Button(library.contentPaused ? "Reprendre" : "Pause") { library.toggleContentPause() }
            }
        }
    }

    // MARK: Disconnected drive, XMP, memories

    private var damagedBar: some View {
        Banner(systemImage: "exclamationmark.triangle") {
            Text("Fichiers vides, tronqués ou illisibles").font(.headline)
            Text("Souvent récupérables depuis une autre copie (sauvegarde, téléphone, carte mémoire). Clic droit › Afficher dans le Finder pour les remplacer.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Vérifier à nouveau") { library.checkIntegrity() }
                .disabled(library.isCheckingIntegrity)
        }
    }

    @ViewBuilder
    private var offlineBanner: some View {
        if !library.offlineRoots.isEmpty {
            Banner(systemImage: "externaldrive.badge.xmark") {
                Text("Disque débranché : \(library.offlineRoots.map { $0.pathComponents.count > 2 ? $0.pathComponents[2] : $0.lastPathComponent }.joined(separator: ", "))")
                    .font(.headline)
                Text("\(library.offlineCount.formatted()) éléments affichés depuis le cache (miniatures, recherche, carte). Rebranchez le disque pour ouvrir les originaux ; Albumine le détecte automatiquement.")
                    .font(.caption).foregroundStyle(.secondary)
            } actions: {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var xmpBanner: some View {
        if library.sidecarCount > 0, !library.xmpImported {
            Banner(systemImage: "doc.badge.gearshape") {
                Text("\(library.sidecarCount.formatted()) fichiers XMP trouvés (Mylio, Lightroom…)").font(.headline)
                Text("Notes, personnes et visages, légendes et lieux peuvent être repris. Vos fichiers ne sont pas modifiés.")
                    .font(.caption).foregroundStyle(.secondary)
            } actions: {
                Button("Plus tard") { library.dismissXMPBanner() }
                Button("Importer") { library.importSidecars() }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.isImportingXMP)
            }
        }
    }

    @ViewBuilder
    private var memoriesBanner: some View {
        if !library.memoryIDs.isEmpty, search.isEmpty {
            let now = Calendar.current.component(.year, from: Date())
            Banner(systemImage: "clock.arrow.circlepath") {
                Text("Ce jour-là : \(library.memoryIDs.count.formatted()) souvenir\(library.memoryIDs.count > 1 ? "s" : "")").font(.headline)
                Text(library.memoryYears.prefix(6).map { "il y a \(now - $0) ans (\(String($0)))" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } actions: {
                Button("Diaporama") {
                    startSlideshow(library.byDateNewest.filter { library.memoryIDs.contains($0.id) }.reversed())
                }
                Button("Voir") { sidebar = .memories }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Timeline

    private var availableYears: [Int] {
        guard let newest = library.byDateNewest.first?.date, let oldest = library.byDateNewest.last?.date else { return [] }
        let cal = Calendar.current
        let a = max(cal.component(.year, from: oldest), 1990), b = cal.component(.year, from: newest)
        return a <= b ? Array((a...b).reversed()) : []
    }

    private var periodLabel: String {
        switch (yearFrom, yearTo) {
        case (nil, nil): return "Période : toutes"
        case let (f?, t?) where f == t: return "Période : \(String(f))"
        case let (f?, t?): return "Période : \(String(f))–\(String(t))"
        case let (f?, nil): return "Période : depuis \(String(f))"
        case let (nil, t?): return "Période : jusqu'à \(String(t))"
        }
    }

    /// First item of each year (date-sorted lists only), by binary search.
    private func computeYearAnchors(_ list: [Photo]) -> [(year: Int, id: String)] {
        guard sort != .name, grouping != .folder, list.count > 50,
              ![.duplicates, .similar, .rejects, .unnamedFaces, .map].contains(sidebar ?? .all),
              let first = list.first?.date, let last = list.last?.date else { return [] }
        let cal = Calendar.current
        let ascending = first <= last
        let y1 = cal.component(.year, from: first), y2 = cal.component(.year, from: last)
        let years = Array(min(y1, y2)...max(y1, y2))
        var anchors: [(year: Int, id: String)] = []
        for y in ascending ? years : years.reversed() {
            guard let start = cal.date(from: DateComponents(year: y)),
                  let end = cal.date(from: DateComponents(year: y + 1)) else { continue }
            // First index whose date falls within the year (in list order).
            var lo = 0, hi = list.count
            while lo < hi {
                let mid = (lo + hi) / 2
                let before = ascending ? list[mid].date < start : list[mid].date >= end
                if before { lo = mid + 1 } else { hi = mid }
            }
            if lo < list.count, list[lo].date >= start, list[lo].date < end { anchors.append((y, list[lo].id)) }
        }
        return anchors
    }

    // MARK: Search suggestions

    @ViewBuilder
    private var searchSuggestions: some View {
        let tokens = search.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let last = (tokens.last ?? "").searchFolded
        if last.count >= 2 {
            let prefix = tokens.dropLast().joined(separator: " ")
            let items = suggestions(for: last)
            ForEach(items, id: \.text) { item in
                Label(item.text, systemImage: item.icon)
                    .searchCompletion((prefix.isEmpty ? "" : prefix + " ") + item.text + " ")
            }
        }
    }

    private func suggestions(for token: String) -> [(text: String, icon: String)] {
        var out: [(String, String)] = []
        func add(_ values: [String], _ icon: String, limit: Int) {
            let matches = values.filter { $0.searchFolded.hasPrefix(token) || $0.searchFolded.contains(" " + token) }
            out += matches.prefix(limit).map { ($0, icon) }
        }
        add(library.allPeople.map(\.name), "person.crop.circle", limit: 4)
        add(library.allPlaces.map(\.name), "mappin.and.ellipse", limit: 3)
        add(library.allAlbums.map(\.name), "rectangle.stack", limit: 2)
        add(library.allTags.map(\.name), "tag", limit: 2)
        add(Array(Set(ContentLabels.names.values)).sorted(), "sparkles", limit: 4)
        add(availableYears.map(String.init), "calendar", limit: 3)
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }.prefix(10).map { (text: $0.0, icon: $0.1) }
    }

    private func startSlideshow(_ list: [Photo], from photo: Photo? = nil) {
        let images = list.filter { !$0.isVideo }
        guard !images.isEmpty else { return }
        if let photo, let i = images.firstIndex(of: photo) {
            slideshowPhotos = Array(images[i...] + images[..<i])
        } else {
            slideshowPhotos = images
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

    // MARK: Selection and keyboard

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

    // MARK: Filtering and grouping

    private func computeList() -> ([Photo], [PhotoGroup]) {
        let item = sidebar ?? .all
        if item == .duplicates { return duplicateList() }
        if item == .similar { return idGroups(library.similarGroups ?? [], title: { items in
            "Série de \(items.count) photos" }) }

        // List already sorted by date (sorted once by the library).
        var list = sort == .oldest ? Array(library.byDateNewest.reversed()) : library.byDateNewest
        switch item {
        case .all, .duplicates: break
        case .starred: list = list.filter { library.rating(of: $0) > 0 }
        case .folder(let path): list = list.filter { $0.folderPath == path }
        case .tag(let tag): list = list.filter { library.tags(of: $0).contains(tag) }
        case .person(let name): list = list.filter { library.people(of: $0).contains(name) }
        case .album(let name): list = list.filter { library.albums(of: $0).contains(name) }
        case .unnamedFaces: list = list.filter { library.faces(of: $0).contains { $0.name == nil } }
        case .videos: list = list.filter(\.isVideo)
        case .map: list = library.photos.filter(\.hasLocation)
        case .similar: break
        case .rejects: list = list.filter { library.rejectReason(of: $0) != nil }
        case .place(let name): list = list.filter { library.placeName(of: $0) == name }
        case .memories: list = list.filter { library.memoryIDs.contains($0.id) }
        case .damaged: list = library.photos.filter { library.damageReason(of: $0) != nil }
        }
        if yearFrom != nil || yearTo != nil {
            let cal = Calendar.current
            let from = yearFrom.flatMap { cal.date(from: DateComponents(year: $0, month: 1, day: 1)) } ?? .distantPast
            let to = yearTo.flatMap { cal.date(from: DateComponents(year: $0 + 1, month: 1, day: 1)) } ?? .distantFuture
            list = list.filter { $0.date >= from && $0.date < to }
        }
        if minRating > 0 {
            list = list.filter { library.rating(of: $0) >= minRating }
        }
        let tokens = search.searchFolded.split(separator: " ").map(String.init)
        if !tokens.isEmpty {
            list = list.filter { library.matches($0, tokens: tokens) }
        }
        if sort == .name {
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if item == .map { return (list, []) }
        if item == .damaged {
            return group(list) { p in
                let r = library.damageReason(of: p) ?? "Problème"
                return (r, r, nil)
            }
        }
        if item == .memories {
            let thisYear = Calendar.current.component(.year, from: Date())
            return group(list) { p in
                let y = Calendar.current.component(.year, from: p.date)
                let n = thisYear - y
                return (String(y), "Il y a \(n) an\(n > 1 ? "s" : "") · \(y)", nil)
            }
        }
        if item == .rejects {
            return group(list) { p in
                let r = library.rejectReason(of: p) ?? .poor
                return (r.rawValue, r.rawValue, nil)
            }
        }
        if item == .unnamedFaces {
            return group(list) { p in
                let s = library.faces(of: p).first { $0.name == nil }?.suggestion
                return (s ?? "~", s.map { "Proposé : \($0)" } ?? "Sans proposition", nil)
            }
        }

        // A single folder view needs no folder header.
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
        case .event:
            return eventGroups(sort == .name ? library.byDateNewest.filter { Set(list.map(\.id)).contains($0.id) } : list)
        }
    }

    /// Events: a break when more than 6 h separate two photos,
    /// or more than 1 h and 40 km. Title = most frequent place, otherwise folder.
    private func eventGroups(_ list: [Photo]) -> ([Photo], [PhotoGroup]) {
        var groups: [PhotoGroup] = []
        var start = 0
        func close(_ end: Int) {
            guard end > start else { return }
            let items = Array(list[start..<end])
            let places = items.compactMap { library.placeName(of: $0) }
            let title = mostCommon(places) ?? mostCommon(items.map(\.folderName)) ?? "Événement"
            groups.append(PhotoGroup(id: "ev\(start)-\(items[0].id)", title: title,
                                     subtitle: eventSubtitle(items), range: start..<end,
                                     folderPath: places.isEmpty ? items[0].folderPath : nil))
            start = end
        }
        for i in list.indices.dropFirst() {
            let a = list[i - 1], b = list[i]
            let gap = abs(a.date.timeIntervalSince(b.date))
            var far = false
            if let la = a.latitude, let lo = a.longitude, let lb = b.latitude, let lob = b.longitude {
                far = abs(la - lb) + abs(lo - lob) > 0.4 // ≈ 40 km
            }
            if gap > 6 * 3600 || (gap > 3600 && far) { close(i) }
        }
        close(list.count)
        return (list, groups)
    }

    private func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    private func eventSubtitle(_ items: [Photo]) -> String {
        let count = "\(items.count.formatted()) élément\(items.count > 1 ? "s" : "")"
        guard let first = items.map(\.date).min(), let last = items.map(\.date).max() else { return count }
        let sameDay = Calendar.current.isDate(first, inSameDayAs: last)
        let a = first.formatted(.dateTime.day().month(.abbreviated).year())
        let b = last.formatted(.dateTime.day().month(.abbreviated).year())
        return sameDay ? "\(count) · \(a)" : "\(count) · \(a) – \(b)"
    }

    /// Sections built from groups of identifiers (similar photos…).
    private func idGroups(_ idGroups: [[String]], title: ([Photo]) -> String) -> ([Photo], [PhotoGroup]) {
        var list: [Photo] = []
        var groups: [PhotoGroup] = []
        for (n, ids) in idGroups.enumerated() {
            let items = ids.compactMap { library.photo(id: $0) }
            guard items.count > 1 else { continue }
            let start = list.count
            list += items
            groups.append(PhotoGroup(id: "g\(n)-\(items[0].id)", title: title(items),
                                     subtitle: eventSubtitle(items), range: start..<list.count,
                                     folderPath: items[0].folderPath))
        }
        return (list, groups)
    }

    /// Splits a sorted list into contiguous sections, in order of first appearance.
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
        case .similar: return "Photos similaires"
        case .rejects: return "Photos ratées"
        case .place(let name): return name
        case .memories: return "Souvenirs du jour"
        case .damaged: return "Fichiers abîmés"
        }
    }

    private var subtitle: String {
        let count = "\(visible.count.formatted()) élément\(visible.count > 1 ? "s" : "")"
        return selection.isEmpty ? count : "\(count) · \(selection.count.formatted()) sélectionné\(selection.count > 1 ? "s" : "")"
    }

    // MARK: Toolbar

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
                Menu(periodLabel) {
                    Button("Toutes les années") { yearFrom = nil; yearTo = nil }
                    Divider()
                    Menu("Depuis") {
                        ForEach(availableYears, id: \.self) { y in Button(String(y)) { yearFrom = y; if let t = yearTo, t < y { yearTo = y } } }
                    }
                    Menu("Jusqu'à") {
                        ForEach(availableYears, id: \.self) { y in Button(String(y)) { yearTo = y; if let f = yearFrom, f > y { yearFrom = y } } }
                    }
                    Divider()
                    ForEach(availableYears.prefix(30), id: \.self) { y in
                        Button("Seulement \(String(y))") { yearFrom = y; yearTo = y }
                    }
                }
                Picker("Note minimale", selection: $minRating) {
                    Text("Toutes les notes").tag(0)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + " et plus").tag(n)
                    }
                }
            } label: {
                Label("Regrouper, trier et filtrer", systemImage: minRating > 0 || yearFrom != nil || yearTo != nil
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

            Button { startSlideshow(selection.count > 1 ? selectedPhotos.sorted { $0.date < $1.date } : visible) } label: {
                Label("Diaporama", systemImage: "play.rectangle")
            }
            .help("Diaporama de la sélection (ou de la vue)")
            .disabled(visible.isEmpty || sidebar == .map)

            Button { exportPhotos = selectedPhotos } label: {
                Label("Exporter", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Exporter la sélection (redimensionnée) vers un dossier")
            .disabled(selection.isEmpty)

            ShareLink(items: selectedPhotos.map(\.url)) {
                Label("Partager", systemImage: "square.and.arrow.up")
            }
            .help("Partager la sélection (Mail, Messages, AirDrop…)")
            .disabled(selection.isEmpty)

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

/// Section header (folder, month, year…), pinned to the top while scrolling.
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

/// Information banner above the grid.
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
    var edits: PhotoEdits? = nil
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(url: photo.url, rotation: rotation, edits: edits)
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
                .overlay(alignment: .topLeading) {
                    if photo.offline {
                        Image(systemName: "externaldrive.badge.xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding(5)
                            .help("Disque débranché : miniature en cache")
                    } else if edits.map({ !$0.isIdentity }) == true {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(4)
                            .help("Retouchée")
                    }
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

/// Small label at the top right of a thumbnail (e.g. "À garder" / keep, in duplicates).
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

/// Year timeline on the right edge of the grid: a click jumps to that year.
struct TimelineBar: View {
    let anchors: [(year: Int, id: String)]
    let onSelect: (String) -> Void
    @Etat private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let step = max(1, Int(ceil(Double(anchors.count) * 16 / max(geo.size.height, 1))))
            VStack(spacing: 0) {
                ForEach(Array(anchors.enumerated()), id: \.offset) { i, a in
                    if i % step == 0 {
                        Button { onSelect(a.id) } label: {
                            Text(String(a.year))
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .frame(maxHeight: .infinity)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .help("Aller en \(String(a.year))")
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.vertical, 4)
            .background(.regularMaterial.opacity(hovering ? 1 : 0.6), in: Capsule())
            .opacity(hovering ? 1 : 0.75)
            .onHover { hovering = $0 }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 40)
    }
}
