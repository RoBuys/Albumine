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
    /// Incrémenté quand la liste à afficher doit être recalculée.
    private(set) var revision = 0

    // Données dérivées, recalculées seulement quand c'est nécessaire.
    private(set) var photoCount = 0
    private(set) var folders: [FolderSummary] = []
    private(set) var allTags: [(name: String, count: Int)] = []
    private(set) var starredCount = 0
    private(set) var allPeople: [(name: String, count: Int)] = []
    private(set) var allAlbums: [(name: String, count: Int)] = []

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
    }

    init() {
        load()
        rescan()
    }

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
        recomputeMetadataDerived()
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
            revision += 1 // re-trie une seule fois avec les vraies dates
        }
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

    private func recomputeMetadataDerived() {
        var tagCounts: [String: Int] = [:]
        var peopleCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var starred = 0
        for (path, m) in metadata where indexByID[path] != nil {
            if m.rating > 0 { starred += 1 }
            for t in m.tags { tagCounts[t, default: 0] += 1 }
            for p in m.people { peopleCounts[p, default: 0] += 1 }
            for a in m.albums { albumCounts[a, default: 0] += 1 }
        }
        func sorted(_ counts: [String: Int]) -> [(name: String, count: Int)] {
            counts.map { (name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        starredCount = starred
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
        save()
        recomputeMetadataDerived()
        revision += 1
    }

    /// La photo correspond-elle à tous les mots recherchés (déjà normalisés) ?
    func matches(_ photo: Photo, tokens: [String]) -> Bool {
        var extra: String?
        return tokens.allSatisfy { token in
            if photo.searchKey.contains(token) { return true }
            if extra == nil {
                let year = String(Calendar.current.component(.year, from: photo.date))
                let m = metadata[photo.id]
                extra = ([photo.camera ?? "", year, m?.caption ?? ""] + (m?.tags ?? []) + (m?.people ?? []) + (m?.albums ?? []))
                    .joined(separator: " ").searchFolded
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
                if m.faces.isEmpty { m.faces = imp.faces }
                m.people.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                summary.namedFaces += imp.faces.filter { $0.name != nil }.count
                summary.people.formUnion(imp.people)
                summary.albums.formUnion(imp.albums)
                if m != before {
                    metadata[id] = m
                    summary.photos += 1
                }
            }
            Debug.log("import Picasa : \(fileCount) fichiers, \(imported.count) entrées, \(summary.photos) photos, \(Date().timeIntervalSince(start)) s")
            picasaImported = true
            metadataChanged()
            isImportingPicasa = false
            picasaSummary = summary
        }
    }

    // MARK: Persistance

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        roots = store.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        metadata = store.metadata
        picasaImported = store.picasaImported ?? false
    }

    private func save() {
        let store = Store(roots: roots.map(\.path), metadata: metadata.filter { !$0.value.isEmpty },
                          picasaImported: picasaImported)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(store) { try? data.write(to: storeURL, options: .atomic) }
    }
}
