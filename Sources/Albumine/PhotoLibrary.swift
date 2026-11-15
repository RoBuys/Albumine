import SwiftUI
import AppKit

/// Library: watched source folders, photos found, ratings and tags.
/// - library.json: watched folders, ratings, tags
/// - index.json  : file index + EXIF (to restart without re-reading everything)
@MainActor
@Observable
final class PhotoLibrary {
    private(set) var roots: [URL] = []
    /// Subfolders excluded from the scan (full paths).
    private(set) var excludedPaths: [String] = []
    /// People hidden from the sidebar.
    private(set) var hiddenPeople: Set<String> = []
    /// Chosen profile picture: name → "photo identifier#face index".
    private(set) var personCovers: [String: String] = [:]
    /// Default profile picture (largest named face): name → (photo, face).
    @ObservationIgnored private(set) var defaultCovers: [String: (String, Int)] = [:]

    // File integrity
    private(set) var damaged: [String: String] = [:]   // identifier → problem
    private(set) var integrityDone = 0
    private(set) var integrityTotal = 0
    private(set) var lastIntegrityCheck: Date?
    @ObservationIgnored private var integrityTask: Task<Void, Never>?

    // Backup
    private(set) var backupDestination: URL? = UserDefaults.standard.string(forKey: "backupDestination").map { URL(fileURLWithPath: $0) }
    private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackup") as? Date
    private(set) var backupPlan: BackupPlan?
    private(set) var isPlanningBackup = false
    private(set) var backupBytesDone: Int64 = 0
    private(set) var backupFilesDone = 0
    private(set) var isBackingUp = false
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    /// All photos. Modified in batches while EXIF data is read:
    /// avoid reading it in a `body` (prefer `revision`, `photoCount`, `photo(id:)`).
    private(set) var photos: [Photo] = []
    private(set) var isScanning = false
    /// Progress of the background EXIF reading.
    private(set) var exifDone = 0
    private(set) var exifTotal = 0
    /// Incremented when the set of photos (or their order) changes.
    private(set) var revision = 0
    /// Incremented when ratings, tags, people… change.
    private(set) var metadataRevision = 0
    /// All photos, newest first (sorted only once).
    @ObservationIgnored private(set) var byDateNewest: [Photo] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // Derived data, recomputed only when needed.
    private(set) var photoCount = 0
    private(set) var folders: [FolderSummary] = []
    private(set) var allTags: [(name: String, count: Int)] = []
    private(set) var starredCount = 0
    /// Photos marked "à jeter" (keyboard review).
    private(set) var discardCount = 0
    private(set) var allPeople: [(name: String, count: Int)] = []
    private(set) var allAlbums: [(name: String, count: Int)] = []

    // Smart albums: saved searches
    private(set) var smartAlbums: [SmartAlbum] = []

    func saveSmartAlbum(_ album: SmartAlbum) {
        smartAlbums.removeAll { $0.name == album.name }
        smartAlbums.append(album)
        smartAlbums.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    func deleteSmartAlbum(_ name: String) {
        smartAlbums.removeAll { $0.name == name }
        save()
    }

    func renameSmartAlbum(_ name: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != name, !smartAlbums.contains(where: { $0.name == n }),
              let i = smartAlbums.firstIndex(where: { $0.name == name }) else { return }
        smartAlbums[i].name = n
        smartAlbums.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    // Virtual albums (list kept even when an album is empty)
    private(set) var albumNames: [String] = []

    // Sidebar counters
    private(set) var videoCount = 0
    private(set) var locatedCount = 0
    private(set) var unnamedFaceCount = 0

    // Duplicates
    private(set) var duplicateGroups: [[String]]?
    private(set) var duplicateKeepers: Set<String> = []
    private(set) var isFindingDuplicates = false
    private(set) var isTrashing = false
    private(set) var duplicateDone = 0
    private(set) var duplicateTotal = 0
    /// Message to show (end of a long operation).
    var notice: String?

    // Faces
    private(set) var faceDone = 0
    private(set) var faceTotal = 0
    private(set) var facePreparing = false
    @ObservationIgnored private var faceTask: Task<Void, Never>?
    @ObservationIgnored private var faceRefs: FaceReferences?

    // Content analysis (categories, quality, fingerprint) — analysis.json
    @ObservationIgnored private(set) var analysis: [String: AnalysisEntry] = [:]
    private(set) var analysisRevision = 0
    private(set) var contentDone = 0
    private(set) var contentTotal = 0
    private(set) var contentPaused = UserDefaults.standard.bool(forKey: "contentPaused")
    private(set) var rejectCount = 0
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    /// Identifies the current analysis pass (an outdated pass stops by itself).
    @ObservationIgnored private var contentRun = 0

    // Memories: photos taken on the same day in previous years
    private(set) var memoryIDs: Set<String> = []
    private(set) var memoryYears: [Int] = []

    // Similar photos (computed on demand)
    private(set) var similarGroups: [[String]]?
    private(set) var similarBest: Set<String> = []
    private(set) var similarRevision = 0
    private(set) var isFindingSimilar = false

    // Places — places.json
    @ObservationIgnored private(set) var places: [String: Place] = [:]
    private(set) var allPlaces: [(name: String, count: Int)] = []
    private(set) var placeDone = 0
    private(set) var placeTotal = 0
    @ObservationIgnored private var placeTask: Task<Void, Never>?

    // Disconnected drive, folder watching
    private(set) var offlineRoots: [URL] = []
    private(set) var offlineCount = 0
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var rescanSoonTask: Task<Void, Never>?

    // XMP files
    private(set) var sidecarCount = 0
    @ObservationIgnored private var sidecarPaths: [String] = []
    private(set) var writeXMP = UserDefaults.standard.bool(forKey: "writeXMP")
    private(set) var xmpImported = UserDefaults.standard.bool(forKey: "xmpImported")
    private(set) var isWritingXMP = false
    private(set) var isImportingXMP = false
    @ObservationIgnored private var xmpState: [String: String] = [:]
    @ObservationIgnored private var xmpTask: Task<Void, Never>?
    @ObservationIgnored private let xmpStateURL = AppPaths.support.appendingPathComponent("xmp-state.json")

    // Picasa import
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
        var excluded: [String]?
        var hiddenPeople: [String]?
        var personCovers: [String: String]?
        var damaged: [String: String]?
        var lastIntegrityCheck: Date?
        var preferredFolders: [String]?
        var smartAlbums: [SmartAlbum]?
    }

    init() {
        load()
        if let data = try? Data(contentsOf: xmpStateURL),
           let state = try? JSONDecoder().decode([String: String].self, from: data) { xmpState = state }
        // Before quitting for an update: save everything synchronously.
        volumeObservers.append(NotificationCenter.default.addObserver(forName: .albumineWillQuitForUpdate, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        })
        // A drive was connected / disconnected: rescan the folders.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescanSoon() }
            })
        }
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

    // MARK: Folders

    func addFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Ajouter")
        panel.message = L("Choisissez les dossiers qui contiennent vos photos")
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
        excludedPaths.removeAll { $0.hasPrefix(root.path + "/") }
        save()
        rescan()
    }

    /// Excludes subfolders of a watched folder (no longer scanned or shown).
    func excludeFolders(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard root(containing: path) != nil, !roots.contains(where: { $0.path == path }),
                  !PhotoScanner.isExcluded(path, excludedPaths) else { continue }
            excludedPaths.removeAll { $0.hasPrefix(path + "/") }
            excludedPaths.append(path)
            changed = true
        }
        if changed {
            excludedPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            save()
            rescan()
        }
    }

    func excludeFolderWithPanel(in root: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = root ?? roots.first
        panel.prompt = L("Exclure")
        panel.message = L("Choisissez les sous-dossiers à ne plus analyser (ils doivent être dans un dossier suivi)")
        if panel.runModal() == .OK { excludeFolders(panel.urls) }
    }

    func includeAgain(_ path: String) {
        excludedPaths.removeAll { $0 == path }
        save()
        rescan()
    }

    /// Number of items found under a watched folder.
    func count(under root: URL) -> Int {
        let prefix = root.path + "/"
        return photos.reduce(0) { $0 + ($1.id.hasPrefix(prefix) ? 1 : 0) }
    }

    func root(containing path: String) -> URL? {
        roots.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    // MARK: Scanning

    func rescan() {
        let roots = self.roots
        let excluded = self.excludedPaths
        scanGeneration += 1
        let generation = scanGeneration
        exifTask?.cancel()
        exifDone = 0
        exifTotal = 0
        isScanning = true
        let reachable = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let missing = roots.filter { r in !reachable.contains(where: { $0.path == r.path }) }
        // First scan of the session: show the library known from the index right away, the
        // drive is then read in the background (about a minute for a large hard drive).
        let instant = photos.isEmpty
        Task {
            let start = Date()
            let index = await Task.detached(priority: .userInitiated) { IndexStore.load() }.value
            if instant, !index.isEmpty, generation == scanGeneration {
                let known = await Task.detached(priority: .userInitiated) { () -> [Photo] in
                    reachable.flatMap { PhotoScanner.offlinePhotos(under: $0, index: index, excluded: excluded, offline: false) }
                        + missing.flatMap { PhotoScanner.offlinePhotos(under: $0, index: index, excluded: excluded) }
                }.value
                if generation == scanGeneration, !known.isEmpty {
                    offlineRoots = missing
                    setPhotos(known)
                    Debug.log("démarrage : \(known.count) photos affichées depuis l'index en \(Date().timeIntervalSince(start)) s")
                }
            }
            let result = await Task.detached(priority: .userInitiated) { () -> ScanResult in
                var result = PhotoScanner.scan(reachable, index: index, excluded: excluded)
                // Disconnected drive: keep its photos, from the index (cached thumbnails).
                for root in missing { result.photos += PhotoScanner.offlinePhotos(under: root, index: index, excluded: excluded) }
                return result
            }.value
            guard generation == scanGeneration else { return }
            offlineRoots = missing
            sidecarPaths = result.sidecars
            sidecarCount = result.sidecars.count
            startWatching(reachable)
            Debug.log("scan: \(result.photos.count) photos (dont \(result.photos.filter(\.offline).count) hors ligne), \(result.pending.count) EXIF à lire, \(result.sidecars.count) XMP, \(Date().timeIntervalSince(start)) s")
            if !sameFiles(result.photos) { setPhotos(result.photos) }
            isScanning = false
            if ProcessInfo.processInfo.environment["ALBUMINE_AUTOIMPORT"] != nil { importPicasa() } // tests
            if ProcessInfo.processInfo.environment["ALBUMINE_AUTODUPLICATES"] != nil { findDuplicates() } // tests
            if result.pending.isEmpty {
                saveIndex()
                afterExifPass()
            } else {
                startExifPass(result.pending, generation: generation)
            }
        }
    }

    /// Did the scan find exactly the files already shown (same size, date, availability)?
    private func sameFiles(_ incoming: [Photo]) -> Bool {
        guard incoming.count == photos.count, !photos.isEmpty else { return false }
        return incoming.allSatisfy { p in
            guard let i = indexByID[p.id] else { return false }
            let q = photos[i]
            return q.fileSize == p.fileSize && abs(q.modificationDate.timeIntervalSince(p.modificationDate)) < 1
                && q.offline == p.offline && q.exifChecked == p.exifChecked
        }
    }

    private func setPhotos(_ incoming: [Photo]) {
        var newPhotos = incoming
        // Locations added by hand.
        for i in newPhotos.indices {
            if let m = metadata[newPhotos[i].id] {
                if let la = m.lat, let lo = m.lon {
                    newPhotos[i].latitude = la
                    newPhotos[i].longitude = lo
                }
                newPhotos[i].dateOverride = m.date.map { Date(timeIntervalSince1970: $0) }
            }
        }
        ImageLoader.registerSignatures(newPhotos)
        offlineCount = newPhotos.reduce(0) { $0 + ($1.offline ? 1 : 0) }
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

    /// Reads missing EXIF data in batches, giving priority to thumbnails.
    private func startExifPass(_ pending: [Int], generation: Int) {
        let urls = pending.map { photos[$0].url }
        exifTotal = pending.count
        exifDone = 0
        exifTask = Task {
            let chunk = 128
            var start = 0
            var lastSave = 0
            while start < pending.count {
                // Pause while thumbnails are loading.
                await ImageLoader.waitUntilIdle(maxSeconds: 15)
                if Task.isCancelled { return }
                if Task.isCancelled || generation != scanGeneration { return }
                let end = min(start + chunk, pending.count)
                let batch = Array(urls[start..<end])
                // Per-file time limit: a file that blocks the reader no longer freezes the pass.
                let results = await Watchdog.map(batch, width: 6, timeout: 30) { PhotoScanner.readExif([$0])[0] }
                    .map { $0 ?? ExifReader.Quick() }
                if Task.isCancelled || generation != scanGeneration { return }
                for (offset, r) in results.enumerated() {
                    let i = pending[start + offset]
                    photos[i].captureDate = r.date
                    photos[i].camera = r.camera
                    photos[i].orientation = r.orientation
                    let manual = metadata[photos[i].id]
                    photos[i].latitude = manual?.lat ?? r.latitude
                    photos[i].longitude = manual?.lon ?? r.longitude
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
            revision += 1 // re-sorts once with the real dates
            afterExifPass()
        }
    }

    /// Called once all dates and coordinates have been read.
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
        computeMemories()
    }

    /// "N years ago today": same day and month, previous years.
    func computeMemories() {
        let snapshot = photos.map { ($0.id, $0.date) }
        Task {
            let (ids, years) = await Task.detached(priority: .utility) { () -> (Set<String>, [Int]) in
                let cal = Calendar.current
                let today = cal.dateComponents([.year, .month, .day], from: Date())
                var ids = Set<String>(), years = Set<Int>()
                for (id, date) in snapshot {
                    let c = cal.dateComponents([.year, .month, .day], from: date)
                    if c.month == today.month, c.day == today.day, let y = c.year, y < (today.year ?? 0) {
                        ids.insert(id)
                        years.insert(y)
                    }
                }
                return (ids, years.sorted(by: >))
            }.value
            memoryIDs = ids
            memoryYears = years
        }
    }

    private func recomputeCounts() {
        videoCount = photos.reduce(0) { $0 + ($1.isVideo ? 1 : 0) }
        locatedCount = photos.reduce(0) { $0 + ($1.hasLocation ? 1 : 0) }
    }

    private func recomputeMetadataDerived() {
        var covers: [String: (String, Int, Double)] = [:]
        var tagCounts: [String: Int] = [:]
        var peopleCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = Dictionary(uniqueKeysWithValues: albumNames.map { ($0, 0) })
        var starred = 0
        var unnamed = 0
        var discards = 0
        for (path, m) in metadata where indexByID[path] != nil {
            if m.rating > 0 { starred += 1 }
            if m.discard { discards += 1 }
            if m.hasUnnamedFaces { unnamed += 1 }
            for t in m.tags { tagCounts[t, default: 0] += 1 }
            for p in m.people { peopleCounts[p, default: 0] += 1 }
            for (i, f) in m.faces.enumerated() where f.w > 0 {
                if let n = f.name, f.w > (covers[n]?.2 ?? 0) { covers[n] = (path, i, f.w) }
            }
            for a in m.albums { albumCounts[a, default: 0] += 1 }
        }
        func sorted(_ counts: [String: Int]) -> [(name: String, count: Int)] {
            counts.map { (name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        starredCount = starred
        discardCount = discards
        unnamedFaceCount = unnamed
        allTags = sorted(tagCounts)
        defaultCovers = covers.mapValues { ($0.0, $0.1) }
        allPeople = sorted(peopleCounts)
        allAlbums = sorted(albumCounts)
    }

    // MARK: Ratings and tags

    func rating(of photo: Photo) -> Int { metadata[photo.id]?.rating ?? 0 }
    func isDiscarded(_ photo: Photo) -> Bool { metadata[photo.id]?.discard ?? false }

    /// Marks photos "à jeter" (or back to kept). Nothing is moved until the user empties that list.
    func setDiscard(_ photos: [Photo], _ on: Bool) {
        var changed = false
        for p in photos where (metadata[p.id]?.discard ?? false) != on {
            metadata[p.id, default: PhotoMetadata()].discard = on
            changed = true
        }
        if changed { metadataChanged() }
    }

    var discardedPhotos: [Photo] { photos.filter { metadata[$0.id]?.discard ?? false } }
    func tags(of photo: Photo) -> [String] { metadata[photo.id]?.tags ?? [] }
    func people(of photo: Photo) -> [String] { metadata[photo.id]?.people ?? [] }
    func albums(of photo: Photo) -> [String] { metadata[photo.id]?.albums ?? [] }
    func caption(of photo: Photo) -> String { metadata[photo.id]?.caption ?? "" }
    func rotation(of photo: Photo) -> Int { metadata[photo.id]?.rotation ?? 0 }
    func faces(of photo: Photo) -> [FaceRegion] { metadata[photo.id]?.faces ?? [] }

    /// Face region in the EXIF-oriented image, without the display rotation.
    /// (Picasa faces are expressed in the raw sensor image: they are converted.)
    func faceRect(_ face: FaceRegion, in photo: Photo) -> CGRect {
        face.raw == true ? FaceGeometry.applyOrientation(face.rect, photo.orientation) : face.rect
    }

    /// Rotates the display by a quarter turn (+1 clockwise, -1 counterclockwise). The file is not modified.
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
        if writeXMP { scheduleXMPWrite() }
        recomputeMetadataDerived()
        metadataRevision += 1
    }

    /// Deferred save, off the main thread: the UI no longer freezes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Does the photo match all the search words (already normalized)?
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
                if let t = analysis[photo.id]?.t { text += " " + t.searchFolded }
                if let place = place(of: photo) { text += " " + place.searchText }
                extra = text
            }
            return extra!.contains(token)
        }
    }

    // MARK: Picasa import

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

    /// Merges Picasa data without overwriting anything: people, albums and stars are added,
    /// rotation and caption are only taken if not already set.
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

            // Case-insensitive index (Picasa sometimes uses a different case than the disk).
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
                if let e = imp.edits, m.edits == nil { m.edits = e; summary.edits += 1 }
                for name in imp.people where !m.people.contains(name) { m.people.append(name) }
                for album in imp.albums where !m.albums.contains(album) { m.albums.append(album) }
                // Replaces faces from a previous import (not those detected or named in Albumine).
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

    // MARK: Virtual albums

    /// Creates an album (optionally with photos). A photo can be in several albums
    /// without being copied.
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

    /// Deletes the album; the photos are not touched.
    func deleteAlbum(_ name: String) {
        albumNames.removeAll { $0 == name }
        for key in metadata.keys where metadata[key]!.albums.contains(name) {
            metadata[key]!.albums.removeAll { $0 == name }
        }
        metadataChanged()
    }

    // MARK: Duplicates

    func findDuplicates() {
        guard !isFindingDuplicates else { return }
        // Sorted by path: files of a folder are read together (far fewer seeks on a hard drive).
        let items = DuplicateFinder.sameSizeCandidates(photos.filter { !$0.offline })
            .map { (id: $0.id, url: $0.url, size: $0.fileSize, mtime: $0.modificationDate) }
            .sorted { $0.id < $1.id }
        isFindingDuplicates = true
        duplicateDone = 0
        duplicateTotal = items.count
        Debug.log("doublons : \(items.count) fichiers de même taille")
        Task {
            var cache = await Task.detached(priority: .utility) { DuplicateHashCache.load() }.value
            var byHash: [String: [String]] = [:]
            var toRead: [(id: String, url: URL, size: Int64, mtime: Date)] = []
            for it in items {
                if let h = cache.hash(path: it.id, size: it.size, mtime: it.mtime) {
                    byHash[h, default: []].append(it.id)
                } else {
                    toRead.append(it)
                }
            }
            duplicateDone = items.count - toRead.count
            var sinceSave = 0
            var start = 0
            // A rescan (folder watching) no longer interrupts the search: ids are paths, and
            // photos that disappeared in the meantime are dropped from the result below.
            while start < toRead.count {
                // Brief pause only, so the grid stays smooth (a long wait made the search
                // crawl while the content analysis kept the image loader busy).
                await ImageLoader.waitUntilIdle(maxSeconds: 0.5)
                let end = min(start + 128, toRead.count)
                let batch = Array(toRead[start..<end])
                let hashes = await Watchdog.map(batch, width: 4, timeout: 30) { DuplicateFinder.quickHash($0.url, size: $0.size) }
                for (it, h) in zip(batch, hashes) {
                    guard let h = h ?? nil else { continue }
                    byHash[h, default: []].append(it.id)
                    cache.entries[it.id] = .init(s: it.size, m: it.mtime.timeIntervalSince1970, h: h)
                }
                sinceSave += batch.count
                if sinceSave >= 4000 {
                    sinceSave = 0
                    let snapshot = cache
                    Task.detached(priority: .utility) { snapshot.save() }
                }
                start = end
                duplicateDone = items.count - toRead.count + end
            }
            let snapshot = cache
            Task.detached(priority: .utility) { snapshot.save() }
            let present = Set(photos.map(\.id))
            setDuplicateGroups(byHash.values
                .map { $0.filter(present.contains) }
                .filter { $0.count > 1 }
                .map { $0.sorted(by: keeperFirst) })
            isFindingDuplicates = false
            let waste = duplicateWaste
            Debug.log("doublons : \(duplicateGroups?.count ?? 0) groupes, \(waste.count) copies")
            #if DEBUG
            if let k = ProcessInfo.processInfo.environment["ALBUMINE_TEST_KEEPDUP"] { keepInDuplicates([k], keep: k) } // tests
            if ProcessInfo.processInfo.environment["ALBUMINE_SELFTEST"] == "folders", !selfTestDone {
                selfTestDone = true
                for p in duplicateFolderPairs { Debug.log("paire : \((p.a as NSString).lastPathComponent) ↔ \((p.b as NSString).lastPathComponent) : \(p.count)") }
                if let pair = duplicateFolderPairs.first(where: { !$0.isInternal }) {
                    keepFolder(pair.a, in: pair)
                    while isTrashing { try? await Task.sleep(for: .milliseconds(100)) }
                    Debug.log("test : après « garder \((pair.a as NSString).lastPathComponent) » : \(photos.count) photos, message : \(notice ?? "-"), annulable : \(canUndoTrash)")
                    Debug.log("test : métadonnées \(metadata.filter { !$0.value.isEmpty }.map { ($0.key as NSString).lastPathComponent + "=" + String($0.value.rating) }.sorted())")
                    try? await Task.sleep(for: .seconds(1))
                    undoLastTrash()
                    while isTrashing || isScanning { try? await Task.sleep(for: .milliseconds(100)) }
                    Debug.log("test : après annulation : \(photos.count) photos, message : \(notice ?? "-"), groupes : \(duplicateGroups?.count ?? -1)")
                    Debug.log("test : métadonnées \(metadata.filter { !$0.value.isEmpty }.map { ($0.key as NSString).lastPathComponent + "=" + String($0.value.rating) }.sorted())")
                }
            }
            #endif
            notice = waste.count == 0
                ? L("Aucun doublon trouvé.")
                : L("\(duplicateGroups?.count ?? 0) groupes de doublons : \(waste.count) copies en trop (\(ByteCountFormatter.string(fromByteCount: waste.bytes, countStyle: .file))).")
        }
    }

    private func setDuplicateGroups(_ groups: [[String]]) {
        duplicateGroups = groups.sorted {
            (photo(id: $0[0])?.fileSize ?? 0) * Int64($0.count) > (photo(id: $1[0])?.fileSize ?? 0) * Int64($1.count)
        }
        duplicateKeepers = Set(groups.compactMap(\.first))
        recomputeDuplicateFolders()
        revision += 1
    }

    // Duplicates by folder

    /// Two folders that share identical files (or one folder holding several copies: a == b).
    struct DuplicateFolderPair: Identifiable, Equatable {
        let a: String
        let b: String
        var count: Int        // groups with a copy in both
        var bytes: Int64      // size of one copy of each
        var id: String { a + "\t" + b }
        var isInternal: Bool { a == b }
    }
    private(set) var duplicateFolderPairs: [DuplicateFolderPair] = []
    /// Folders whose copies are always kept (most important first); subfolders included.
    private(set) var preferredFolders: [String] = []

    private func recomputeDuplicateFolders() {
        var pairs: [String: DuplicateFolderPair] = [:]
        for g in duplicateGroups ?? [] {
            let items = g.compactMap { photo(id: $0) }
            guard let size = items.first?.fileSize else { continue }
            let byFolder = Dictionary(grouping: items, by: \.folderPath)
            let folders = byFolder.keys.sorted()
            func add(_ a: String, _ b: String) {
                let key = a + "\t" + b
                pairs[key, default: DuplicateFolderPair(a: a, b: b, count: 0, bytes: 0)].count += 1
                pairs[key]!.bytes += size
            }
            for (i, a) in folders.enumerated() {
                if byFolder[a]!.count > 1 { add(a, a) }
                for b in folders[(i + 1)...] { add(a, b) }
            }
        }
        duplicateFolderPairs = pairs.values.sorted { ($0.count, $0.bytes, $1.id) > ($1.count, $1.bytes, $0.id) }
    }

    /// Groups of duplicates with a copy in both folders of the pair.
    func duplicateGroups(in pair: DuplicateFolderPair) -> [[String]] {
        (duplicateGroups ?? []).filter { g in
            let folders = g.compactMap { photo(id: $0)?.folderPath }
            return pair.isInternal ? folders.filter { $0 == pair.a }.count > 1
                                   : folders.contains(pair.a) && folders.contains(pair.b)
        }
    }

    /// Keeps the copies of `keep` and moves to the Trash the identical files of the other folder
    /// of the pair (copies in other folders are left alone). Internal pair: one copy stays.
    func keepFolder(_ keep: String, in pair: DuplicateFolderPair) {
        let other = keep == pair.a ? pair.b : pair.a
        var steps: [TrashStep] = []
        for g in duplicateGroups(in: pair) {
            let inKeep = g.filter { photo(id: $0)?.folderPath == keep }
            guard let keeper = inKeep.first else { continue }
            let remove = pair.isInternal ? Array(inKeep.dropFirst()) : g.filter { photo(id: $0)?.folderPath == other }
            steps += remove.map { TrashStep(remove: $0, into: keeper) }
        }
        let name = (other as NSString).lastPathComponent
        performTrash(steps, verifyIdentical: true) { [self] r in
            let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
            notice = L(r.removed.count, one: "1 copie de « \(name) » mise à la corbeille (\(size) libérés).",
                       other: "\(r.removed.count) copies de « \(name) » mises à la corbeille (\(size) libérés).")
                + (r.skipped > 0 ? L(" \(r.skipped) fichiers gardés : contenu différent ou corbeille indisponible.") : "")
        }
    }

    func isPreferredFolder(_ path: String) -> Bool { preferredFolders.contains(path) }

    /// Rule: the copies of this folder (and its subfolders) are the ones to keep.
    func setPreferredFolder(_ path: String, _ on: Bool) {
        preferredFolders.removeAll { $0 == path }
        if on { preferredFolders.append(path) }
        save()
        if let g = duplicateGroups { setDuplicateGroups(g.map { $0.sorted(by: keeperFirst) }) }
    }

    private func preferenceRank(_ id: String) -> Int {
        guard !preferredFolders.isEmpty else { return 0 }
        return preferredFolders.firstIndex { id.hasPrefix($0 + "/") } ?? Int.max
    }

    /// Preference order for the copy to keep: folder rules, then most annotated, then oldest,
    /// then shortest path.
    private func keeperFirst(_ a: String, _ b: String) -> Bool {
        let pa = preferenceRank(a), pb = preferenceRank(b)
        if pa != pb { return pa < pb }
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

    /// Moves all copies to the Trash (recoverable from the drive's Trash).
    /// Each copy is first compared byte by byte with the kept photo; its ratings,
    /// tags, people and albums are carried over to the kept photo.
    func trashDuplicateCopies() {
        guard let groups = duplicateGroups else { return }
        trashDuplicateCopies(in: groups)
    }

    /// Series containing one of these photos (duplicates or similar photos), in display order.
    func series(containing ids: Set<String>, in groups: [[String]]?) -> [[String]] {
        (groups ?? []).filter { $0.contains(where: ids.contains) }
    }

    /// Right-click on duplicates: keeps the copy marked "À garder" (or `keep`) of each series
    /// touched, the other copies of those series go to the Trash.
    func keepInDuplicates(_ ids: Set<String>, keep: String? = nil) {
        let touched = series(containing: ids, in: duplicateGroups).map { g in
            keep.map { k in g.contains(k) ? [k] + g.filter { $0 != k } : g } ?? g
        }
        trashDuplicateCopies(in: touched)
    }

    /// Each group: the copy to keep first, then the copies to remove.
    private func trashDuplicateCopies(in groups: [[String]]) {
        let steps = groups.flatMap { g in g.dropFirst().map { TrashStep(remove: $0, into: g[0]) } }
        performTrash(steps, verifyIdentical: true) { [self] r in
            let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
            notice = L(r.removed.count, one: "1 copie mise à la corbeille (\(size) libérés).",
                       other: "\(r.removed.count) copies mises à la corbeille (\(size) libérés).")
                + (r.skipped > 0 ? L(" \(r.skipped) fichiers gardés : contenu différent ou corbeille indisponible.") : "")
        }
    }

    // MARK: Trash and undo

    /// `remove` goes to the Trash; its ratings, people, albums… are merged into `into`.
    struct TrashStep { let remove: String; let into: String? }

    /// What the last move to the Trash did, to put everything back.
    struct TrashUndo {
        var files: [(original: URL, trashed: URL)]
        var metadata: [String: PhotoMetadata?]
        var duplicateGroups: [[String]]?
        var similarGroups: [[String]]?
    }
    private(set) var lastTrash: TrashUndo?
    /// The message that goes with the last move to the Trash (it gets an "Annuler" button).
    private(set) var undoNotice: String?
    var canUndoTrash: Bool { lastTrash != nil && !isTrashing }

    struct TrashResult { let removed: Set<String>; let skipped: Int; let bytes: Int64 }

    nonisolated static func moveToTrash(_ url: URL) -> URL? {
        var out: NSURL?
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &out)) != nil else { return nil }
        return out as URL?
    }

    /// Moves files to the Trash (recoverable), merges their annotations into the kept photos,
    /// updates the duplicate and similar series, and remembers how to undo it all.
    /// - verifyIdentical: compares each file byte by byte with its kept copy first (duplicates).
    private func performTrash(_ steps: [TrashStep], verifyIdentical: Bool = false, chained: Bool = false,
                              then: @escaping (TrashResult) -> Void) {
        guard !isTrashing else {
            // Already moving files (quick sorting, series after series): this one waits its turn.
            pendingTrash.append { [self] in performTrash(steps, verifyIdentical: verifyIdentical, chained: true, then: then) }
            return
        }
        let work: [(remove: String, url: URL, into: String?, keepURL: URL?)] = steps.compactMap { st in
            guard let p = photo(id: st.remove), !p.offline, st.remove != st.into else { return nil }
            let keep = st.into.flatMap { photo(id: $0) }
            if st.into != nil, keep == nil { return nil }
            return (st.remove, p.url, st.into, keep?.url)
        }
        guard !work.isEmpty else { runPendingTrash(); return }
        var undo = TrashUndo(files: [], metadata: [:], duplicateGroups: duplicateGroups, similarGroups: similarGroups)
        // Operations that followed each other without a pause are undone together.
        let previous = chained ? lastTrash : nil
        for w in work {
            undo.metadata[w.remove] = .some(metadata[w.remove])
            if let k = w.into { undo.metadata[k] = .some(metadata[k]) }
        }
        isTrashing = true
        Task {
            let done = await Task.detached(priority: .userInitiated) { () -> [(id: String, into: String?, from: URL, to: URL?, size: Int64)] in
                var done: [(String, String?, URL, URL?, Int64)] = []
                for w in work {
                    if verifyIdentical, let k = w.keepURL, !DuplicateFinder.identical(k, w.url) { continue }
                    let size = (try? w.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                    guard (try? FileManager.default.attributesOfItem(atPath: w.url.path)) != nil else { continue }
                    var out: NSURL?
                    guard (try? FileManager.default.trashItem(at: w.url, resultingItemURL: &out)) != nil else { continue }
                    done.append((w.remove, w.into, w.url, out as URL?, Int64(size)))
                }
                return done
            }.value
            for d in done {
                if let k = d.into, let m = metadata[d.id] { metadata[k, default: PhotoMetadata()].merge(m) }
                metadata[d.id] = nil
                if let to = d.to { undo.files.append((d.from, to)) }
            }
            let removed = Set(done.map(\.id))
            let kept = Set(done.compactMap(\.into))
            undo.metadata = undo.metadata.filter { removed.contains($0.key) || kept.contains($0.key) }
            removeFromLibrary(removed)
            // Series: removed photos leave them, the kept photo comes first.
            func prune(_ groups: [[String]]?) -> [[String]]? {
                groups?.map { g in
                    let rest = g.filter { !removed.contains($0) }
                    guard let k = rest.first(where: kept.contains) else { return rest }
                    return [k] + rest.filter { $0 != k }
                }.filter { $0.count > 1 }
            }
            if let g = prune(duplicateGroups) { setDuplicateGroups(g) }
            if let g = prune(similarGroups) {
                similarGroups = g
                similarBest = Set(g.compactMap(\.first))
                similarRevision += 1
            }
            if let previous {
                undo.files = previous.files + undo.files
                undo.metadata.merge(previous.metadata) { _, older in older }
                undo.duplicateGroups = previous.duplicateGroups
                undo.similarGroups = previous.similarGroups
            }
            lastTrash = undo.files.isEmpty ? nil : undo
            isTrashing = false
            then(TrashResult(removed: removed, skipped: work.count - done.count, bytes: done.reduce(0) { $0 + $1.size }))
            undoNotice = lastTrash == nil ? nil : notice
            metadataChanged()
            runPendingTrash()
        }
    }

    @ObservationIgnored private var pendingTrash: [() -> Void] = []
    #if DEBUG
    @ObservationIgnored private var selfTestDone = false
    #endif

    private func runPendingTrash() {
        guard !isTrashing, !pendingTrash.isEmpty else { return }
        pendingTrash.removeFirst()()
    }

    /// Puts the files of the last move to the Trash back in place, with their annotations.
    func undoLastTrash() {
        guard let undo = lastTrash, !isTrashing else { return }
        lastTrash = nil
        isTrashing = true
        Task {
            let restored = await Task.detached(priority: .userInitiated) { () -> Int in
                var n = 0
                for f in undo.files where !FileManager.default.fileExists(atPath: f.original.path) {
                    if (try? FileManager.default.moveItem(at: f.trashed, to: f.original)) != nil { n += 1 }
                }
                return n
            }.value
            for (id, m) in undo.metadata { metadata[id] = m }
            isTrashing = false
            duplicateGroups = undo.duplicateGroups
            duplicateKeepers = Set((undo.duplicateGroups ?? []).compactMap(\.first))
            similarGroups = undo.similarGroups
            similarBest = Set((undo.similarGroups ?? []).compactMap(\.first))
            similarRevision += 1
            let missing = undo.files.count - restored
            notice = L(restored, one: "1 fichier remis en place.", other: "\(restored) fichiers remis en place.")
                + (missing > 0 ? " " + L(missing, one: "1 introuvable dans la Corbeille (déjà vidée ?).",
                                         other: "\(missing) introuvables dans la Corbeille (déjà vidée ?).") : "")
            metadataChanged()
            rescan()
        }
    }

    /// Moves photos to the Trash (recoverable).
    func trash(_ photos: [Photo]) {
        let count = photos.count
        performTrash(photos.map { TrashStep(remove: $0.id, into: nil) }) { [self] r in
            notice = L(r.removed.count, one: "1 élément mis à la corbeille.", other: "\(r.removed.count) éléments mis à la corbeille.")
                + (r.removed.count < count ? L(" \(count - r.removed.count) n'ont pas pu l'être.") : "")
        }
    }

    /// Removes photos from the list without rescanning (EXIF reading resumes afterwards).
    private func removeFromLibrary(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if isScanning {
            // The drive is still being read (instant startup): its result would bring the removed
            // files back, so the scan starts again.
            setPhotos(photos.filter { !ids.contains($0.id) })
            rescan()
            return
        }
        exifTask?.cancel()
        scanGeneration += 1
        setPhotos(photos.filter { !ids.contains($0.id) })
        let pending = photos.indices.filter { !photos[$0].exifChecked }
        if !pending.isEmpty { startExifPass(pending, generation: scanGeneration) }
    }

    // MARK: Faces

    var isAnalyzingFaces: Bool { faceTotal > 0 && faceDone < faceTotal }

    func cancelFaceAnalysis() {
        faceTask?.cancel()
    }

    /// Detects faces in the photos of the list that have not been analyzed yet,
    /// and suggests a name based on already named faces.
    func analyzeFaces(in list: [Photo]) {
        guard !isAnalyzingFaces, !facePreparing else { return }
        let targets = list.filter { p in
            guard !p.isVideo, !p.offline else { return false }
            let m = metadata[p.id]
            return !(m?.facesAnalyzed ?? false) && (m?.faces.isEmpty ?? true)
        }
        guard !targets.isEmpty else {
            notice = L("Les visages de ces photos ont déjà été analysés.")
            return
        }
        let items = targets.map { (id: $0.id, url: $0.url, rotation: rotation(of: $0)) }

        // Examples: for each person, their largest named faces.
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
                await ImageLoader.waitUntilIdle(maxSeconds: 15)
                let end = min(start + 6, items.count)
                let batch = Array(items[start..<end])
                let detected = await Watchdog.map(batch, width: 2, timeout: 60) {
                    FaceEngine.analyze(url: $0.url, rotation: $0.rotation, references: refs)
                }
                let results = zip(batch, detected).map { (id: $0.0.id, faces: $0.1 ?? []) }
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
            notice = Task.isCancelled
                ? L("Analyse des visages interrompue : \(found) visages trouvés, \(suggested) noms proposés. Ils sont dans « Visages à nommer ».")
                : L("Analyse des visages terminée : \(found) visages trouvés, \(suggested) noms proposés. Ils sont dans « Visages à nommer ».")
        }
    }

    // MARK: Grouping unknown faces

    /// A face of a photo, found again by its position (indices move when a face is removed).
    struct FaceRef: Hashable, Identifiable {
        let photo: String
        let x: Double
        let y: Double
        var id: String { "\(photo)|\(x)|\(y)" }
    }

    /// Faces that look alike. `suggestion`: the known person they resemble, if any.
    struct FaceGroup: Identifiable {
        let id: Int
        var faces: [FaceRef]
        var suggestion: String?
    }

    private(set) var faceGroups: [FaceGroup]?
    private(set) var isGroupingFaces = false
    private(set) var faceGroupDone = 0
    private(set) var faceGroupTotal = 0
    /// Unnamed faces that resemble no other (they stay in the grid).
    private(set) var faceGroupSingles = 0
    @ObservationIgnored private var faceGroupTask: Task<Void, Never>?

    func faceIndex(_ ref: FaceRef) -> Int? {
        metadata[ref.photo]?.faces.firstIndex { $0.name == nil && $0.x == ref.x && $0.y == ref.y }
    }

    func cancelFaceGrouping() { faceGroupTask?.cancel() }

    /// Reference fingerprints of the named people (built on first use).
    private func loadReferences() async -> FaceReferences {
        let refs: FaceReferences
        if let r = faceRefs { refs = r } else { refs = await Task.detached { FaceReferences.load() }.value }
        faceRefs = refs
        var examples: [String: [(url: URL, rotation: Int, rect: CGRect)]] = [:]
        for (path, m) in metadata where indexByID[path] != nil {
            guard let p = photo(id: path), !p.isVideo, !p.offline else { continue }
            for f in m.faces where f.w >= 0.05 { if let n = f.name { examples[n, default: []].append((p.url, m.rotation, faceRect(f, in: p))) } }
        }
        let known = refs.people
        let missing = examples.filter { !known.contains($0.key) }.mapValues { list in
            Array(list.sorted { $0.rect.width > $1.rect.width }.prefix(FaceReferences.samplesPerPerson * 3).shuffled()
                .prefix(FaceReferences.samplesPerPerson))
        }
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
        return refs
    }

    /// Groups the unnamed faces: first those that resemble a known person (name suggested),
    /// then the unknown ones that look alike, so that a whole group is named at once.
    func groupUnknownFaces() {
        guard !isGroupingFaces else { return }
        var items: [(ref: FaceRef, url: URL, rotation: Int, rect: CGRect)] = []
        for (path, m) in metadata where m.hasUnnamedFaces {
            guard let p = photo(id: path), !p.isVideo, !p.offline else { continue }
            for f in m.faces where f.name == nil && f.w >= FaceEngine.minFaceWidth {
                items.append((FaceRef(photo: path, x: f.x, y: f.y), p.url, m.rotation, faceRect(f, in: p)))
            }
        }
        guard !items.isEmpty else {
            notice = offlineCount > 0 ? L("Aucun visage à regrouper sur les disques branchés.") : L("Aucun visage à regrouper.")
            return
        }
        items.sort { $0.ref.id < $1.ref.id }
        isGroupingFaces = true
        faceGroupDone = 0
        faceGroupTotal = items.count
        faceGroupTask = Task {
            let refs = await loadReferences()
            var cache = await Task.detached(priority: .utility) { FaceVectorCache.load() }.value
            var todo = items.filter { cache.vectors[$0.ref.id] == nil }
            faceGroupDone = items.count - todo.count
            var sinceSave = 0
            while !todo.isEmpty, !Task.isCancelled {
                await ImageLoader.waitUntilIdle(maxSeconds: 2)
                let batch = Array(todo.prefix(12))
                todo.removeFirst(batch.count)
                let vectors = await Watchdog.map(batch, width: 3, timeout: 60) { it -> [Float]? in
                    FaceEngine.referencePrint(url: it.url, rotation: it.rotation, rect: it.rect).flatMap(FaceClusterer.vector)
                }
                // Unreadable face: an empty vector, so that it is not tried again every time.
                for (it, v) in zip(batch, vectors) { cache.vectors[it.ref.id] = (v ?? nil) ?? [] }
                faceGroupDone += batch.count
                sinceSave += batch.count
                if sinceSave >= 300 {
                    sinceSave = 0
                    let snapshot = cache
                    Task.detached(priority: .utility) { snapshot.save() }
                }
            }
            let snapshot = cache
            Task.detached(priority: .utility) { snapshot.save() }
            let usable = items.compactMap { it -> (ref: FaceRef, vector: [Float])? in
                guard let v = cache.vectors[it.ref.id], !v.isEmpty else { return nil }
                return (it.ref, v)
            }
            let result = await Task.detached(priority: .userInitiated) { () -> (named: [(Int, String, Double)], clusters: [[Int]]) in
                // 1. Known people: mean distance to the 3 closest examples, as for recognition.
                let people = refs.vectors()
                var named: [(Int, String, Double)] = []
                var unknown: [Int] = []
                for (i, u) in usable.enumerated() {
                    var best: (String, Double)?
                    for (name, samples) in people {
                        let ds = samples.map { Double(FaceClusterer.distance(u.vector, $0)) }.sorted().prefix(3)
                        guard !ds.isEmpty else { continue }
                        let d = ds.reduce(0, +) / Double(ds.count)
                        if best == nil || d < best!.1 { best = (name, d) }
                    }
                    if let best, best.1 < FaceReferences.threshold { named.append((i, best.0, best.1)) } else { unknown.append(i) }
                }
                // 2. The others: grouped by resemblance.
                let clusters = FaceClusterer.cluster(unknown.map { usable[$0].vector }).map { $0.map { unknown[$0] } }
                return (named, clusters)
            }.value
            // Suggested names are stored with the faces (also shown in the grid and the inspector).
            for (i, name, score) in result.named {
                let ref = usable[i].ref
                if let k = faceIndex(ref) {
                    metadata[ref.photo]!.faces[k].suggestion = name
                    metadata[ref.photo]!.faces[k].score = score
                }
            }
            var groups: [FaceGroup] = []
            let byName = Dictionary(grouping: result.named, by: { $0.1 })
            for (name, list) in byName.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
                groups.append(FaceGroup(id: groups.count, faces: list.sorted { $0.2 < $1.2 }.map { usable[$0.0].ref }, suggestion: name))
            }
            for c in result.clusters where c.count > 1 {
                groups.append(FaceGroup(id: groups.count, faces: c.map { usable[$0].ref }, suggestion: nil))
            }
            faceGroupSingles = result.clusters.filter { $0.count == 1 }.count
            faceGroups = groups
            isGroupingFaces = false
            Debug.log("visages : \(usable.count) empreintes, \(byName.count) personnes proposées (\(result.named.count) visages), \(result.clusters.filter { $0.count > 1 }.count) groupes inconnus, \(faceGroupSingles) isolés")
            metadataChanged()
        }
    }

    /// Names all the faces of a group at once.
    func nameFaces(_ refs: [FaceRef], as raw: String, group: Int) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var examples: [(URL, Int, CGRect)] = []
        for ref in refs {
            guard let k = faceIndex(ref), var m = metadata[ref.photo] else { continue }
            m.faces[k].name = name
            m.faces[k].suggestion = nil
            m.faces[k].score = nil
            if !m.people.contains(name) {
                m.people.append(name)
                m.people.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            metadata[ref.photo] = m
            if examples.count < 6, let p = photo(id: ref.photo) { examples.append((p.url, m.rotation, faceRect(m.faces[k], in: p))) }
        }
        dropFromGroup(refs, group: group)
        metadataChanged()
        Task.detached(priority: .utility) { [faceRefs] in
            guard let known = faceRefs else { return }
            for (url, rotation, rect) in examples {
                if let fp = FaceEngine.referencePrint(url: url, rotation: rotation, rect: rect) { known.add(fp, for: name) }
            }
            known.save()
        }
    }

    /// "Ce ne sont pas des visages" / faces of strangers: the regions are removed.
    func removeFaces(_ refs: [FaceRef], group: Int) {
        for ref in refs {
            guard let k = faceIndex(ref) else { continue }
            metadata[ref.photo]!.faces.remove(at: k)
        }
        dropFromGroup(refs, group: group)
        metadataChanged()
    }

    /// Takes faces out of a group without changing them (they stay "à nommer").
    func dropFromGroup(_ refs: [FaceRef], group: Int) {
        guard var groups = faceGroups, let g = groups.firstIndex(where: { $0.id == group }) else { return }
        let gone = Set(refs)
        groups[g].faces.removeAll { gone.contains($0) }
        if groups[g].faces.isEmpty { groups.remove(at: g) }
        faceGroups = groups
    }

    func closeFaceGroups() { faceGroups = nil }

    /// Names a face (and adds it to that person's examples).
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

    /// Removes a face (false detection); the person is removed only if no face carries that name anymore.
    func removeFace(_ photo: Photo, at index: Int) {
        guard var m = metadata[photo.id], m.faces.indices.contains(index) else { return }
        let removed = m.faces.remove(at: index)
        if let n = removed.name, !m.faces.contains(where: { $0.name == n }) { m.people.removeAll { $0 == n } }
        metadata[photo.id] = m
        metadataChanged()
    }

    // MARK: Content analysis

    func toggleContentPause() {
        contentPaused.toggle()
        UserDefaults.standard.set(contentPaused, forKey: "contentPaused")
        if contentPaused {
            contentTask?.cancel()
            contentTask = nil
            contentRun += 1
        } else {
            startContentPass()
        }
    }

    /// Analyzes not-yet-analyzed photos in the background (newest first).
    /// Fills the thumbnail cache along the way. Resumes where it left off.
    func startContentPass() {
        guard !contentPaused else { return }
        // A new pass always replaces the previous one (even if it is still stuck or stopping):
        // before, a restart requested at the wrong moment was ignored and analysis froze.
        contentTask?.cancel()
        contentTask = nil
        contentRun += 1
        let run = contentRun
        let pending = byDateNewest.filter { p in
            guard !p.offline else { return false }
            guard let e = analysis[p.id] else { return true }
            return e.s != p.fileSize || abs(e.m - p.modificationDate.timeIntervalSince1970) >= 1
                || (e.v ?? 1) < ContentAnalyzer.version
        }
        guard !pending.isEmpty else {
            contentTotal = 0
            contentDone = 0
            return
        }
        contentTotal = pending.count
        contentDone = 0
        contentTask = Task {
            var start = 0
            var sinceSave = 0
            while start < pending.count {
                // Priority to displayed thumbnails and face analysis, but never wait forever.
                await ImageLoader.waitUntilIdle(maxSeconds: 15)
                var waited = 0
                while isAnalyzingFaces, waited < 75, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    waited += 1
                }
                if Task.isCancelled || run != contentRun { return }
                let end = min(start + 8, pending.count)
                let batch = Array(pending[start..<end])
                // Each photo gets at most 60 s: a file that blocks a decoder no longer freezes the pass.
                let results = await Watchdog.map(batch, width: 4, timeout: 60) { ContentAnalyzer.analyze($0) }
                if run != contentRun { return }
                var stuck: [String] = []
                for (p, e) in zip(batch, results) {
                    if let e {
                        analysis[p.id] = e
                    } else {
                        // Marked as analyzed (empty) so it is not retried at every launch.
                        analysis[p.id] = AnalysisEntry(s: p.fileSize, m: p.modificationDate.timeIntervalSince1970,
                                                       v: ContentAnalyzer.version)
                        stuck.append(p.id)
                        Debug.log("analyse : délai dépassé pour \(p.url.path)")
                    }
                }
                if !stuck.isEmpty {
                    for id in stuck { damaged[id] = L("Analyse impossible (le fichier bloque le décodage)") }
                    save()
                }
                contentDone = end
                start = end
                Debug.log("contenu : \(end) / \(pending.count) (passe \(run))")
                sinceSave += batch.count
                if sinceSave >= 1500 {
                    sinceSave = 0
                    saveAnalysis()
                    recomputeAnalysisDerived()
                }
            }
            guard run == contentRun else { return }
            Debug.log("contenu : analyse terminée (passe \(run))")
            saveAnalysis()
            recomputeAnalysisDerived()
            contentTotal = 0
            contentDone = 0
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
    func recognizedText(of photo: Photo) -> String? { analysis[photo.id]?.t }

    func rejectReason(of photo: Photo) -> RejectReason? {
        guard !(metadata[photo.id]?.qualityOK ?? false), let e = analysis[photo.id] else { return nil }
        return RejectReason.reason(for: e)
    }

    /// "Ce n'est pas raté" (not a failure): the photo no longer appears among failed photos.
    func markQualityOK(_ photos: [Photo]) {
        for p in photos { metadata[p.id, default: PhotoMetadata()].qualityOK = true }
        metadataChanged()
        recomputeAnalysisDerived()
    }

    /// Score used to pick the best photo of a series.
    func qualityScore(_ id: String) -> Float {
        guard let e = analysis[id] else { return -10 }
        return (e.a ?? 0) * 10 + min((e.b ?? 0) / 500, 2) + Float(metadata[id]?.richness ?? 0)
    }

    // MARK: Similar photos

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

    /// Keeps the best photo of each series and moves the others to the Trash
    /// (ratings, people and albums are carried over to the kept one).
    func trashSimilarExtras() {
        guard let groups = similarGroups else { return }
        trashSimilar(in: groups)
    }

    /// Right-click on similar photos: keeps the best photo (or `keep`) of each series touched,
    /// the other photos of those series go to the Trash.
    func keepInSimilar(_ ids: Set<String>, keep: String? = nil) {
        let touched = series(containing: ids, in: similarGroups).map { g in
            keep.map { k in g.contains(k) ? [k] + g.filter { $0 != k } : g } ?? g
        }
        trashSimilar(in: touched)
    }

    /// Each group: the photo to keep first, then the ones to remove.
    private func trashSimilar(in selected: [[String]]) {
        let steps = selected.flatMap { g in g.dropFirst().map { TrashStep(remove: $0, into: g[0]) } }
        performTrash(steps) { [self] r in
            let n = r.removed.count
            notice = selected.count == 1
                ? L(n, one: "1 photo de la série mise à la corbeille.", other: "\(n) photos de la série mises à la corbeille.")
                : L("\(n) photos mises à la corbeille ; une photo est conservée dans chacune des \(selected.count) séries.")
        }
    }

    /// Comparison view: `keep` stay, `remove` go to the Trash (annotations merged into the first
    /// kept photo), and the series is considered sorted (it leaves the list).
    func resolveSeries(keep: [Photo], remove: [Photo]) {
        let ids = Set((keep + remove).map(\.id))
        func dismiss() {
            if let g = similarGroups {
                similarGroups = g.filter { !$0.contains(where: ids.contains) }
                similarBest = Set((similarGroups ?? []).compactMap(\.first))
                similarRevision += 1
            }
        }
        guard !remove.isEmpty else { dismiss(); return }
        performTrash(remove.map { TrashStep(remove: $0.id, into: keep.first?.id) }) { [self] r in
            dismiss()
            notice = L(r.removed.count, one: "1 photo mise à la corbeille", other: "\(r.removed.count) photos mises à la corbeille")
                + ", " + L(keep.count, one: "1 gardée.", other: "\(keep.count) gardées.")
        }
    }

    // MARK: Places

    func place(of photo: Photo) -> Place? {
        guard let la = photo.latitude, let lo = photo.longitude,
              let p = places[PlaceStore.cell(la, lo)], !p.label.isEmpty else { return nil }
        return p
    }

    /// Short name used in lists ("Avoriaz").
    func placeName(of photo: Photo) -> String? {
        guard let p = place(of: photo) else { return nil }
        return p.locality ?? p.area ?? p.country
    }

    /// Looks up the names of visited areas, most photographed first.
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
                    if failures > 20 { break } // offline: will resume at next launch
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                failures = 0
                i += 1
                placeDone = i
                if i % 25 == 0 { savePlaces(); recomputePlaces() }
                try? await Task.sleep(for: .milliseconds(1300)) // Apple service rate limit
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

    // MARK: Disconnected drive and folder watching

    /// Coalesced rescan (a burst of disk events → a single rescan).
    func rescanSoon() {
        rescanSoonTask?.cancel()
        rescanSoonTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            while isScanning || isTrashing { try? await Task.sleep(for: .seconds(2)) }
            rescan()
        }
    }

    private func startWatching(_ reachable: [URL]) {
        let paths = reachable.map(\.path)
        watcher = FolderWatcher(paths: paths) { [weak self] in
            MainActor.assumeIsolated { self?.rescanSoon() }
        }
    }

    // MARK: Locations added by hand

    /// Sets (or clears, with nil) the location of photos without GPS. The file is not modified
    /// (the location is written to the XMP when that option is on).
    func setLocation(_ list: [Photo], latitude: Double?, longitude: Double?) {
        for p in list {
            var m = metadata[p.id] ?? PhotoMetadata()
            m.lat = latitude
            m.lon = longitude
            metadata[p.id] = m
        }
        applyManualLocations(list.map(\.id))
    }

    /// Photos without a location: take the one of the closest geotagged photo in time (≤ 2 h).
    func fillLocationsFromNeighbors(_ list: [Photo]) {
        let located = byDateNewest.filter(\.hasLocation).reversed() as [Photo] // chronological order
        let dates = located.map(\.date)
        var changed: [String] = []
        for p in list where !p.hasLocation && !p.offline {
            // Binary search for the closest neighbor.
            var lo = 0, hi = dates.count
            while lo < hi { let mid = (lo + hi) / 2; if dates[mid] < p.date { lo = mid + 1 } else { hi = mid } }
            let candidates = [lo - 1, lo].filter { dates.indices.contains($0) }
            guard let best = candidates.min(by: { abs(dates[$0].timeIntervalSince(p.date)) < abs(dates[$1].timeIntervalSince(p.date)) }),
                  abs(dates[best].timeIntervalSince(p.date)) <= 2 * 3600,
                  let la = located[best].latitude, let lon = located[best].longitude else { continue }
            metadata[p.id, default: PhotoMetadata()].lat = la
            metadata[p.id, default: PhotoMetadata()].lon = lon
            changed.append(p.id)
        }
        applyManualLocations(changed)
        let skipped = list.filter { !$0.hasLocation }.count - changed.count
        notice = L("\(changed.count) photo(s) localisée(s) d'après les photos prises à moins de 2 h d'intervalle.")
            + (skipped > 0 ? L(" \(skipped) sans voisine géolocalisée.") : "")
    }

    private func applyManualLocations(_ ids: [String]) {
        for id in ids {
            guard let i = indexByID[id] else { continue }
            let m = metadata[id]
            // Removing a manual location gives way to the original GPS (re-read at the next scan).
            photos[i].latitude = m?.lat ?? (photos[i].exifChecked ? nil : photos[i].latitude)
            photos[i].longitude = m?.lon ?? (photos[i].exifChecked ? nil : photos[i].longitude)
        }
        if !ids.isEmpty {
            resort()
            recomputeCounts()
            recomputePlaces()
            revision += 1
            metadataChanged()
            startPlacePass()
            if ids.contains(where: { metadata[$0]?.lat == nil }) { rescanSoon() }
        }
    }

    func hasManualLocation(_ photo: Photo) -> Bool { metadata[photo.id]?.lat != nil }

    // MARK: Edits

    func edits(of photo: Photo) -> PhotoEdits? { metadata[photo.id]?.edits }

    func setEdits(_ edits: PhotoEdits?, for photo: Photo) {
        metadata[photo.id, default: PhotoMetadata()].edits = (edits?.isIdentity ?? true) ? nil : edits
        metadataChanged()
    }

    var editedCount: Int { metadata.values.reduce(0) { $0 + (($1.edits?.isIdentity ?? true) ? 0 : 1) } }

    // MARK: XMP files

    /// Turns on automatic writing: every rating, tag, person, caption or location is
    /// written to an XMP file next to the photo (merged with another application's one).
    func setWriteXMP(_ on: Bool) {
        writeXMP = on
        UserDefaults.standard.set(on, forKey: "writeXMP")
        if on { scheduleXMPWrite(immediately: true) }
    }

    private func xmpContent(_ id: String) -> XMPSidecar.Content {
        let m = metadata[id]
        return XMPSidecar.Content(rating: m?.rating ?? 0, tags: m?.tags ?? [], people: m?.people ?? [],
                                  caption: m?.caption ?? "", latitude: m?.lat, longitude: m?.lon,
                                  date: m?.date.map { Date(timeIntervalSince1970: $0) })
    }

    private func signature(_ c: XMPSidecar.Content) -> String {
        "\(c.rating)|\(c.tags.joined(separator: ","))|\(c.people.joined(separator: ","))|\(c.caption)|\(c.latitude ?? 0),\(c.longitude ?? 0)|\(c.date?.timeIntervalSince1970 ?? 0)"
    }

    private func scheduleXMPWrite(immediately: Bool = false) {
        xmpTask?.cancel()
        xmpTask = Task {
            if !immediately { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            // Only what changed since the last write.
            var jobs: [(id: String, url: URL, content: XMPSidecar.Content, sig: String)] = []
            for (id, _) in metadata {
                guard let p = photo(id: id), !p.offline else { continue }
                let c = xmpContent(id)
                let sig = signature(c)
                let empty = c == XMPSidecar.Content()
                if xmpState[id] == sig || (empty && xmpState[id] == nil) { continue }
                jobs.append((id, p.url, c, sig))
            }
            guard !jobs.isEmpty else { return }
            isWritingXMP = true
            let results = await Task.detached(priority: .utility) { () -> [(String, String)] in
                jobs.compactMap { job in
                    (try? XMPSidecar.write(job.content, for: job.url)) != nil ? (job.id, job.sig) : nil
                }
            }.value
            for (id, sig) in results { xmpState[id] = sig }
            isWritingXMP = false
            let state = xmpState, url = xmpStateURL
            Task.detached(priority: .background) {
                if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
            }
            if immediately { notice = L("\(results.count) fichier(s) XMP écrit(s) ou mis à jour.") }
        }
    }

    /// Imports information from existing XMP files (Mylio, Lightroom, digiKam…):
    /// ratings, keywords, people and face regions, captions, locations. Nothing is overwritten.
    func importSidecars() {
        guard !isImportingXMP else { return }
        isImportingXMP = true
        let paths = sidecarPaths
        // Mapping "folder/name without extension" → photos (for "photo.xmp" sidecars).
        var byStem: [String: [String]] = [:]
        for p in photos where !p.offline { byStem[p.url.deletingPathExtension().path, default: []].append(p.id) }
        let ids = Set(indexByID.keys)
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [(String, XMPSidecar.Content)] in
                paths.compactMap { path -> (String, XMPSidecar.Content)? in
                    let withoutXMP = String(path.dropLast(4))
                    let target: String?
                    if ids.contains(withoutXMP) {
                        target = withoutXMP
                    } else if let list = byStem[withoutXMP], list.count == 1 {
                        target = list[0]
                    } else {
                        target = nil
                    }
                    guard let target, let c = XMPSidecar.read(URL(fileURLWithPath: path)) else { return nil }
                    return (target, c)
                }
            }.value
            var photosChanged = 0, people = Set<String>(), ratings = 0, located: [String] = []
            for (id, c) in found {
                var m = metadata[id] ?? PhotoMetadata()
                let before = m
                if c.rating > m.rating { m.rating = c.rating; ratings += 1 }
                for t in c.tags where !m.tags.contains(t) { m.tags.append(t) }
                for n in c.people where !m.people.contains(n) { m.people.append(n) }
                people.formUnion(c.people)
                if m.caption.isEmpty, !c.caption.isEmpty { m.caption = c.caption }
                let rects = c.regions.filter { $0.w > 0 }
                if m.faces.isEmpty, !rects.isEmpty { m.faces = rects }
                if let la = c.latitude, let lo = c.longitude, let p = photo(id: id), !p.hasLocation, m.lat == nil {
                    m.lat = la
                    m.lon = lo
                    located.append(id)
                }
                if m != before {
                    metadata[id] = m
                    photosChanged += 1
                }
            }
            xmpImported = true
            UserDefaults.standard.set(true, forKey: "xmpImported")
            isImportingXMP = false
            if located.isEmpty { metadataChanged() } else { applyManualLocations(located) }
            notice = L("\(found.count) fichiers XMP lus : \(photosChanged) photos enrichies (\(people.count) personnes, \(ratings) notes, \(located.count) lieux). Vos fichiers n'ont pas été modifiés.")
        }
    }

    func dismissXMPBanner() {
        xmpImported = true
        UserDefaults.standard.set(true, forKey: "xmpImported")
    }

    // MARK: People management

    /// Renames a person everywhere (photos, faces, recognition examples).
    /// If the new name already exists, the two people are merged.
    func renamePerson(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        for key in metadata.keys {
            guard var m = metadata[key] else { continue }
            var changed = false
            if m.people.contains(old) {
                m.people = m.people.map { $0 == old ? new : $0 }
                m.people = m.people.enumerated().filter { m.people.firstIndex(of: $0.element) == $0.offset }.map(\.element)
                m.people.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                changed = true
            }
            for i in m.faces.indices {
                if m.faces[i].name == old { m.faces[i].name = new; changed = true }
                if m.faces[i].suggestion == old { m.faces[i].suggestion = new; changed = true }
            }
            if changed { metadata[key] = m }
        }
        if hiddenPeople.remove(old) != nil, !peopleNames.contains(new) { hiddenPeople.insert(new) }
        if let cover = personCovers.removeValue(forKey: old), personCovers[new] == nil { personCovers[new] = cover }
        if let refs = faceRefs {
            refs.rename(old, to: new)
            Task.detached(priority: .utility) { refs.save() }
        } else {
            Task.detached(priority: .utility) {
                let refs = FaceReferences.load()
                refs.rename(old, to: new)
                refs.save()
            }
        }
        metadataChanged()
    }

    private var peopleNames: Set<String> { Set(allPeople.map(\.name)) }

    func setHidden(_ name: String, _ hidden: Bool) {
        if hidden { hiddenPeople.insert(name) } else { hiddenPeople.remove(name) }
        save()
    }

    /// People shown in the sidebar (hidden ones excluded).
    var visiblePeople: [(name: String, count: Int)] { allPeople.filter { !hiddenPeople.contains($0.name) } }

    func setCover(_ photo: Photo, faceIndex: Int, for name: String) {
        personCovers[name] = "\(photo.id)#\(faceIndex)"
        save()
    }

    /// Face used as a person's portrait: the chosen one, otherwise the largest.
    func cover(of name: String) -> (photo: Photo, rect: CGRect, rotation: Int)? {
        var ref: (String, Int)?
        if let c = personCovers[name], let hash = c.lastIndex(of: "#"), let i = Int(c[c.index(after: hash)...]) {
            ref = (String(c[..<hash]), i)
        }
        if ref == nil { ref = defaultCovers[name] }
        guard let (id, i) = ref, let p = photo(id: id), let faces = metadata[id]?.faces, faces.indices.contains(i),
              faces[i].w > 0 else { return nil }
        return (p, faceRect(faces[i], in: p), metadata[id]?.rotation ?? 0)
    }

    /// Likely duplicates: same name up to case or accents, or first name only of a full name.
    /// Each pair points from the person to merge to the person to keep.
    var duplicatePeople: [(from: String, into: String)] {
        let people = allPeople
        func norm(_ s: String) -> String { s.searchFolded.trimmingCharacters(in: .whitespaces) }
        var pairs: [(String, String)] = []
        for (i, a) in people.enumerated() {
            for b in people[(i + 1)...] {
                let na = norm(a.name), nb = norm(b.name)
                let firstA = na.split(separator: " ").first, firstB = nb.split(separator: " ").first
                let similar = na == nb
                    || (na.split(separator: " ").count == 1 && firstA == firstB)
                    || (nb.split(separator: " ").count == 1 && firstA == firstB)
                guard similar else { continue }
                // Keep the most complete name, then the one with capitals, then the most frequent.
                func score(_ p: (name: String, count: Int)) -> (Int, Int, Int) {
                    (p.name.split(separator: " ").count, p.name == p.name.lowercased() ? 0 : 1, p.count)
                }
                pairs.append(score(a) < score(b) ? (a.name, b.name) : (b.name, a.name))
            }
        }
        return pairs.map { (from: $0.0, into: $0.1) }
    }

    // MARK: Date correction

    /// Shifts dates (e.g. wrong camera clock: +1 h, -1 year…).
    func shiftDates(_ list: [Photo], by components: DateComponents) {
        let cal = Calendar.current
        for p in list {
            guard let d = cal.date(byAdding: components, to: p.date) else { continue }
            metadata[p.id, default: PhotoMetadata()].date = d.timeIntervalSince1970
        }
        applyDateOverrides(list.map(\.id))
    }

    /// Sets an exact date (e.g. scanned photos). With `keepSpacing`, the oldest one
    /// gets this date and the others keep their offset from it.
    func setDates(_ list: [Photo], to target: Date, keepSpacing: Bool) {
        let earliest = list.map(\.date).min() ?? target
        for p in list {
            let d = keepSpacing ? target.addingTimeInterval(p.date.timeIntervalSince(earliest)) : target
            metadata[p.id, default: PhotoMetadata()].date = d.timeIntervalSince1970
        }
        applyDateOverrides(list.map(\.id))
    }

    func resetDates(_ list: [Photo]) {
        for p in list { metadata[p.id]?.date = nil }
        applyDateOverrides(list.map(\.id))
    }

    func hasDateOverride(_ photo: Photo) -> Bool { metadata[photo.id]?.date != nil }

    private func applyDateOverrides(_ ids: [String]) {
        for id in ids {
            guard let i = indexByID[id] else { continue }
            photos[i].dateOverride = metadata[id]?.date.map { Date(timeIntervalSince1970: $0) }
        }
        guard !ids.isEmpty else { return }
        recomputeFolders()
        resort()
        revision += 1
        metadataChanged()
    }

    // MARK: File integrity

    var isCheckingIntegrity: Bool { integrityTotal > 0 && integrityDone < integrityTotal }

    /// Checks that every file is readable and complete (empty, truncated, unreadable files).
    func checkIntegrity() {
        guard integrityTask == nil else { return }
        let items = photos.filter { !$0.offline }
        integrityTotal = items.count
        integrityDone = 0
        integrityTask = Task {
            var found: [String: String] = [:]
            var start = 0
            while start < items.count, !Task.isCancelled {
                await ImageLoader.waitUntilIdle(maxSeconds: 15)
                let end = min(start + 64, items.count)
                let batch = Array(items[start..<end])
                let checked = await Watchdog.map(batch, width: 4, timeout: 60) { IntegrityChecker.problem($0) }
                let results = checked.map { $0 ?? L("Lecture bloquée (fichier ou disque défaillant ?)") }
                for (p, r) in zip(batch, results) { if let r { found[p.id] = r } }
                integrityDone = end
                start = end
            }
            let completed = start >= items.count
            if completed {
                damaged = found
                lastIntegrityCheck = Date()
            } else {
                damaged.merge(found) { _, new in new }
            }
            integrityTotal = 0
            integrityDone = 0
            integrityTask = nil
            save()
            revision += 1
            notice = completed
                ? (found.isEmpty ? L("Vérification terminée : tous les fichiers sont lisibles.")
                                 : L("Vérification terminée : \(found.count) fichier(s) à problème, listés dans « Fichiers abîmés »."))
                : L("Vérification interrompue (\(found.count) problème(s) trouvés jusque-là).")
        }
    }

    func cancelIntegrityCheck() { integrityTask?.cancel() }

    func damageReason(of photo: Photo) -> String? { damaged[photo.id] }

    // MARK: Backup

    func chooseBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choisir")
        panel.message = L("Choisissez le dossier de sauvegarde (idéalement sur un autre disque)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if root(containing: url.path) != nil || roots.contains(where: { url.path.hasPrefix($0.path) || $0.path.hasPrefix(url.path + "/") }) {
            notice = L("Ce dossier fait partie (ou contient) un dossier analysé : choisissez un emplacement à part, de préférence sur un autre disque.")
            return
        }
        backupDestination = url
        UserDefaults.standard.set(url.path, forKey: "backupDestination")
        backupPlan = nil
        planBackup()
    }

    /// Is the backup folder on the same drive as the photos?
    var backupOnSameVolume: Bool {
        guard let dest = backupDestination, let root = roots.first else { return false }
        let a = try? dest.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let b = try? root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        return a != nil && a == b
    }

    /// Computes what is missing from the backup (absent files, or different size or date).
    func planBackup() {
        guard let dest = backupDestination, !isPlanningBackup, !isBackingUp else { return }
        isPlanningBackup = true
        let sources = backupSources()
        let roots = self.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        Task {
            let plan = await Task.detached(priority: .userInitiated) { BackupEngine.plan(sources, roots: roots, destination: dest) }.value
            backupPlan = plan
            isPlanningBackup = false
        }
    }

    /// Photos, videos, XMP and Picasa files of the watched folders (exclusions respected).
    private func backupSources() -> [(URL, Int64)] {
        var list = photos.filter { !$0.offline }.map { ($0.url, $0.fileSize) }
        for path in sidecarPaths { list.append((URL(fileURLWithPath: path), -1)) }
        for ini in PicasaImporter.iniFiles(in: folders.map(\.path)) { list.append((ini, -1)) }
        return list
    }

    func startBackup() {
        guard let plan = backupPlan, let dest = backupDestination, !isBackingUp else { return }
        let free = (try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        if free > 0, free < plan.totalBytes + 200_000_000 {
            notice = L("Pas assez de place sur le disque de sauvegarde : il faut \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)), il reste \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)).")
            return
        }
        isBackingUp = true
        backupBytesDone = 0
        backupFilesDone = 0
        backupTask = Task {
            var errors = 0
            for chunk in stride(from: 0, to: plan.files.count, by: 20) {
                if Task.isCancelled { break }
                let batch = Array(plan.files[chunk..<min(chunk + 20, plan.files.count)])
                let result = await Task.detached(priority: .utility) { () -> (Int64, Int) in
                    var bytes: Int64 = 0, failed = 0
                    for f in batch {
                        if BackupEngine.copy(f) { bytes += f.size } else { failed += 1 }
                    }
                    return (bytes, failed)
                }.value
                backupBytesDone += result.0
                backupFilesDone += batch.count
                errors += result.1
            }
            // Albumine's data (ratings, people, albums…): copied at every backup.
            await Task.detached(priority: .utility) { BackupEngine.copyLibraryData(to: dest) }.value
            let cancelled = Task.isCancelled
            isBackingUp = false
            if !cancelled, errors == 0 {
                lastBackup = Date()
                UserDefaults.standard.set(lastBackup, forKey: "lastBackup")
            }
            notice = (cancelled ? L("Sauvegarde interrompue : ") : L("Sauvegarde terminée : "))
                + L("\(backupFilesDone - errors) fichier(s) copiés (\(ByteCountFormatter.string(fromByteCount: backupBytesDone, countStyle: .file))).")
                + (errors > 0 ? L(" \(errors) erreur(s) : relancez la sauvegarde pour réessayer.") : "")
            backupPlan = nil
            planBackup()
        }
    }

    func cancelBackup() { backupTask?.cancel() }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        roots = store.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        metadata = store.metadata
        // Migration: faces imported from Picasa before v0.3 lacked the "raw" flag.
        for key in metadata.keys where !metadata[key]!.facesAnalyzed {
            for i in metadata[key]!.faces.indices where metadata[key]!.faces[i].raw == nil
                && metadata[key]!.faces[i].suggestion == nil && metadata[key]!.faces[i].score == nil {
                metadata[key]!.faces[i].raw = true
            }
        }
        picasaImported = store.picasaImported ?? false
        albumNames = store.albums ?? []
        excludedPaths = store.excluded ?? []
        hiddenPeople = Set(store.hiddenPeople ?? [])
        personCovers = store.personCovers ?? [:]
        damaged = store.damaged ?? [:]
        lastIntegrityCheck = store.lastIntegrityCheck
        preferredFolders = store.preferredFolders ?? []
        smartAlbums = store.smartAlbums ?? []
    }

    /// Immediate, synchronous save of the library, index and analysis (before quitting).
    func saveNow() {
        saveTask?.cancel()
        let store = Store(roots: roots.map(\.path), metadata: metadata.filter { !$0.value.isEmpty },
                          picasaImported: picasaImported, albums: albumNames, excluded: excludedPaths,
                          hiddenPeople: hiddenPeople.sorted(), personCovers: personCovers,
                          damaged: damaged, lastIntegrityCheck: lastIntegrityCheck,
                          preferredFolders: preferredFolders, smartAlbums: smartAlbums)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: storeURL, options: .atomic) }
        IndexStore.save(photos)
        AnalysisStore.save(analysis)
    }

    private func save() {
        let store = Store(roots: roots.map(\.path), metadata: metadata,
                          picasaImported: picasaImported, albums: albumNames, excluded: excludedPaths,
                          hiddenPeople: hiddenPeople.sorted(), personCovers: personCovers,
                          damaged: damaged, lastIntegrityCheck: lastIntegrityCheck,
                          preferredFolders: preferredFolders, smartAlbums: smartAlbums)
        let url = storeURL
        Task.detached(priority: .utility) {
            var s = store
            s.metadata = s.metadata.filter { !$0.value.isEmpty }
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        }
    }
}
