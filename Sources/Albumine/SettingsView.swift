import AppKit
import SwiftUI

/// Réglages (⌘,) : dossiers analysés, exclusions, options.
struct SettingsView: View {
    var body: some View {
        TabView {
            FoldersSettings()
                .tabItem { Label("Dossiers", systemImage: "folder") }
            OptionsSettings()
                .tabItem { Label("Options", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 500)
    }
}

/// Dossiers suivis et sous-dossiers exclus.
struct FoldersSettings: View {
    @Environment(PhotoLibrary.self) private var library
    @Etat private var rootToRemove: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dossiers analysés").font(.headline)
                Text("Albumine parcourt ces dossiers et leurs sous-dossiers. Les fichiers ne sont jamais déplacés.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    if library.roots.isEmpty {
                        Text("Aucun dossier. Cliquez sur « Ajouter un dossier… ».").foregroundStyle(.secondary)
                    }
                    ForEach(library.roots, id: \.path) { root in
                        rootRow(root)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 140)
                HStack {
                    Button {
                        library.addFolderWithPanel()
                    } label: {
                        Label("Ajouter un dossier…", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        library.rescan()
                    } label: {
                        Label("Rescanner", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isScanning)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Sous-dossiers exclus").font(.headline)
                Text("Ils ne sont plus analysés ni affichés (par exemple des sauvegardes ou des copies de téléphone).")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    if library.excludedPaths.isEmpty {
                        Text("Aucune exclusion.").foregroundStyle(.secondary)
                    }
                    ForEach(library.excludedPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Réintégrer") { library.includeAgain(path) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 90)
                HStack {
                    Button {
                        library.excludeFolderWithPanel()
                    } label: {
                        Label("Exclure un sous-dossier…", systemImage: "minus.circle")
                    }
                    .disabled(library.roots.isEmpty)
                    Spacer()
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Analyse…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .confirmationDialog("Retirer « \(rootToRemove?.lastPathComponent ?? "") » de la bibliothèque ?",
                            isPresented: Binding(get: { rootToRemove != nil }, set: { if !$0 { rootToRemove = nil } })) {
            Button("Retirer le dossier", role: .destructive) {
                if let r = rootToRemove { library.removeRoot(r) }
                rootToRemove = nil
            }
        } message: {
            Text("Les photos ne sont pas supprimées du disque : elles disparaissent seulement d'Albumine. Vos notes, personnes et albums sont conservés et réapparaîtront si vous rajoutez le dossier.")
        }
    }

    private func rootRow(_ root: URL) -> some View {
        let online = FileManager.default.fileExists(atPath: root.path)
        let count = library.count(under: root)
        return HStack(spacing: 10) {
            Image(systemName: online ? "folder.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(online ? Color.accentColor : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(root.lastPathComponent).font(.body.weight(.medium))
                Text(root.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(online ? "\(count.formatted()) éléments" : "Disque débranché · \(count.formatted()) éléments en cache")
                    .font(.caption2)
                    .foregroundStyle(online ? .secondary : Color.orange)
            }
            Spacer()
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Afficher dans le Finder")
            .disabled(!online)
            Button { library.excludeFolderWithPanel(in: root) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Exclure un sous-dossier de ce dossier")
            .disabled(!online)
            Button { rootToRemove = root } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Retirer ce dossier de la bibliothèque")
        }
        .padding(.vertical, 3)
    }
}

/// Options générales.
struct OptionsSettings: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        Form {
            Section("Analyse du contenu") {
                Toggle("Analyser le contenu des photos en arrière-plan", isOn: Binding(
                    get: { !library.contentPaused }, set: { on in if on == library.contentPaused { library.toggleContentPause() } }))
                Text("Recherche par contenu et par texte, photos similaires et ratées. Tout reste sur ce Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if library.isAnalyzingContent {
                    ProgressView(value: Double(library.contentDone), total: Double(max(library.contentTotal, 1))) {
                        Text("\(library.contentDone.formatted()) / \(library.contentTotal.formatted()) photos").font(.caption)
                    }
                }
            }
            Section("Fichiers XMP") {
                Toggle("Écrire les annotations dans des fichiers XMP", isOn: Binding(
                    get: { library.writeXMP }, set: { library.setWriteXMP($0) }))
                Text("Notes, étiquettes, personnes, légendes et lieux sont reportés à côté des photos, lisibles par Lightroom, digiKam, Mylio… Un XMP existant est complété, jamais écrasé.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Importer les fichiers XMP existants") { library.importSidecars() }
                        .disabled(library.isImportingXMP || library.sidecarCount == 0)
                    Text("\(library.sidecarCount.formatted()) trouvés").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Picasa") {
                Button("Importer depuis Picasa…") { library.importPicasa() }
                    .disabled(library.isImportingPicasa)
                Text("Personnes, albums, étoiles, rotations, légendes et retouches des fichiers .picasa.ini.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Données") {
                LabeledContent("Bibliothèque") {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) }
                }
                LabeledContent("Cache des miniatures") {
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.thumbnails]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
