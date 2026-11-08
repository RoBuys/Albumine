import SwiftUI
import AppKit

/// Bibliothèque : dossiers sources surveillés, photos trouvées, notes et étiquettes.
/// - library.json : dossiers suivis, notes, étiquettes
/// - index.json   : index des fichiers + EXIF (pour redémarrer sans tout relire)
@MainActor
@Observable
final class PhotoLibrary {
    private(set) var roots: [URL] = []
    /// Toutes les photos. Modifié par lots pendant la lecture des EXIF :
    /// évitez de le lire dans un `body` (préférez `revision`, `photoCount`, `photo(id:)`).
    private(set) var photos: [Photo] = []
    private(set) var isScanning = false
    /// Avancement de la lecture des EXIF en arrière-plan.
    private(set) var exifDone = 0
    private(set) var exifTotal = 0
    /// Incrémenté quand l'ensemble des photos (ou leur ordre) change.
    private(set) var revision = 0
    /// Incrémenté quand des notes, étiquettes, personnes… changent.
    private(set) var metadataRevision = 0
    /// Toutes les photos, de la plus récente à la plus ancienne (tri fait une seule fois).
    @ObservationIgnored private(set) var byDateNewest: [Photo] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // Données dérivées, recalculées seulement quand c'est nécessaire.
    private(set) var photoCount = 0
    private(set) var folders: [FolderSummary] = []
    private(set) var allTags: [(name: String, count: Int)] = []
    private(set) var starredCount = 0
    private(set) var allPeople: [(name: String, count: Int)] = []
    private(set) var allAlbums: [(name: String, count: Int)] = []

    // Albums virtuels (liste conservée même quand un album est vide)
    private(set) var albumNames: [String] = []

    // Compteurs pour la barre latérale
    private(set) var videoCount = 0
    private(set) var locatedCount = 0
    private(set) var unnamedFaceCount = 0

    // Doublons
    private(set) var duplicateGroups: [[String]]?
    private(set) var duplicateKeepers: Set<String> = []
    private(set) var isFindingDuplicates = false
    private(set) var isTrashing = false
    private(set) var duplicateDone = 0
    private(set) var duplicateTotal = 0
    /// Message à afficher (fin d'une opération longue).
    var notice: String?

    // Visages
    private(set) var faceDone = 0
    private(set) var faceTotal = 0
    private(set) var facePreparing = false
    @ObservationIgnored private var faceTask: Task<Void, Never>?
    @ObservationIgnored private var faceRefs: FaceReferences?

    // Analyse du contenu (catégories, qualité, empreinte) — analysis.json
    @ObservationIgnored private(set) var analysis: [String: AnalysisEntry] = [:]
    private(set) var analysisRevision = 0
    private(set) var contentDone = 0
    private(set) var contentTotal = 0
    private(set) var contentPaused = UserDefaults.standard.bool(forKey: "contentPaused")
    private(set) var rejectCount = 0
    @ObservationIgnored private var contentTask: Task<Void, Never>?

    // Photos similaires (calculées à la demande)
    private(set) var similarGroups: [[String]]?
    private(set) var similarBest: Set<String> = []
    private(set) var similarRevision = 0
    private(set) var isFindingSimilar = false

    // Lieux — places.json
    @ObservationIgnored private(set) var places: [String: Place] = [:]
    private(set) var allPlaces: [(name: String, count: Int)] = []
    private(set) var placeDone = 0
    private(set) var placeTotal = 0
    @ObservationIgnored private var placeTask: Task<Void, Never>?

    // Import Picasa
    private(set) var picasaFilesFound = 0
    private(set) var picasaImported = false
    private(set) var isImportingPicasa = false
    var picasaSummary: PicasaImportSummary?

    private var metadata: [String: PhotoMetadata] = [:]
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var exifTask: Task<Void, Never>?

    @ObservationIgnored private let storeURL = AppPaths.support.appendingPathComponent("library.json")

    private struct Store: Codable {
        var roots: [String]
        var metadata: [String: PhotoMetadata]
        var picasaImported: Bool?
        var albums: [String]?
    }

    init() {
        load()
        Task {
            let (a, p) = await Task.detached(priority: .userInitiated) { (AnalysisStore.load(), PlaceStore.load()) }.value
            analysis = a
            places = p
            recomputeAnalysisDerived()
            recomputePlaces()
            rescan()
        }
    }

    var isAnalyzingContent: Bool { contentTotal > 0 && contentDone < contentTotal }
    var isFindingPlaces: Bool { placeTotal > 0 && placeDone < placeTotal }

    var isReadingExif: Bool { exifTotal > 0 && exifDone < exifTotal }

    func photo(id: String) -> Photo? { indexByID[id].map { photos[$0] } }

    // MARK: Dossiers

    func addFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        panel.message = "Choisissez les dossiers qui contiennent vos photos"
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }

    func addFolders(_ urls: [URL]) {
        var changed = false
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let folder = url.standardizedFileURL
            if root(containing: folder.path) != nil { continue }
            roots.removeAll { $0.path.hasPrefix(folder.path + "/") }
            roots.append(folder)
            changed = true
        }
        if changed {
            roots.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            save()
            rescan()
        }
    }

    func removeRoot(_ root: URL) {
        roots.removeAll { $0.path == root.path }
        save()
        rescan()
    }

    func root(containing path: String) -> URL? {
        roots.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    // MARK: Analyse

    func rescan() {
        let roots = self.roots
        scanGeneration += 1
        let generation = scanGeneration
        exifTask?.cancel()
        exifDone = 0
        exifTotal = 0
        isScanning = true
        Task {
            let start = Date()
            let result = await Task.detached(priority: .userInitiated) { () -> ScanResult in
                PhotoScanner.scan(roots, index: IndexStore.load())
            }.value
            guard generation == scanGeneration else { return }
            Debug.log("scan: \(result.photos.count) photos, \(result.pending.count) EXIF à lire, \(Date().timeIntervalSince(start)) s")
            setPhotos(result.photos)
            isScanning = false
            if ProcessInfo.processInfo.environment["ALBUMINE_AUTOIMPORT"] != nil { importPicasa() } // tests
            if result.pending.isEmpty {
                saveIndex()
                afterExifPass()
            } else {
                startExifPass(result.pending, generation: generation)
            }
        }
    }

    private func setPhotos(_ newPhotos: [Photo]) {
        photos = newPhotos
        photoCount = newPhotos.count
        var map: [String: Int] = [:]
        map.reserveCapacity(newPhotos.count)
        for (i, p) in newPhotos.enumerated() { map[p.id] = i }
        indexByID = map
        recomputeFolders()
        recomputeCounts()
        recomputeMetadataDerived()
        resort()
        revision += 1
        detectPicasaFiles()
    }

    /// Lit les EXIF manquants par lots, en laissant la priorité aux miniatures.
    private func startExifPass(_ pending: [Int], generation: Int) {
        let urls = pending.map { photos[$0].url }
        exifTotal = pending.count
        exifDone = 0
        exifTask = Task {
            let chunk = 128
            var start = 0
            var lastSave = 0
            while start < pending.count {
                // Pause tant que des miniatures sont en cours de chargement.
                while !(await ImageLoader.limiter.isIdle) {
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                }
                if Task.isCancelled || generation != scanGeneration { return }
                let end = min(start + chunk, pending.count)
                let batch = Array(urls[start..<end])
                let results = await Task.detached(priority: .utility) { PhotoScanner.readExif(batch) }.value
                if Task.isCancelled || generation != scanGeneration { return }
                for (offset, r) in results.enumerated() {
                    let i = pending[start + offset]
                    photos[i].captureDate = r.date
                    photos[i].camera = r.camera
                    photos[i].orientation = r.orientation
                    photos[i].latitude = r.latitude
                    photos[i].longitude = r.longitude
                    photos[i].exifChecked = true
                }
                exifDone = end
                start = end
                if exifDone - lastSave >= 5000 {
                    lastSave = exifDone
                    saveIndex()
                }
            }
            Debug.log("EXIF terminés")
            saveIndex()
            recomputeFolders()
            recomputeCounts()
            resort()
            revision += 1 // re-trie une seule fois avec les vraies dates
            afterExifPass()
        }
    }

    /// Appelé quand toutes les dates et coordonnées sont lues.
    private func afterExifPass() {
        startContentPass()
        startPlacePass()
    }

    private func saveIndex() {
        let snapshot = photos
        Task.detached(priority: .background) { IndexStore.save(snapshot) }
    }

    private func recomputeFolders() {
        var groups: [String: (count: Int, latest: Date)] = [:]
        for p in photos {
            let g = groups[p.folderPath]
            groups[p.folderPath] = ((g?.count ?? 0) + 1, max(g?.latest ?? .distantPast, p.date))
        }
        folders = groups
            .map { FolderSummary(path: $0.key, name: ($0.key as NSString).lastPathComponent,
                                 count: $0.value.count, latest: $0.value.latest) }
            .sorted { $0.latest > $1.latest }
    }

    private func resort() {
        byDateNewest = photos.sorted { $0.date > $1.date }
    }

    private func recomputeCounts() {
        videoCount = photos.reduce(0) { $0 + ($1.isVideo ? 1 : 0) }
        locatedCount = photos.reduce(0) { $0 + ($1.hasLocation ? 1 : 0) }
    }

    private func recomputeMetadataDerived() {
        var tagCounts: [String: Int] = [:]
        var peopleCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = Dictionary(uniqueKeysWithValues: albumNames.map { ($0, 0) })
        var starred = 0
        var unnamed = 0
        for (path, m) in metadata where indexByID[path] != nil {
            if m.rating > 0 { starred += 1 }
            if m.hasUnnamedFaces { unnamed += 1 }
            for t in m.tags { tagCounts[t, default: 0] += 1 }
            for p in m.people { peopleCounts[p, default: 0] += 1 }
            for a in m.albums { albumCounts[a, default: 0] += 1 }
        }
        func sorted(_ counts: [String: Int]) -> [(name: String, count: Int)] {
            counts.map { (name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        starredCount = starred
        unnamedFaceCount = unnamed
        allTags = sorted(tagCounts)
        allPeople = sorted(peopleCounts)
        allAlbums = sorted(albumCounts)
    }

    // MARK: Notes et étiquettes

    func rating(of photo: Photo) -> Int { metadata[photo.id]?.rating ?? 0 }
    func tags(of photo: Photo) -> [String] { metadata[photo.id]?.tags ?? [] }
    func people(of photo: Photo) -> [String] { metadata[photo.id]?.people ?? [] }
    func albums(of photo: Photo) -> [String] { metadata[photo.id]?.albums ?? [] }
    func caption(of photo: Photo) -> String { metadata[photo.id]?.caption ?? "" }
    func rotation(of photo: Photo) -> Int { metadata[photo.id]?.rotation ?? 0 }
    func faces(of photo: Photo) -> [FaceRegion] { metadata[photo.id]?.faces ?? [] }

    /// Zone d'un visage dans l'image orientée selon l'EXIF, sans la rotation d'affichage.
    /// (Les visages Picasa sont exprimés dans l'image brute du capteur : on les convertit.)
    func faceRect(_ face: FaceRegion, in photo: Photo) -> CGRect {
        face.raw == true ? FaceGeometry.applyOrientation(face.rect, photo.orientation) : face.rect
    }

    /// Pivote l'affichage d'un quart de tour (+1 horaire, -1 antihoraire). Le fichier n'est pas modifié.
    func rotate(_ photos: [Photo], by quarterTurns: Int) {
        for p in photos {
            let r = ((metadata[p.id]?.rotation ?? 0) + quarterTurns) % 4
            metadata[p.id, default: PhotoMetadata()].rotation = (r + 4) % 4
        }
        metadataChanged()
    }

    func setCaption(_ caption: String, for photo: Photo) {
        metadata[photo.id, default: PhotoMetadata()].caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        metadataChanged()
    }

    func removePerson(_ name: String, from photos: [Photo]) {
        for p in photos {
            metadata[p.id]?.people.removeAll { $0 == name }
            if let faces = metadata[p.id]?.faces {
                metadata[p.id]?.faces = faces.map { var f = $0; if f.name == name { f.name = nil }; return f }
            }
        }
        metadataChanged()
    }

    func setRating(_ rating: Int, for photos: [Photo]) {
        let value = min(max(rating, 0), 5)
        for p in photos { metadata[p.id, default: PhotoMetadata()].rating = value }
        metadataChanged()
    }

    func addTag(_ raw: String, to photos: [Photo]) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        let canonical = allTags.first { $0.name.caseInsensitiveCompare(tag) == .orderedSame }?.name ?? tag
        for p in photos {
            var m = metadata[p.id, default: PhotoMetadata()]
            if !m.tags.contains(canonical) {
                m.tags.append(canonical)
                m.tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            metadata[p.id] = m
        }
        metadataChanged()
    }

    func removeTag(_ tag: String, from photos: [Photo]) {
        for p in photos { metadata[p.id]?.tags.removeAll { $0 == tag } }
        metadataChanged()
    }

    private func metadataChanged() {
        scheduleSave()
        recomputeMetadataDerived()
        metadataRevision += 1
    }

    /// Enregistrement différé et hors du fil principal : l'interface ne se bloque plus.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// La photo correspond-elle à tous les mots recherchés (déjà normalisés) ?
    func matches(_ photo: Photo, tokens: [String]) -> Bool {
        var extra: String?
        return tokens.allSatisfy { token in
            if photo.searchKey.contains(token) { return true }
            if extra == nil {
                let year = String(Calendar.current.component(.year, from: photo.date))
                let m = metadata[photo.id]
                var text = ([photo.camera ?? "", year, m?.caption ?? ""] + (m?.tags ?? []) + (m?.people ?? []) + (m?.albums ?? []))
                    .joined(separator: " ").searchFolded
                for label in analysis[photo.id]?.l ?? [] { text += " " + ContentLabels.searchText(label) }
                if let place = place(of: photo) { text += " " + place.searchText }
                extra = text
            }
            return extra!.contains(token)
        }
    }

    // MARK: Import Picasa

    private var allFolders: [String] { folders.map(\.path) + roots.map(\.path) }

    private func detectPicasaFiles() {
        let folders = allFolders
        Task {
            picasaFilesFound = await Task.detached(priority: .utility) { PicasaImporter.iniFiles(in: folders).count }.value
        }
    }

    func dismissPicasaBanner() {
        picasaImported = true
        save()
    }

    /// Fusionne les données Picasa sans rien écraser : on ajoute personnes, albums, étoiles,
    /// et on reprend rotation et légende seulement si elles ne sont pas déjà définies.
    func importPicasa() {
        guard !isImportingPicasa else { return }
        isImportingPicasa = true
        let folders = allFolders
        Task {
            let start = Date()
            let (fileCount, imported) = await Task.detached(priority: .userInitiated) { () -> (Int, [String: PicasaImporter.Imported]) in
                let files = PicasaImporter.iniFiles(in: folders)
                return (files.count, PicasaImporter.load(files))
            }.value

            // Index insensible à la casse (Picasa a parfois une autre casse que le disque).
            var lowercased: [String: String] = [:]
            for p in photos { lowercased[p.id.lowercased()] = p.id }

            var summary = PicasaImportSummary(files: fileCount)
            for (path, imp) in imported {
                guard let id = indexByID[path] != nil ? path : lowercased[path.lowercased()] else { continue }
                var m = metadata[id] ?? PhotoMetadata()
                let before = m
                if imp.star, m.rating < 5 { m.rating = 5; summary.stars += 1 }
                if imp.rotation != 0, m.rotation == 0 { m.rotation = imp.rotation; summary.rotations += 1 }
                if let c = imp.caption, m.caption.isEmpty { m.caption = c; summary.captions += 1 }
                for name in imp.people where !m.people.contains(name) { m.people.append(name) }
                for album in imp.albums where !m.albums.contains(album) { m.albums.append(album) }
                // Remplace les visages d'un import précédent (pas ceux détectés ou nommés dans Albumine).
                let fromPicasaOnly = !m.facesAnalyzed && m.faces.allSatisfy { $0.suggestion == nil && $0.score == nil }
                if m.faces.isEmpty || (fromPicasaOnly && m.faces != imp.faces) { m.faces = imp.faces }
                m.people.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                summary.namedFaces += imp.faces.filter { $0.name != nil }.count
                summary.people.formUnion(imp.people)
                summary.albums.formUnion(imp.albums)
                if m != before {
                    metadata[id] = m
                    summary.photos += 1
                }
            }
            for album in summary.albums where !albumNames.contains(album) { albumNames.append(album) }
            albumNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            Debug.log("import Picasa : \(fileCount) fichiers, \(imported.count) entrées, \(summary.photos) photos, \(Date().timeIntervalSince(start)) s")
            picasaImported = true
            metadataChanged()
            isImportingPicasa = false
            picasaSummary = summary
        }
    }

    // MARK: Albums virtuels

    /// Crée un album (éventuellement avec des photos). Une photo peut être dans plusieurs albums,
    /// sans être copiée.
    func createAlbum(_ raw: String, with photos: [Photo] = []) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !albumNames.contains(name) {
            albumNames.append(name)
            albumNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if photos.isEmpty { metadataChanged() } else { addPhotos(photos, toAlbum: name) }
    }

    func addPhotos(_ photos: [Photo], toAlbum name: String) {
        if !albumNames.contains(name) { albumNames.append(name) }
        for p in photos where !(metadata[p.id]?.albums.contains(name) ?? false) {
            metadata[p.id, default: PhotoMetadata()].albums.append(name)
        }
        metadataChanged()
    }

    func removePhotos(_ photos: [Photo], fromAlbum name: String) {
        for p in photos { metadata[p.id]?.albums.removeAll { $0 == name } }
        metadataChanged()
    }

    func renameAlbum(_ old: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        albumNames.removeAll { $0 == old }
        if !albumNames.contains(name) { albumNames.append(name) }
        albumNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        for key in metadata.keys where metadata[key]!.albums.contains(old) {
            var albums = metadata[key]!.albums.map { $0 == old ? name : $0 }
            albums = albums.enumerated().filter { albums.firstIndex(of: $0.element) == $0.offset }.map(\.element)
            metadata[key]!.albums = albums
        }
        metadataChanged()
    }

    /// Supprime l'album ; les photos ne sont pas touchées.
    func deleteAlbum(_ name: String) {
        albumNames.removeAll { $0 == name }
        for key in metadata.keys where metadata[key]!.albums.contains(name) {
            metadata[key]!.albums.removeAll { $0 == name }
        }
        metadataChanged()
    }

    // MARK: Doublons

    func findDuplicates() {
        guard !isFindingDuplicates else { return }
        let candidates = DuplicateFinder.sameSizeCandidates(photos)
        let items = candidates.map { (id: $0.id, url: $0.url, size: $0.fileSize) }
        let generation = scanGeneration
        isFindingDuplicates = true
        duplicateDone = 0
        duplicateTotal = items.count
        Task {
            var byHash: [String: [String]] = [:]
            var start = 0
            while start < items.count {
                while !(await ImageLoader.limiter.isIdle) { try? await Task.sleep(for: .milliseconds(150)) }
                guard generation == scanGeneration else { isFindingDuplicates = false; return }
                let end = min(start + 64, items.count)
                let batch = Array(items[start..<end])
                let results = await Task.detached(priority: .utility) { DuplicateFinder.hashes(batch) }.value
                for r in results { if let h = r.hash { byHash[h, default: []].append(r.id) } }
                start = end
                duplicateDone = end
            }
            setDuplicateGroups(byHash.values.filter { $0.count > 1 }.map { $0.sorted(by: keeperFirst) })
            isFindingDuplicates = false
            let waste = duplicateWaste
            notice = waste.count == 0
                ? "Aucun doublon trouvé."
                : "\(duplicateGroups?.count ?? 0) groupes de doublons : \(waste.count) copies en trop (\(ByteCountFormatter.string(fromByteCount: waste.bytes, countStyle: .file)))."
        }
    }

    private func setDuplicateGroups(_ groups: [[String]]) {
        duplicateGroups = groups.sorted {
            (photo(id: $0[0])?.fileSize ?? 0) * Int64($0.count) > (photo(id: $1[0])?.fileSize ?? 0) * Int64($1.count)
        }
        duplicateKeepers = Set(groups.compactMap(\.first))
        revision += 1
    }

    /// Ordre de préférence de la copie à garder : la plus annotée, puis la plus ancienne, puis le chemin le plus court.
    private func keeperFirst(_ a: String, _ b: String) -> Bool {
        let ra = metadata[a]?.richness ?? 0, rb = metadata[b]?.richness ?? 0
        if ra != rb { return ra > rb }
        let da = photo(id: a)?.modificationDate ?? .distantFuture, db = photo(id: b)?.modificationDate ?? .distantFuture
        if da != db { return da < db }
        return a.count < b.count
    }

    var duplicateWaste: (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for g in duplicateGroups ?? [] {
            for id in g.dropFirst() { count += 1; bytes += photo(id: id)?.fileSize ?? 0 }
        }
        return (count, bytes)
    }

    /// Met à la corbeille toutes les copies (récupérables depuis la Corbeille du disque).
    /// Chaque copie est d'abord comparée octet par octet à la photo gardée ; ses notes,
    /// étiquettes, personnes et albums sont reportés sur la photo gardée.
    func trashDuplicateCopies() {
        guard let groups = duplicateGroups, !isTrashing else { return }
        let plan: [(keep: URL, keepID: String, copies: [(id: String, url: URL)])] = groups.compactMap { g in
            guard let keep = photo(id: g[0]) else { return nil }
            return (keep.url, keep.id, g.dropFirst().compactMap { id in photo(id: id).map { (id, $0.url) } })
        }
        isTrashing = true
        Task {
            let trashed = await Task.detached(priority: .userInitiated) { () -> [(kept: String, copy: String, size: Int64)] in
                var done: [(String, String, Int64)] = []
                for g in plan {
                    for c in g.copies where DuplicateFinder.identical(g.keep, c.url) {
                        let size = (try? c.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                        if (try? FileManager.default.trashItem(at: c.url, resultingItemURL: nil)) != nil {
                            done.append((g.keepID, c.id, Int64(size)))
                        }
                    }
                }
                return done
            }.value
            for t in trashed {
                if let m = metadata[t.copy] {
                    metadata[t.kept, default: PhotoMetadata()].merge(m)
                    metadata[t.copy] = nil
                }
            }
            let removed = Set(trashed.map(\.copy))
            removeFromLibrary(removed)
            setDuplicateGroups(groups.map { $0.filter { !removed.contains($0) } }.filter { $0.count > 1 })
            isTrashing = false
            let bytes = trashed.reduce(Int64(0)) { $0 + $1.size }
            let skipped = plan.reduce(0) { $0 + $1.copies.count } - trashed.count
            notice = "\(trashed.count) copies mises à la corbeille (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) libérés)."
                + (skipped > 0 ? " \(skipped) fichiers gardés : contenu différent ou corbeille indisponible." : "")
            metadataChanged()
        }
    }

    /// Met des photos à la corbeille (récupérables).
    func trash(_ photos: [Photo]) {
        let urls = photos.map { ($0.id, $0.url) }
        Task {
            let done = await Task.detached { urls.filter { (try? FileManager.default.trashItem(at: $0.1, resultingItemURL: nil)) != nil }.map(\.0) }.value
            for id in done { metadata[id] = nil }
            removeFromLibrary(Set(done))
            if done.count < urls.count { notice = "\(urls.count - done.count) fichiers n'ont pas pu être mis à la corbeille." }
            metadataChanged()
        }
    }

    /// Retire des photos de la liste sans relire le disque (la lecture des EXIF reprend ensuite).
    private func removeFromLibrary(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        exifTask?.cancel()
        scanGeneration += 1
        setPhotos(photos.filter { !ids.contains($0.id) })
        let pending = photos.indices.filter { !photos[$0].exifChecked }
        if !pending.isEmpty { startExifPass(pending, generation: scanGeneration) }
    }

    // MARK: Visages

    var isAnalyzingFaces: Bool { faceTotal > 0 && faceDone < faceTotal }

    func cancelFaceAnalysis() {
        faceTask?.cancel()
    }

    /// Détecte les visages des photos de la liste qui n'ont pas encore été analysées,
    /// et propose un nom à partir des visages déjà nommés.
    func analyzeFaces(in list: [Photo]) {
        guard !isAnalyzingFaces, !facePreparing else { return }
        let targets = list.filter { p in
            guard !p.isVideo else { return false }
            let m = metadata[p.id]
            return !(m?.facesAnalyzed ?? false) && (m?.faces.isEmpty ?? true)
        }
        guard !targets.isEmpty else {
            notice = "Les visages de ces photos ont déjà été analysés."
            return
        }
        let items = targets.map { (id: $0.id, url: $0.url, rotation: rotation(of: $0)) }

        // Exemples : pour chaque personne, ses plus grands visages nommés.
        var examples: [String: [(url: URL, rotation: Int, rect: CGRect)]] = [:]
        for (path, m) in metadata where indexByID[path] != nil {
            guard let p = photo(id: path), !p.isVideo else { continue }
            for f in m.faces where f.w >= 0.05 { if let n = f.name { examples[n, default: []].append((p.url, m.rotation, faceRect(f, in: p))) } }
        }
        for (n, list) in examples {
            examples[n] = Array(list.sorted { $0.rect.width > $1.rect.width }.prefix(FaceReferences.samplesPerPerson * 3).shuffled()
                .prefix(FaceReferences.samplesPerPerson))
        }

        facePreparing = true
        faceTask = Task {
            let refs: FaceReferences
            if let r = faceRefs { refs = r } else { refs = await Task.detached { FaceReferences.load() }.value }
            faceRefs = refs
            let missing = examples.filter { !refs.people.contains($0.key) }
            if !missing.isEmpty {
                await Task.detached(priority: .utility) {
                    for (name, list) in missing {
                        for e in list {
                            if let fp = FaceEngine.referencePrint(url: e.url, rotation: e.rotation, rect: e.rect) { refs.add(fp, for: name) }
                        }
                    }
                    refs.save()
                }.value
            }
            facePreparing = false
            faceTotal = items.count
            faceDone = 0
            var found = 0, suggested = 0
            var start = 0
            while start < items.count, !Task.isCancelled {
                while !(await ImageLoader.limiter.isIdle) { try? await Task.sleep(for: .milliseconds(150)) }
                let end = min(start + 6, items.count)
                let batch = Array(items[start..<end])
                let results = await Task.detached(priority: .utility) {
                    batch.map { (id: $0.id, faces: FaceEngine.analyze(url: $0.url, rotation: $0.rotation, references: refs)) }
                }.value
                for r in results {
                    var m = metadata[r.id] ?? PhotoMetadata()
                    m.faces = r.faces
                    m.facesAnalyzed = true
                    metadata[r.id] = m
                    found += r.faces.count
                    suggested += r.faces.filter { $0.suggestion != nil }.count
                }
                faceDone = end
                start = end
                if start % 300 < 6 { save() }
            }
            faceTotal = 0
            faceDone = 0
            metadataChanged()
            notice = "Analyse des visages\(Task.isCancelled ? " interrompue" : " terminée") : \(found) visages trouvés, \(suggested) noms proposés. Ils sont dans « Visages à nommer »."
        }
    }

    /// Donne un nom à un visage (et l'ajoute aux exemples de cette personne).
    func nameFace(_ photo: Photo, at index: Int, as raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var m = metadata[photo.id], m.faces.indices.contains(index) else { return }
        m.faces[index].name = name
        m.faces[index].suggestion = nil
        m.faces[index].score = nil
        if !m.people.contains(name) {
            m.people.append(name)
            m.people.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        metadata[photo.id] = m
        metadataChanged()
        let (url, rotation, rect) = (photo.url, m.rotation, faceRect(m.faces[index], in: photo))
        Task.detached(priority: .utility) { [faceRefs] in
            guard let refs = faceRefs, let fp = FaceEngine.referencePrint(url: url, rotation: rotation, rect: rect) else { return }
            refs.add(fp, for: name)
            refs.save()
        }
    }

    func acceptSuggestions(in photos: [Photo]) {
        for p in photos {
            for (i, f) in faces(of: p).enumerated() where f.name == nil {
                if let s = f.suggestion { nameFace(p, at: i, as: s) }
            }
        }
    }

    /// Retire un visage (fausse détection) ; la personne n'est retirée que si plus aucun visage ne la porte.
    func removeFace(_ photo: Photo, at index: Int) {
        guard var m = metadata[photo.id], m.faces.indices.contains(index) else { return }
        let removed = m.faces.remove(at: index)
        if let n = removed.name, !m.faces.contains(where: { $0.name == n }) { m.people.removeAll { $0 == n } }
        metadata[photo.id] = m
        metadataChanged()
    }

    // MARK: Analyse du contenu

    func toggleContentPause() {
        contentPaused.toggle()
        UserDefaults.standard.set(contentPaused, forKey: "contentPaused")
        if contentPaused {
            contentTask?.cancel()
        } else {
            startContentPass()
        }
    }

    /// Analyse en arrière-plan les photos pas encore analysées (les plus récentes d'abord).
    /// Remplit au passage le cache de miniatures. Reprend là où elle s'était arrêtée.
    func startContentPass() {
        guard contentTask == nil, !contentPaused else { return }
        let pending = byDateNewest.filter { p in
            guard let e = analysis[p.id] else { return true }
            return e.s != p.fileSize || abs(e.m - p.modificationDate.timeIntervalSince1970) >= 1
        }
        guard !pending.isEmpty else { return }
        contentTotal = pending.count
        contentDone = 0
        let generation = scanGeneration
        contentTask = Task {
            var start = 0
            var sinceSave = 0
            while start < pending.count {
                // Priorité aux miniatures affichées et à l'analyse des visages.
                while !(await ImageLoader.limiter.isIdle) || isAnalyzingFaces {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { break }
                }
                if Task.isCancelled || generation != scanGeneration { break }
                let end = min(start + 8, pending.count)
                let batch = Array(pending[start..<end])
                let results = await Task.detached(priority: .utility) { () -> [AnalysisEntry] in
                    var out = [AnalysisEntry](repeating: AnalysisEntry(s: 0, m: 0), count: batch.count)
                    out.withUnsafeMutableBufferPointer { buffer in
                        DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                            buffer[i] = ContentAnalyzer.analyze(batch[i])
                        }
                    }
                    return out
                }.value
                for (p, e) in zip(batch, results) { analysis[p.id] = e }
                contentDone = end
                start = end
                sinceSave += batch.count
                if sinceSave >= 1500 {
                    sinceSave = 0
                    saveAnalysis()
                    recomputeAnalysisDerived()
                }
            }
            saveAnalysis()
            recomputeAnalysisDerived()
            if start >= pending.count { contentTotal = 0; contentDone = 0 }
            contentTask = nil
        }
    }

    private func saveAnalysis() {
        let snapshot = analysis
        Task.detached(priority: .background) { AnalysisStore.save(snapshot) }
    }

    private func recomputeAnalysisDerived() {
        var rejects = 0
        for (id, e) in analysis where indexByID[id] != nil {
            if RejectReason.reason(for: e) != nil, !(metadata[id]?.qualityOK ?? false) { rejects += 1 }
        }
        rejectCount = rejects
        analysisRevision += 1
    }

    func labels(of photo: Photo) -> [String] { analysis[photo.id]?.l ?? [] }

    func rejectReason(of photo: Photo) -> RejectReason? {
        guard !(metadata[photo.id]?.qualityOK ?? false), let e = analysis[photo.id] else { return nil }
        return RejectReason.reason(for: e)
    }

    /// « Ce n'est pas raté » : la photo n'apparaît plus dans les photos ratées.
    func markQualityOK(_ photos: [Photo]) {
        for p in photos { metadata[p.id, default: PhotoMetadata()].qualityOK = true }
        metadataChanged()
        recomputeAnalysisDerived()
    }

    /// Score pour choisir la meilleure photo d'une série.
    func qualityScore(_ id: String) -> Float {
        guard let e = analysis[id] else { return -10 }
        return (e.a ?? 0) * 10 + min((e.b ?? 0) / 500, 2) + Float(metadata[id]?.richness ?? 0)
    }

    // MARK: Photos similaires

    func findSimilar() {
        guard !isFindingSimilar else { return }
        let items = photos.compactMap { p -> SimilarFinder.Item? in
            guard !p.isVideo, let h = analysis[p.id]?.h else { return nil }
            return SimilarFinder.Item(id: p.id, date: p.date, hash: h)
        }
        isFindingSimilar = true
        Task {
            let groups = await Task.detached(priority: .userInitiated) { SimilarFinder.groups(items) }.value
            let ordered = groups.map { g in g.sorted { qualityScore($0) > qualityScore($1) } }
            similarGroups = ordered.sorted { (photo(id: $0[0])?.date ?? .distantPast) > (photo(id: $1[0])?.date ?? .distantPast) }
            similarBest = Set(ordered.compactMap(\.first))
            isFindingSimilar = false
            similarRevision += 1
        }
    }

    var similarExtras: Int { (similarGroups ?? []).reduce(0) { $0 + $1.count - 1 } }

    /// Garde la meilleure photo de chaque série et met les autres à la corbeille
    /// (notes, personnes et albums reportés sur celle gardée).
    func trashSimilarExtras() {
        guard let groups = similarGroups, !isTrashing else { return }
        let plan = groups.compactMap { g -> (keep: String, others: [(String, URL)])? in
            guard g.count > 1 else { return nil }
            return (g[0], g.dropFirst().compactMap { id in photo(id: id).map { (id, $0.url) } })
        }
        isTrashing = true
        Task {
            let trashed = await Task.detached(priority: .userInitiated) { () -> [(keep: String, copy: String)] in
                var done: [(String, String)] = []
                for g in plan {
                    for (id, url) in g.others where (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                        done.append((g.keep, id))
                    }
                }
                return done
            }.value
            for t in trashed {
                if let m = metadata[t.copy] { metadata[t.keep, default: PhotoMetadata()].merge(m); metadata[t.copy] = nil }
            }
            let removed = Set(trashed.map(\.copy))
            removeFromLibrary(removed)
            similarGroups = groups.map { $0.filter { !removed.contains($0) } }.filter { $0.count > 1 }
            similarRevision += 1
            isTrashing = false
            notice = "\(trashed.count) photos mises à la corbeille ; la meilleure de chaque série est conservée."
            metadataChanged()
        }
    }

    // MARK: Lieux

    func place(of photo: Photo) -> Place? {
        guard let la = photo.latitude, let lo = photo.longitude,
              let p = places[PlaceStore.cell(la, lo)], !p.label.isEmpty else { return nil }
        return p
    }

    /// Nom court utilisé pour les listes (« Avoriaz »).
    func placeName(of photo: Photo) -> String? {
        guard let p = place(of: photo) else { return nil }
        return p.locality ?? p.area ?? p.country
    }

    /// Recherche les noms des zones visitées, les plus photographiées d'abord.
    func startPlacePass() {
        guard placeTask == nil else { return }
        var counts: [String: Int] = [:]
        for p in photos {
            if let la = p.latitude, let lo = p.longitude { counts[PlaceStore.cell(la, lo), default: 0] += 1 }
        }
        let pending = counts.filter { places[$0.key] == nil }.sorted { $0.value > $1.value }.map(\.key)
        guard !pending.isEmpty else { return }
        placeTotal = pending.count
        placeDone = 0
        placeTask = Task {
            var i = 0
            var failures = 0
            while i < pending.count, !Task.isCancelled {
                switch await PlaceStore.lookup(pending[i]) {
                case .found(let place):
                    places[pending[i]] = place
                case .nothing:
                    places[pending[i]] = Place()
                case .retryLater:
                    failures += 1
                    if failures > 20 { break } // hors ligne : on reprendra au prochain lancement
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                failures = 0
                i += 1
                placeDone = i
                if i % 25 == 0 { savePlaces(); recomputePlaces() }
                try? await Task.sleep(for: .milliseconds(1300)) // limite du service Apple
            }
            savePlaces()
            recomputePlaces()
            placeTotal = 0
            placeDone = 0
            placeTask = nil
        }
    }

    private func savePlaces() {
        let snapshot = places
        Task.detached(priority: .background) { PlaceStore.save(snapshot) }
    }

    private func recomputePlaces() {
        var counts: [String: Int] = [:]
        for p in photos { if let n = placeName(of: p) { counts[n, default: 0] += 1 } }
        allPlaces = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        analysisRevision += 1
    }

    // MARK: Persistance

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        roots = store.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        metadata = store.metadata
        // Migration : les visages importés de Picasa avant la v0.3 n'avaient pas l'indicateur « raw ».
        for key in metadata.keys where !metadata[key]!.facesAnalyzed {
            for i in metadata[key]!.faces.indices where metadata[key]!.faces[i].raw == nil
                && metadata[key]!.faces[i].suggestion == nil && metadata[key]!.faces[i].score == nil {
                metadata[key]!.faces[i].raw = true
            }
        }
        picasaImported = store.picasaImported ?? false
        albumNames = store.albums ?? []
    }

    private func save() {
        let store = Store(roots: roots.map(\.path), metadata: metadata,
                          picasaImported: picasaImported, albums: albumNames)
        let url = storeURL
        Task.detached(priority: .utility) {
            var s = store
            s.metadata = s.metadata.filter { !$0.value.isEmpty }
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        }
    }
}
