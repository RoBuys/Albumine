import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(PhotoLibrary.self) private var library
    @Binding var selection: SidebarItem?
    /// Photos glissées sur un album (identifiants).
    let onDropToAlbum: (_ album: String, _ ids: [String]) -> Void

    @Etat private var creatingAlbum = false
    @Etat private var renamingAlbum: String?
    @Etat private var deletingAlbum: String?
    @Etat private var albumName = ""

    var body: some View {
        List(selection: $selection) {
            Section("Bibliothèque") {
                Label("Toutes les photos", systemImage: "photo.on.rectangle")
                    .badge(library.photoCount)
                    .tag(SidebarItem.all)
                if !library.memoryIDs.isEmpty {
                    Label("Souvenirs du jour", systemImage: "clock.arrow.circlepath")
                        .badge(library.memoryIDs.count)
                        .tag(SidebarItem.memories)
                }
                Label("Étoilées", systemImage: "star")
                    .badge(library.starredCount)
                    .tag(SidebarItem.starred)
                Label("Vidéos", systemImage: "film")
                    .badge(library.videoCount)
                    .tag(SidebarItem.videos)
                Label("Carte", systemImage: "map")
                    .badge(library.locatedCount)
                    .tag(SidebarItem.map)
                Label("Doublons", systemImage: "square.on.square")
                    .badge(library.duplicateGroups.map { $0.count } ?? 0)
                    .tag(SidebarItem.duplicates)
                Label("Photos similaires", systemImage: "square.stack.3d.down.right")
                    .badge(library.similarGroups.map { $0.count } ?? 0)
                    .tag(SidebarItem.similar)
                Label("Photos ratées", systemImage: "hand.thumbsdown")
                    .badge(library.rejectCount)
                    .tag(SidebarItem.rejects)
            }

            if !library.allPlaces.isEmpty {
                Section("Lieux") {
                    ForEach(library.allPlaces.prefix(40), id: \.name) { place in
                        Label(place.name, systemImage: "mappin.and.ellipse")
                            .badge(place.count)
                            .tag(SidebarItem.place(place.name))
                    }
                }
            }

            Section("Personnes") {
                Label("Visages à nommer", systemImage: "person.crop.circle.badge.questionmark")
                    .badge(library.unnamedFaceCount)
                    .tag(SidebarItem.unnamedFaces)
                ForEach(library.allPeople, id: \.name) { person in
                    Label(person.name, systemImage: "person.crop.circle")
                        .badge(person.count)
                        .tag(SidebarItem.person(person.name))
                }
            }

            Section {
                ForEach(library.allAlbums, id: \.name) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .badge(album.count)
                        .tag(SidebarItem.album(album.name))
                        .dropDestination(for: String.self) { ids, _ in
                            onDropToAlbum(album.name, ids)
                            return true
                        }
                        .contextMenu {
                            Button("Renommer…") { albumName = album.name; renamingAlbum = album.name }
                            Button("Supprimer l'album…", role: .destructive) { deletingAlbum = album.name }
                        }
                }
                if library.allAlbums.isEmpty {
                    Text("Glissez des photos ici après avoir créé un album")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                HStack {
                    Text("Albums")
                    Spacer()
                    Button { albumName = ""; creatingAlbum = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Nouvel album")
                }
            }

            let tags = library.allTags
            if !tags.isEmpty {
                Section("Étiquettes") {
                    ForEach(tags, id: \.name) { tag in
                        Label(tag.name, systemImage: "tag")
                            .badge(tag.count)
                            .tag(SidebarItem.tag(tag.name))
                    }
                }
            }

            Section("Dossiers") {
                ForEach(library.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(folder.count)
                        .tag(SidebarItem.folder(folder.path))
                        .help(folder.path)
                        .contextMenu {
                            Button("Afficher dans le Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                            }
                            if let root = library.root(containing: folder.path) {
                                Divider()
                                Button("Retirer « \(root.lastPathComponent) » de la bibliothèque") {
                                    if case .folder(let p) = selection, p.hasPrefix(root.path) { selection = .all }
                                    library.removeRoot(root)
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { status }
        .alert("Nouvel album", isPresented: $creatingAlbum) {
            TextField("Nom de l'album", text: $albumName)
            Button("Créer") { library.createAlbum(albumName) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Un album regroupe des photos de n'importe quels dossiers, sans les copier.")
        }
        .alert("Renommer l'album", isPresented: Binding(get: { renamingAlbum != nil },
                                                        set: { if !$0 { renamingAlbum = nil } })) {
            TextField("Nom de l'album", text: $albumName)
            Button("Renommer") {
                if let old = renamingAlbum {
                    library.renameAlbum(old, to: albumName)
                    if selection == .album(old) { selection = .album(albumName.trimmingCharacters(in: .whitespaces)) }
                }
                renamingAlbum = nil
            }
            Button("Annuler", role: .cancel) { renamingAlbum = nil }
        }
        .confirmationDialog("Supprimer l'album « \(deletingAlbum ?? "") » ?",
                            isPresented: Binding(get: { deletingAlbum != nil },
                                                 set: { if !$0 { deletingAlbum = nil } })) {
            Button("Supprimer l'album", role: .destructive) {
                if let name = deletingAlbum {
                    if selection == .album(name) { selection = .all }
                    library.deleteAlbum(name)
                }
                deletingAlbum = nil
            }
        } message: {
            Text("Les photos ne sont pas supprimées, seulement retirées de cet album.")
        }
    }

    /// Bas de la barre latérale : ajout de dossier et tâches en cours.
    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            if library.isImportingPicasa {
                progressRow("Import Picasa…", value: nil)
            }
            if library.isScanning {
                progressRow("Analyse des dossiers…", value: nil)
            } else if library.isReadingExif {
                progressRow("Dates et lieux \(library.exifDone.formatted()) / \(library.exifTotal.formatted())",
                            value: Double(library.exifDone) / Double(max(library.exifTotal, 1)))
                    .help("Lecture des dates de prise de vue et du GPS en arrière-plan.")
            }
            if library.isFindingDuplicates {
                progressRow("Doublons \(library.duplicateDone.formatted()) / \(library.duplicateTotal.formatted())",
                            value: Double(library.duplicateDone) / Double(max(library.duplicateTotal, 1)))
            }
            if library.isAnalyzingContent || library.contentPaused {
                HStack {
                    if library.contentPaused {
                        Text("Analyse du contenu en pause").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        progressRow("Contenu \(library.contentDone.formatted()) / \(library.contentTotal.formatted())",
                                    value: Double(library.contentDone) / Double(max(library.contentTotal, 1)))
                    }
                    Button { library.toggleContentPause() } label: {
                        Image(systemName: library.contentPaused ? "play.circle" : "pause.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(library.contentPaused ? "Reprendre l'analyse du contenu" : "Mettre l'analyse du contenu en pause")
                }
            }
            if library.isFindingPlaces {
                progressRow("Lieux \(library.placeDone.formatted()) / \(library.placeTotal.formatted())",
                            value: Double(library.placeDone) / Double(max(library.placeTotal, 1)))
                    .help("Recherche des noms de lieux (service Apple, une zone à la fois).")
            }
            if library.isWritingXMP {
                progressRow("Écriture des fichiers XMP…", value: nil)
            }
            if library.isImportingXMP {
                progressRow("Import des fichiers XMP…", value: nil)
            }
            if !library.offlineRoots.isEmpty {
                Label("Disque débranché (lecture seule)", systemImage: "externaldrive.badge.xmark")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if library.isTrashing {
                progressRow("Mise à la corbeille…", value: nil)
            }
            if library.facePreparing {
                progressRow("Visages : préparation des exemples…", value: nil)
            } else if library.isAnalyzingFaces {
                HStack {
                    progressRow("Visages \(library.faceDone.formatted()) / \(library.faceTotal.formatted())",
                                value: Double(library.faceDone) / Double(max(library.faceTotal, 1)))
                    Button { library.cancelFaceAnalysis() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless)
                        .help("Arrêter")
                }
            }
            Button {
                library.addFolderWithPanel()
            } label: {
                Label("Ajouter un dossier", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressRow(_ text: String, value: Double?) -> some View {
        HStack(spacing: 6) {
            if let value {
                ProgressView(value: value).frame(width: 50)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }
}
