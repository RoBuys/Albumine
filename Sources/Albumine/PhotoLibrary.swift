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

    private var metadata: [String: PhotoMetadata] = [:]
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var exifTask: Task<Void, Never>?

    @ObservationIgnored private let storeURL = AppPaths.support.appendingPathComponent("library.json")

    private struct Store: Codable {
        var roots: [String]
        var metadata: [String: PhotoMetadata]
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
        var counts: [String: Int] = [:]
        var starred = 0
        for (path, m) in metadata where indexByID[path] != nil {
            if m.rating > 0 { starred += 1 }
            for t in m.tags { counts[t, default: 0] += 1 }
        }
        starredCount = starred
        allTags = counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Notes et étiquettes

    func rating(of photo: Photo) -> Int { metadata[photo.id]?.rating ?? 0 }
    func tags(of photo: Photo) -> [String] { metadata[photo.id]?.tags ?? [] }

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
                extra = ([photo.camera ?? "", year] + tags(of: photo)).joined(separator: " ").searchFolded
            }
            return extra!.contains(token)
        }
    }

    // MARK: Persistance

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        roots = store.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        metadata = store.metadata
    }

    private func save() {
        let store = Store(roots: roots.map(\.path), metadata: metadata.filter { !$0.value.isEmpty })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(store) { try? data.write(to: storeURL, options: .atomic) }
    }
}
