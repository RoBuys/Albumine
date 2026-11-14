import SwiftUI

/// Unnamed faces grouped by resemblance: a whole group is named in one go.
/// Groups with a suggested name come first, then groups of unknown people.
struct FaceGroupsView: View {
    @Environment(PhotoLibrary.self) private var library
    let onOpen: (Photo) -> Void

    var body: some View {
        let groups = library.faceGroups ?? []
        if groups.isEmpty {
            ContentUnavailableView {
                Label("Aucun groupe de visages", systemImage: "person.2.crop.square.stack")
            } description: {
                Text(library.faceGroupSingles > 0
                     ? "Les \(library.faceGroupSingles.formatted()) visages restants ne ressemblent à aucun autre : nommez-les un par un dans la grille."
                     : "Tous les visages regroupés ont été traités.")
            } actions: {
                Button("Revenir à la grille") { library.closeFaceGroups() }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(groups) { group in
                        FaceGroupRow(group: group, onOpen: onOpen)
                    }
                    if library.faceGroupSingles > 0 {
                        Text("\(library.faceGroupSingles.formatted()) visages ne ressemblent à aucun autre : ils restent à nommer un par un dans la grille.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct FaceGroupRow: View {
    @Environment(PhotoLibrary.self) private var library
    let group: PhotoLibrary.FaceGroup
    let onOpen: (Photo) -> Void

    @Etat private var name = ""
    /// Faces set aside by a click: they are not named with the others.
    @Etat private var excluded: Set<String> = []

    private var chosen: [PhotoLibrary.FaceRef] { group.faces.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let s = group.suggestion {
                    Label("Probablement \(s)", systemImage: "person.crop.circle.badge.questionmark").font(.headline)
                } else {
                    Label("Personne inconnue", systemImage: "person.crop.circle.dashed").font(.headline)
                }
                Text("\(group.faces.count) visage\(group.faces.count > 1 ? "s" : "")")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Nom", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(apply)
                Menu {
                    ForEach(library.allPeople, id: \.name) { p in Button(p.name) { name = p.name } }
                } label: { Image(systemName: "person.2") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Choisir une personne existante")
                Button(chosen.count == group.faces.count ? "Nommer les \(chosen.count)" : "Nommer \(chosen.count) sur \(group.faces.count)", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
                Menu {
                    Button("Ignorer ce groupe pour l'instant") { library.dropFromGroup(group.faces, group: group.id) }
                    Button("Ce ne sont pas des visages à nommer (retirer les \(chosen.count) cadres)", role: .destructive) {
                        library.removeFaces(chosen, group: group.id)
                        excluded = []
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: group.faces.count > 12) {
                LazyHStack(spacing: 6) {
                    ForEach(group.faces) { ref in
                        if let photo = library.photo(id: ref.photo), let k = library.faceIndex(ref) {
                            let face = library.faces(of: photo)[k]
                            let out = excluded.contains(ref.id)
                            FaceCropView(url: photo.url, rect: library.faceRect(face, in: photo), rotation: library.rotation(of: photo))
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .opacity(out ? 0.25 : 1)
                                .overlay(alignment: .topTrailing) {
                                    if out { Image(systemName: "xmark.circle.fill").foregroundStyle(.red).padding(3) }
                                }
                                .onTapGesture(count: 2) { onOpen(photo) }
                                .onTapGesture { if out { excluded.remove(ref.id) } else { excluded.insert(ref.id) } }
                                .help("\(photo.name) — clic : écarter ce visage du groupe · double-clic : ouvrir la photo")
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 80)
            if !excluded.isEmpty {
                Text("\(excluded.count) visage\(excluded.count > 1 ? "s" : "") écarté\(excluded.count > 1 ? "s" : "") : \(excluded.count > 1 ? "ils resteront" : "il restera") à nommer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { if name.isEmpty { name = group.suggestion ?? "" } }
    }

    private func apply() {
        let faces = chosen
        guard !faces.isEmpty else { return }
        library.nameFaces(faces, as: name, group: group.id)
        // The faces set aside stay in the group, to be named differently.
        excluded = []
        name = group.suggestion ?? ""
    }
}
