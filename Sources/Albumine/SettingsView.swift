import AppKit
import SwiftUI

/// Réglages (⌘,) : dossiers analysés, exclusions, options.
struct SettingsView: View {
    var body: some View {
        TabView {
            FoldersSettings()
                .tabItem { Label("Dossiers", systemImage: "folder") }
            PeopleSettings()
                .tabItem { Label("Personnes", systemImage: "person.2") }
            BackupSettings()
                .tabItem { Label("Sauvegarde", systemImage: "externaldrive.badge.timemachine") }
            OptionsSettings()
                .tabItem { Label("Options", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 540)
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

/// Personnes : doublons à fusionner, renommage, personnes masquées.
struct PeopleSettings: View {
    @Environment(PhotoLibrary.self) private var library
    @Etat private var renaming: String?
    @Etat private var newName = ""

    var body: some View {
        Form {
            Section("Doublons probables") {
                let pairs = library.duplicatePeople
                if pairs.isEmpty {
                    Text("Aucun doublon détecté.").foregroundStyle(.secondary)
                } else {
                    Text("Même nom à la casse ou aux accents près, ou prénom seul d'un nom complet. Vérifiez avant de fusionner : deux personnes différentes peuvent avoir le même prénom.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(pairs, id: \.from) { pair in
                        HStack {
                            personLabel(pair.from)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            personLabel(pair.into)
                            Spacer()
                            Button("Fusionner") { library.renamePerson(pair.from, to: pair.into) }
                        }
                    }
                }
            }
            Section("Toutes les personnes") {
                ForEach(library.allPeople, id: \.name) { p in
                    HStack {
                        personLabel(p.name)
                        Spacer()
                        Text("\(p.count.formatted()) photos").font(.caption).foregroundStyle(.secondary)
                        Button("Renommer…") { newName = p.name; renaming = p.name }
                            .buttonStyle(.borderless)
                        Toggle("Visible", isOn: Binding(get: { !library.hiddenPeople.contains(p.name) },
                                                        set: { library.setHidden(p.name, !$0) }))
                            .toggleStyle(.checkbox)
                            .help("Afficher dans la barre latérale")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Renommer la personne", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Prénom Nom", text: $newName)
            Button("Renommer") {
                if let old = renaming { library.renamePerson(old, to: newName) }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        } message: {
            Text("Si ce nom existe déjà, les deux personnes seront fusionnées.")
        }
    }

    private func personLabel(_ name: String) -> some View {
        HStack(spacing: 6) {
            if let c = library.cover(of: name) {
                FaceCropView(url: c.photo.url, rect: c.rect, rotation: c.rotation)
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
            }
            Text(name)
            if let n = library.allPeople.first(where: { $0.name == name })?.count {
                Text("(\(n))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Sauvegarde vers un second disque et contrôle d'intégrité.
struct BackupSettings: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        Form {
            Section("Sauvegarde") {
                LabeledContent("Destination") {
                    HStack {
                        Text(library.backupDestination?.path ?? "Aucune")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(library.backupDestination == nil ? .secondary : .primary)
                        Button("Choisir…") { library.chooseBackupDestination() }
                            .disabled(library.isBackingUp)
                    }
                }
                if library.backupOnSameVolume {
                    Label("La destination est sur le même disque que les photos : elle ne protège pas d'une panne de ce disque.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Dernière sauvegarde") {
                    Text(library.lastBackup.map { $0.formatted(date: .long, time: .shortened) } ?? "Jamais")
                }
                if library.isPlanningBackup {
                    HStack { ProgressView().controlSize(.small); Text("Comparaison avec la sauvegarde…").font(.caption) }
                } else if let plan = library.backupPlan {
                    LabeledContent("À copier") {
                        Text(plan.files.isEmpty ? "Rien : la sauvegarde est à jour (\(plan.upToDate.formatted()) fichiers)"
                             : "\(plan.files.count.formatted()) fichiers · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                    }
                }
                if library.isBackingUp, let plan = library.backupPlan {
                    ProgressView(value: Double(library.backupBytesDone), total: Double(max(plan.totalBytes, 1))) {
                        Text("\(library.backupFilesDone.formatted()) / \(plan.files.count.formatted()) fichiers").font(.caption)
                    }
                }
                HStack {
                    Button("Vérifier") { library.planBackup() }
                        .disabled(library.backupDestination == nil || library.isPlanningBackup || library.isBackingUp)
                    Spacer()
                    if library.isBackingUp {
                        Button("Arrêter") { library.cancelBackup() }
                    } else {
                        Button("Sauvegarder maintenant") { library.startBackup() }
                            .buttonStyle(.borderedProminent)
                            .disabled(library.backupPlan?.files.isEmpty ?? true)
                    }
                }
                Text("Copie les photos, vidéos, XMP et fichiers Picasa manquants ou modifiés (en gardant l'arborescence), ainsi que les données d'Albumine. Rien n'est jamais supprimé de la sauvegarde. Peut être interrompue et reprise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Intégrité des fichiers") {
                LabeledContent("Dernière vérification") {
                    Text(library.lastIntegrityCheck.map { $0.formatted(date: .long, time: .shortened) } ?? "Jamais")
                }
                LabeledContent("Fichiers à problème") {
                    Text(library.damaged.isEmpty ? "Aucun" : "\(library.damaged.count) (voir « Fichiers abîmés » dans la barre latérale)")
                }
                if library.isCheckingIntegrity {
                    ProgressView(value: Double(library.integrityDone), total: Double(max(library.integrityTotal, 1))) {
                        Text("\(library.integrityDone.formatted()) / \(library.integrityTotal.formatted())").font(.caption)
                    }
                }
                HStack {
                    Spacer()
                    if library.isCheckingIntegrity {
                        Button("Arrêter") { library.cancelIntegrityCheck() }
                    } else {
                        Button("Vérifier tous les fichiers") { library.checkIntegrity() }
                    }
                }
                Text("Détecte les fichiers vides, tronqués (copie interrompue, disque défaillant) ou illisibles. À faire avant une sauvegarde : un fichier abîmé se récupère dans une autre copie.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if library.backupPlan == nil { library.planBackup() } }
    }
}
