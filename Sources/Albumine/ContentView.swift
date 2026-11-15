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
    // Duplicates: list of folder pairs instead of groups, and groups limited to one pair.
    @Etat private var duplicatesByFolder = false
    @Etat private var pairFilter: PhotoLibrary.DuplicateFolderPair?
    // Comparison view: series to go through, starting position, and whether they are similar series.
    @Etat private var compareSeries: [[Photo]]?
    @Etat private var compareStart = 0
    @Etat private var compareIsSimilar = false
    @Etat private var savingSmartAlbum = false
    @Etat private var smartAlbumName = ""
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
        var pairFilter: String?
        var smartAlbums: [SmartAlbum]
    }

    private var filterKey: FilterKey {
        FilterKey(revision: library.revision,
                  metadataRevision: dependsOnMetadata ? library.metadataRevision : 0,
                  analysisRevision: dependsOnAnalysis ? library.analysisRevision &+ library.similarRevision &* 7919 : 0,
                  mapTick: sidebar == .map ? library.exifDone / 2000 : 0,
                  memoryCount: sidebar == .memories ? library.memoryIDs.count : 0,
                  yearFrom: yearFrom, yearTo: yearTo,
                  sidebar: sidebar, search: search, sort: sort, grouping: grouping, minRating: minRating,
                  pairFilter: sidebar == .duplicates ? pairFilter?.id : nil,
                  smartAlbums: isSmart ? library.smartAlbums : [])
    }

    /// The list depends on ratings/tags/people only in some views:
    /// elsewhere, rating a photo recomputes nothing.
    private var isSmart: Bool {
        if case .smart = sidebar ?? .all { return true }
        return false
    }

    private var dependsOnMetadata: Bool {
        if minRating > 0 || !search.isEmpty { return true }
        switch sidebar ?? .all {
        case .starred, .tag, .person, .album, .unnamedFaces, .duplicates, .similar, .rejects, .smart, .discards: return true
        default: return false
        }
    }

    private var dependsOnAnalysis: Bool {
        if !search.isEmpty || grouping == .event { return true }
        switch sidebar ?? .all {
        case .similar, .rejects, .place, .smart: return true
        default: return false
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar, onDropToAlbum: dropToAlbum)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .overlay(alignment: .bottom) {
                    if let notice = library.notice {
                        NoticeToast(text: notice,
                                    undo: library.canUndoTrash && notice == library.undoNotice ? { library.undoLastTrash() } : nil) {
                            library.notice = nil
                        }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice) {
                            // Stays longer when it offers to undo.
                            try? await Task.sleep(for: .seconds(notice == library.undoNotice ? 12 : 7))
                            if !Task.isCancelled, library.notice == notice { library.notice = nil }
                        }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: library.notice)
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
        .overlay {
            if let series = compareSeries {
                CompareView(series: series, start: compareStart, isSeries: compareIsSimilar) { keep, remove in
                    if compareIsSimilar { library.resolveSeries(keep: keep, remove: remove) }
                    else if !remove.isEmpty { library.trash(remove); selection.removeAll() }
                } onClose: { compareSeries = nil; gridFocused = true }
            }
        }
        .alert("Nouvel album intelligent", isPresented: $savingSmartAlbum) {
            TextField("Nom", text: $smartAlbumName)
            Button("Enregistrer") {
                let name = smartAlbumName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                library.saveSmartAlbum(SmartAlbum(name: name, query: search.trimmingCharacters(in: .whitespaces),
                                                  minRating: minRating, yearFrom: yearFrom, yearTo: yearTo))
                search = ""; minRating = 0; yearFrom = nil; yearTo = nil
                sidebar = .smart(name)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La recherche et les filtres actuels sont enregistrés : l'album se met à jour tout seul quand de nouvelles photos correspondent.")
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
        .sheet(isPresented: Binding(get: { Updater.shared.showSheet }, set: { Updater.shared.showSheet = $0 })) {
            UpdateSheet()
        }
        .task { Updater.shared.checkAtLaunch() }
        #if DEBUG
        .task { await debugScenario() }
        #endif
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

    #if DEBUG
    /// Tests: ALBUMINE_SCENARIO opens a given screen and ALBUMINE_SNAPSHOT_DIR receives PNG
    /// captures of the window (drawn by the app itself, no screen recording needed).
    private func debugScenario() async {
        let env = ProcessInfo.processInfo.environment
        guard let scenario = env["ALBUMINE_SCENARIO"], let dir = env["ALBUMINE_SNAPSHOT_DIR"] else { return }
        func snap(_ name: String, wait: Double = 2.5) async {
            try? await Task.sleep(for: .seconds(wait))
            // The frame view includes the title bar and toolbar.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            Debug.log("capture : \(name)")
        }
        while library.isScanning || library.photoCount == 0 { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1))
        let photos = library.byDateNewest
        switch scenario {
        case "dupfolders":
            sidebar = .duplicates
            library.findDuplicates()
            while library.duplicateGroups == nil || library.isFindingDuplicates { try? await Task.sleep(for: .milliseconds(200)) }
            await snap("dup-groups")
            duplicatesByFolder = true
            await snap("dup-folders")
            if let pair = library.duplicateFolderPairs.first(where: { !$0.isInternal }) {
                library.keepFolder(pair.a, in: pair)
                await snap("dup-toast-undo", wait: 2)
            }
        case "reddit":
            if let w = NSApp.windows.first(where: { $0.isVisible }) {
                w.setFrame(NSRect(x: 60, y: 60, width: 1500, height: 940), display: true)
            }
            thumbSize = 150
            grouping = .folder
            while library.isAnalyzingContent { try? await Task.sleep(for: .milliseconds(300)) }
            let all = library.byDateNewest
            library.setRating(5, for: Array(all.filter { $0.folderName == "Mountains 2021" }.prefix(3)))
            library.setRating(4, for: Array(all.filter { $0.folderName == "Seaside 2020" }.prefix(4)))
            library.createAlbum("Best of", with: Array(all.filter { $0.folderName != "Old phone backup" }.prefix(9)))
            library.saveSmartAlbum(SmartAlbum(name: "Snow", query: "neige", minRating: 0))
            library.notice = nil
            sidebar = .all
            try? await Task.sleep(for: .seconds(2))
            if let p = visible.first(where: { $0.folderName == "Mountains 2021" }) { selection = [p.id] }
            await snap("1-grid", wait: 4)
            search = "neige"
            selection = []
            await snap("2-search", wait: 3)
            search = ""
            sidebar = .duplicates
            library.findDuplicates()
            while library.duplicateGroups == nil || library.isFindingDuplicates { try? await Task.sleep(for: .milliseconds(200)) }
            library.notice = nil
            duplicatesByFolder = true
            await snap("3-duplicates-by-folder", wait: 2)
            duplicatesByFolder = false
            sidebar = .similar
            library.findSimilar()
            while library.similarGroups == nil || library.isFindingSimilar { try? await Task.sleep(for: .milliseconds(200)) }
            await snap("4-similar", wait: 3)
            if !(library.similarGroups ?? []).isEmpty { compareSimilar(from: 0) }
            await snap("5-compare", wait: 5)
            compareSeries = nil
            sidebar = .all
            try? await Task.sleep(for: .seconds(1.5))
            if let i = visible.firstIndex(where: { $0.folderName == "Seaside 2020" }) { open(visible, at: i) }
            await snap("6-viewer", wait: 5)
            viewerList = nil
            sidebar = .map
            await snap("7-map", wait: 4)
        case "inspectzero":
            sidebar = .all
            try? await Task.sleep(for: .seconds(1.5))
            if let p = visible.first(where: { $0.name == "zero-exposure.jpg" }) { selection = [p.id] }
            await snap("inspect-zero", wait: 3)
            Debug.log("inspecteur affiché sans plantage")
        case "selviews":
            let all = library.byDateNewest
            library.setRating(3, for: Array(all.prefix(3)))
            for (name, item) in [("memories", SidebarItem.memories), ("all", .all), ("folder", .folder(all[0].folderPath)), ("starred", .starred)] {
                sidebar = item
                try? await Task.sleep(for: .seconds(1.5))
                selection = Set(visible.prefix(2).map(\.id))
                await snap("sel-\(name)", wait: 1.5)
                if name == "memories" {
                    await snap("sel-\(name)-later", wait: 4)
                    thumbSize += 1
                    await snap("sel-\(name)-nudged", wait: 1.5)
                }
                Debug.log("vue \(name) : \(visible.count) affichés, \(selection.count) sélectionnés")
            }
        case "memories":
            sidebar = .memories
            try? await Task.sleep(for: .seconds(2))
            Debug.log("souvenirs : \(visible.count) affichés, \(library.memoryIDs.count) au total")
            await snap("mem-before", wait: 1)
            let victims = Array(visible.prefix(2))
            selection = Set(victims.map(\.id))
            await snap("mem-selected", wait: 1.5)
            photosToTrash = victims
            await snap("mem-confirm", wait: 1.5)
            library.trash(victims)
            photosToTrash = nil
            selection.removeAll()
            while library.isTrashing { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1.5))
            Debug.log("souvenirs après : \(visible.count) affichés, message : \(library.notice ?? "-"), existe encore : \(victims.map { FileManager.default.fileExists(atPath: $0.id) })")
            await snap("mem-after", wait: 1)
        case "trashselect":
            sidebar = .all
            try? await Task.sleep(for: .seconds(2))
            selection = Set(visible.prefix(2).map(\.id))
            await snap("sel-before", wait: 1.5)
            library.trash(Array(visible.prefix(2)))
            selection.removeAll()
            while library.isTrashing { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(2))
            selection = Set([visible[0].id, visible[2].id])
            Debug.log("sélection : \(selection.map { ($0 as NSString).lastPathComponent })")
            await snap("sel-after", wait: 1.5)
        case "compare":
            compareIsSimilar = true
            compareSeries = [Array(photos.prefix(3)), Array(photos.dropFirst(3).prefix(5))]
            await snap("compare-3", wait: 5)
        case "compare5":
            compareIsSimilar = true
            compareSeries = [Array(photos.dropFirst(3).prefix(5))]
            await snap("compare-5", wait: 5)
        case "discards":
            library.setDiscard(Array(photos.prefix(2)), true)
            await snap("grid-discard-badges")
            open(visible, at: 0)
            await snap("viewer-discard", wait: 4)
            viewerList = nil
            sidebar = .discards
            await snap("discards-view")
        case "smart":
            library.setRating(4, for: Array(photos.prefix(3)))
            library.saveSmartAlbum(SmartAlbum(name: "Mes 4 étoiles", query: "", minRating: 4))
            sidebar = .smart("Mes 4 étoiles")
            await snap("smart-album")
            sidebar = .rejects
            await snap("rejects")
        case "faces":
            sidebar = .all
            library.analyzeFaces(in: photos)
            try? await Task.sleep(for: .seconds(2))
            while library.isAnalyzingFaces || library.facePreparing { try? await Task.sleep(for: .milliseconds(300)) }
            library.notice = nil
            sidebar = .unnamedFaces
            await snap("faces-grid")
            library.groupUnknownFaces()
            while library.isGroupingFaces { try? await Task.sleep(for: .milliseconds(300)) }
            await snap("faces-groups", wait: 5)
        default: break
        }
        Debug.log("scénario terminé")
    }
    #endif

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
        } else if item == .unnamedFaces, library.faceGroups != nil || library.isGroupingFaces {
            Group {
                if library.isGroupingFaces {
                    ContentUnavailableView {
                        Label("Regroupement des visages", systemImage: "person.2.crop.square.stack")
                    } description: {
                        VStack(spacing: 8) {
                            ProgressView(value: Double(library.faceGroupDone), total: Double(max(library.faceGroupTotal, 1)))
                                .frame(width: 260)
                            Text("Lecture de \(library.faceGroupDone.formatted()) / \(library.faceGroupTotal.formatted()) visages…")
                        }
                    } actions: {
                        Button("Arrêter") { library.cancelFaceGrouping() }
                    }
                } else {
                    FaceGroupsView { photo in open([photo], at: 0) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { facesBar.padding(.top, 6) }
        } else if item == .duplicates, duplicatesByFolder, !(library.duplicateGroups ?? []).isEmpty {
            DuplicateFoldersView { pair in
                pairFilter = pair
                duplicatesByFolder = false
            }
            .safeAreaInset(edge: .top, spacing: 0) { duplicatesBar.padding(.top, 6) }
        } else if visible.isEmpty, pairFilter != nil, item == .duplicates {
            ContentUnavailableView {
                Label("Plus de doublon entre ces deux dossiers", systemImage: "checkmark.circle")
            } actions: {
                Button("Revenir à la liste des dossiers") { pairFilter = nil; duplicatesByFolder = true }
            }
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
                        if item == .discards { discardsBar }
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
                            // Cells are identified by photo, not by position: after photos are
                            // removed (Trash), position-keyed cells kept a stale selection state.
                            ForEach(group.range.map { (index: $0, photo: photos[$0]) }, id: \.photo.id) { item in
                                cell(item.photo, index: item.index, in: photos)
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
            // ⌘⌫ or ⌫ (as in the Finder and Photos): move the selection to the Trash, after confirmation.
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                let targets = selectedPhotos.filter { !$0.offline }
                guard !targets.isEmpty, !library.isTrashing else { return .ignored }
                photosToTrash = targets
                return .handled
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["ALBUMINE_TRACE_CELLS"] != nil {
            Debug.log("cellule \(photo.name) sélectionnée=\(selection.contains(photo.id)) vue=\(String(describing: sidebar))")
        }
        #endif
        return         PhotoCell(
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
            return library.duplicateKeepers.contains(photo.id) ? L("À garder") : nil
        case .similar:
            return library.similarBest.contains(photo.id) ? L("Meilleure") : nil
        case .unnamedFaces:
            let suggestions = library.faces(of: photo).filter { $0.name == nil }.compactMap(\.suggestion)
            return suggestions.isEmpty ? nil : Set(suggestions).sorted().joined(separator: ", ") + " ?"
        default:
            return library.isDiscarded(photo) ? L("À jeter") : nil
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
        if sidebar == .duplicates || sidebar == .similar {
            seriesMenu(for: photo, targets: targets)
        }
        if sidebar == .duplicates {
            let folder = photo.folderPath
            Toggle("Toujours garder les copies du dossier « \(photo.folderName) »", isOn: Binding(
                get: { library.isPreferredFolder(folder) }, set: { library.setPreferredFolder(folder, $0) }))
            Divider()
        }
        if sidebar == .similar, let i = (library.similarGroups ?? []).firstIndex(where: { $0.contains(photo.id) }) {
            Button("Comparer cette série…") { compareSimilar(from: i) }
        } else if targets.count > 1, targets.count <= 12, !targets.contains(where: \.isVideo) {
            Button("Comparer les \(targets.count) photos…") {
                compareIsSimilar = false
                compareStart = 0
                compareSeries = [targets.sorted { $0.date < $1.date }]
            }
        }
        if targets.contains(where: { !library.isDiscarded($0) }) {
            Button("Marquer « à jeter »") { library.setDiscard(targets, true) }
        } else {
            Button("Ne plus jeter") { library.setDiscard(targets, false) }
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
                Button(n == 0 ? L("Aucune") : String(repeating: "★", count: n)) {
                    library.setRating(n, for: targets)
                }
            }
        }
        Divider()
        Button("Mettre à la corbeille…", role: .destructive) { photosToTrash = targets }
            .keyboardShortcut(.delete, modifiers: .command)
    }

    /// Duplicates and similar photos: keep one photo of the series under the mouse (or of every
    /// series touched by the selection) and send the others to the Trash.
    @ViewBuilder
    private func seriesMenu(for photo: Photo, targets: [Photo]) -> some View {
        let isDup = sidebar == .duplicates
        let groups = isDup ? library.duplicateGroups : library.similarGroups
        let ids = Set(targets.map(\.id))
        let touched = library.series(containing: ids, in: groups)
        let own = touched.first { $0.contains(photo.id) } ?? []
        let isBest = own.first == photo.id
        if touched.count > 1 {
            Button(isDup ? "Garder la copie « À garder » des \(touched.count) groupes sélectionnés"
                         : "Garder la meilleure des \(touched.count) séries sélectionnées") {
                if isDup { library.keepInDuplicates(ids) } else { library.keepInSimilar(ids) }
                selection.removeAll()
            }
        } else if own.count > 1 {
            Button(isDup ? "Garder la copie « À garder » de ce groupe (\(own.count - 1) à la corbeille)"
                         : "Garder la meilleure de cette série (\(own.count - 1) à la corbeille)") {
                if isDup { library.keepInDuplicates([photo.id]) } else { library.keepInSimilar([photo.id]) }
                selection.removeAll()
            }
            if !isBest {
                Button(isDup ? "Garder cette copie, mettre les \(own.count - 1) autres à la corbeille"
                             : "Garder cette photo, mettre les \(own.count - 1) autres à la corbeille") {
                    if isDup { library.keepInDuplicates([photo.id], keep: photo.id) }
                    else { library.keepInSimilar([photo.id], keep: photo.id) }
                    selection.removeAll()
                }
            }
        }
        Divider()
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
            if let pair = pairFilter, !duplicatesByFolder {
                HStack(spacing: 6) {
                    Text(pair.isInternal ? "Seulement : copies à l'intérieur de « \((pair.a as NSString).lastPathComponent) »"
                         : "Seulement : « \((pair.a as NSString).lastPathComponent) » ↔ « \((pair.b as NSString).lastPathComponent) »")
                    Button { pairFilter = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Afficher tous les groupes")
                }
                .font(.caption)
            } else if duplicatesByFolder {
                Text("Dossiers qui contiennent les mêmes fichiers. Gardez un dossier : ses copies restent, celles de l'autre vont à la corbeille. Les fichiers qui ne sont pas en double ne sont jamais touchés.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Dans chaque groupe, la copie « À garder » est conservée (dossier prioritaire, sinon la plus annotée, sinon la plus ancienne). Les autres vont à la corbeille ; leurs notes, personnes et albums sont reportés.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } actions: {
            Picker("", selection: $duplicatesByFolder) {
                Text("Par groupe").tag(false)
                Text("Par dossier").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !library.preferredFolders.isEmpty {
                Menu("Dossiers prioritaires (\(library.preferredFolders.count))") {
                    ForEach(library.preferredFolders, id: \.self) { path in
                        Button("Retirer « \((path as NSString).lastPathComponent) »") { library.setPreferredFolder(path, false) }
                    }
                }
                .fixedSize()
                .help("Les copies de ces dossiers (et de leurs sous-dossiers) sont toujours celles gardées")
            }
            Button("Relancer") { library.findDuplicates() }
            if !duplicatesByFolder, pairFilter == nil {
                Button("Mettre les copies à la corbeille…") { confirmTrashCopies = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(waste.count == 0 || library.isTrashing)
            }
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
            ? L("\(library.contentDone.formatted()) / \(library.contentTotal.formatted()) photos analysées")
            : L("terminée")
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
            Button("Comparer…") { compareSimilar(from: 0) }
                .help("Voir les photos de chaque série côte à côte et choisir au clavier")
        }
        .confirmationDialog("Mettre \(library.similarExtras.formatted()) photos à la corbeille ?", isPresented: $confirmTrashSimilar) {
            Button("Garder la meilleure de chaque série", role: .destructive) { library.trashSimilarExtras() }
        } message: {
            Text("Les autres photos de chaque série vont dans la Corbeille du disque (récupérables). Leurs notes, personnes et albums sont reportés sur la photo gardée.")
        }
    }

    private func compareSimilar(from index: Int) {
        let series = (library.similarGroups ?? []).map { $0.compactMap { library.photo(id: $0) } }
        guard index < series.count else { return }
        compareIsSimilar = true
        compareStart = index
        compareSeries = series
    }

    private var discardsBar: some View {
        Banner(systemImage: "trash") {
            Text("Photos marquées « à jeter »").font(.headline)
            Text("Marquées avec la touche X dans la visionneuse. Elles sont encore sur le disque tant que vous ne les mettez pas à la corbeille.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("Tout garder finalement") { library.setDiscard(visible, false) }
            Button("Mettre les \(visible.count.formatted()) à la corbeille…") { photosToTrash = visible }
                .buttonStyle(.borderedProminent)
                .disabled(library.isTrashing)
        }
    }

    private var rejectsBar: some View {
        Banner(systemImage: "hand.thumbsdown") {
            Text("Photos probablement ratées : floues, trop sombres, surexposées, captures d'écran…").font(.headline)
            Text("Cliquez sur les photos pour les sélectionner (⇧-clic : une plage, ⌘A : tout), puis mettez-les à la corbeille ou « Ce n'est pas raté » pour les retirer de la liste.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            if selection.isEmpty {
                Button("Tout sélectionner") { selection = Set(visible.map(\.id)) }
                    .keyboardShortcut("a", modifiers: .command)
            } else {
                Button("Tout désélectionner") { selection.removeAll() }
                    .keyboardShortcut("a", modifiers: .command)
            }
            Button("Ce n'est pas raté") { library.markQualityOK(selectedPhotos); selection.removeAll() }
                .disabled(selection.isEmpty)
            Button(selection.isEmpty ? "Mettre la sélection à la corbeille…"
                   : L(selection.count, one: "Mettre 1 photo à la corbeille…", other: "Mettre \(selection.count.formatted()) photos à la corbeille…")) { photosToTrash = selectedPhotos }
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
                Text(L(library.memoryIDs.count, one: "Ce jour-là : 1 souvenir", other: "Ce jour-là : \(library.memoryIDs.count.formatted()) souvenirs")).font(.headline)
                Text(library.memoryYears.prefix(6).map { L(now - $0, one: "il y a 1 an (\(String($0)))", other: "il y a \(now - $0) ans (\(String($0)))") }.joined(separator: " · "))
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
        case (nil, nil): return L("Période : toutes")
        case let (f?, t?) where f == t: return L("Période : \(String(f))")
        case let (f?, t?): return L("Période : \(String(f))–\(String(t))")
        case let (f?, nil): return L("Période : depuis \(String(f))")
        case let (nil, t?): return L("Période : jusqu'à \(String(t))")
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
        add(ContentLabels.suggestionNames, "sparkles", limit: 4)
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
            if library.faceGroups != nil {
                Button("Revenir à la grille") { library.closeFaceGroups() }
                Button("Regrouper à nouveau") { library.groupUnknownFaces() }
            } else if !library.isGroupingFaces {
                Button("Regrouper par personne") { library.groupUnknownFaces() }
                    .help("Réunit les visages qui se ressemblent pour les nommer par paquets")
                Button("Confirmer la sélection") { library.acceptSuggestions(in: selectedPhotos) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
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
        } else if sidebar == .rejects {
            // Sorting failed photos: a simple click adds or removes the photo from the selection.
            if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
            anchor = photo.id
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

    private func filter(_ list: [Photo], from yearFrom: Int?, to yearTo: Int?) -> [Photo] {
        guard yearFrom != nil || yearTo != nil else { return list }
        let cal = Calendar.current
        let from = yearFrom.flatMap { cal.date(from: DateComponents(year: $0, month: 1, day: 1)) } ?? .distantPast
        let to = yearTo.flatMap { cal.date(from: DateComponents(year: $0 + 1, month: 1, day: 1)) } ?? .distantFuture
        return list.filter { $0.date >= from && $0.date < to }
    }

    private func computeList() -> ([Photo], [PhotoGroup]) {
        let item = sidebar ?? .all
        if item == .duplicates { return duplicateList() }
        if item == .similar { return idGroups(library.similarGroups ?? [], title: { items in
            L("Série de \(items.count) photos") }) }

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
        case .discards: list = list.filter { library.isDiscarded($0) }
        case .smart(let name):
            if let album = library.smartAlbums.first(where: { $0.name == name }) {
                list = filter(list, from: album.yearFrom, to: album.yearTo)
                if album.minRating > 0 { list = list.filter { library.rating(of: $0) >= album.minRating } }
                let words = album.query.searchFolded.split(separator: " ").map(String.init)
                if !words.isEmpty { list = list.filter { library.matches($0, tokens: words) } }
            } else {
                list = []
            }
        }
        list = filter(list, from: yearFrom, to: yearTo)
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
                let r = library.damageReason(of: p) ?? L("Problème")
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
                return (r.rawValue, r.title, nil)
            }
        }
        if item == .unnamedFaces {
            return group(list) { p in
                let s = library.faces(of: p).first { $0.name == nil }?.suggestion
                return (s ?? "~", s.map { L("Proposé : \($0)") } ?? L("Sans proposition"), nil)
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
            let title = mostCommon(places) ?? mostCommon(items.map(\.folderName)) ?? L("Événement")
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
        let count = L(items.count, one: "1 élément", other: "\(items.count.formatted()) éléments")
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
        let count = L(items.count, one: "1 élément", other: "\(items.count.formatted()) éléments")
        guard let first = items.map(\.date).min(), let last = items.map(\.date).max() else { return count }
        let a = first.formatted(.dateTime.month(.abbreviated).year())
        let b = last.formatted(.dateTime.month(.abbreviated).year())
        return a == b ? "\(count) · \(a)" : "\(count) · \(a) – \(b)"
    }

    private func duplicateList() -> ([Photo], [PhotoGroup]) {
        var list: [Photo] = []
        var groups: [PhotoGroup] = []
        let source = pairFilter.map { library.duplicateGroups(in: $0) } ?? library.duplicateGroups ?? []
        for (n, ids) in source.enumerated() {
            let items = ids.compactMap { library.photo(id: $0) }
            guard items.count > 1 else { continue }
            let start = list.count
            list += items
            groups.append(PhotoGroup(
                id: "dup\(n)", title: items[0].name,
                subtitle: L("\(items.count) copies identiques · \(ByteCountFormatter.string(fromByteCount: items[0].fileSize, countStyle: .file)) chacune"),
                range: start..<list.count))
        }
        return (list, groups)
    }

    private var title: String {
        switch sidebar ?? .all {
        case .all: return L("Toutes les photos")
        case .starred: return L("Étoilées")
        case .folder(let path): return (path as NSString).lastPathComponent
        case .tag(let tag): return tag
        case .person(let name): return name
        case .album(let name): return name
        case .unnamedFaces: return L("Visages à nommer")
        case .videos: return L("Vidéos")
        case .duplicates: return L("Doublons")
        case .map: return L("Carte")
        case .similar: return L("Photos similaires")
        case .rejects: return L("Photos ratées")
        case .place(let name): return name
        case .memories: return L("Souvenirs du jour")
        case .damaged: return L("Fichiers abîmés")
        case .smart(let name): return name
        case .discards: return L("À jeter")
        }
    }

    private var subtitle: String {
        let count = L(visible.count, one: "1 élément", other: "\(visible.count.formatted()) éléments")
        return selection.isEmpty ? count
            : count + " · " + L(selection.count, one: "1 sélectionné", other: "\(selection.count.formatted()) sélectionnés")
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
                    ForEach(PhotoGrouping.allCases) { Text($0.title).tag($0) }
                }
                Picker("Trier par", selection: $sort) {
                    ForEach(PhotoSort.allCases) { Text($0.title).tag($0) }
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
                        Text(String(repeating: "★", count: n) + L(" et plus")).tag(n)
                    }
                }
                Divider()
                Button("Enregistrer comme album intelligent…") { smartAlbumName = search; savingSmartAlbum = true }
                    .disabled(search.trimmingCharacters(in: .whitespaces).isEmpty && minRating == 0 && yearFrom == nil && yearTo == nil)
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
            .background((text == L("À jeter") ? Color.red : Color.green).opacity(0.85), in: Capsule())
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
