import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(PhotoLibrary.self) private var library
    @Binding var selection: SidebarItem?

    var body: some View {
        let tags = library.allTags
        List(selection: $selection) {
            Section("Bibliothèque") {
                Label("Toutes les photos", systemImage: "photo.on.rectangle")
                    .badge(library.photoCount)
                    .tag(SidebarItem.all)
                Label("Étoilées", systemImage: "star")
                    .badge(library.starredCount)
                    .tag(SidebarItem.starred)
            }

            if !library.allPeople.isEmpty {
                Section("Personnes") {
                    ForEach(library.allPeople, id: \.name) { person in
                        Label(person.name, systemImage: "person.crop.circle")
                            .badge(person.count)
                            .tag(SidebarItem.person(person.name))
                    }
                }
            }

            if !library.allAlbums.isEmpty {
                Section("Albums") {
                    ForEach(library.allAlbums, id: \.name) { album in
                        Label(album.name, systemImage: "rectangle.stack")
                            .badge(album.count)
                            .tag(SidebarItem.album(album.name))
                    }
                }
            }

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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    library.addFolderWithPanel()
                } label: {
                    Label("Ajouter un dossier", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if library.isImportingPicasa {
                    ProgressView().controlSize(.small)
                    Text("Import Picasa…").font(.caption).foregroundStyle(.secondary)
                } else if library.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Analyse…").font(.caption).foregroundStyle(.secondary)
                } else if library.isReadingExif {
                    ProgressView(value: Double(library.exifDone), total: Double(library.exifTotal))
                        .frame(width: 60)
                    Text("Dates \(library.exifDone.formatted()) / \(library.exifTotal.formatted())")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .help("Lecture des dates de prise de vue en arrière-plan. Les photos sont triées par date de fichier en attendant.")
                }
            }
            .padding(10)
        }
    }
}
