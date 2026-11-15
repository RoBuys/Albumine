import SwiftUI
import AppKit

/// Duplicates seen by folder: pairs of folders holding the same files, most copies first.
/// For each pair, one folder is kept and the identical files of the other go to the Trash.
struct DuplicateFoldersView: View {
    @Environment(PhotoLibrary.self) private var library
    /// "Voir" : shows the groups of this pair in the grid.
    let onShow: (PhotoLibrary.DuplicateFolderPair) -> Void

    @Etat private var pending: (pair: PhotoLibrary.DuplicateFolderPair, keep: String)?

    var body: some View {
        let totals = Dictionary(library.folders.map { ($0.path, $0.count) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(library.duplicateFolderPairs) { pair in
                    row(pair, totals: totals)
                }
            }
            .padding(14)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Mettre à la corbeille", role: .destructive) {
                if let p = pending { library.keepFolder(p.keep, in: p.pair) }
                pending = nil
            }
        } message: {
            Text("Chaque fichier est d'abord comparé octet par octet à la copie gardée. Seuls les fichiers en double sont concernés ; ils restent récupérables dans la Corbeille du disque, et « Annuler » les remet en place.")
        }
    }

    private var confirmTitle: String {
        guard let p = pending else { return "" }
        if p.pair.isInternal { return L("Garder une seule copie de \(p.pair.count.formatted()) fichiers dans « \(name(p.keep)) » ?") }
        let other = p.keep == p.pair.a ? p.pair.b : p.pair.a
        return L("Mettre à la corbeille les \(p.pair.count.formatted()) copies de « \(name(other)) » ?")
    }

    private func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Path shown under the name: relative to the watched folder.
    private func location(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard let root = library.root(containing: path) else { return parent }
        let base = (root.path as NSString).deletingLastPathComponent
        return parent.hasPrefix(base + "/") ? String(parent.dropFirst(base.count + 1)) : parent
    }

    private func row(_ pair: PhotoLibrary.DuplicateFolderPair, totals: [String: Int]) -> some View {
        HStack(spacing: 12) {
            folderCard(pair.a, pair: pair, total: totals[pair.a])
            VStack(spacing: 4) {
                Image(systemName: pair.isInternal ? "square.on.square" : "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                Text("\(pair.count.formatted()) en double").font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: pair.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Voir") { onShow(pair) }
                    .controlSize(.small)
                    .help("Afficher ces doublons dans la grille")
            }
            .frame(width: 130)
            if pair.isInternal {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plusieurs copies dans le même dossier").font(.callout)
                    Text("Par exemple « IMG_1234.jpg » et « IMG_1234 (1).jpg ».").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else {
                folderCard(pair.b, pair: pair, total: totals[pair.b])
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func folderCard(_ path: String, pair: PhotoLibrary.DuplicateFolderPair, total: Int?) -> some View {
        let preferred = library.isPreferredFolder(path)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(Color.accentColor)
                Text(name(path)).font(.headline).lineLimit(1).truncationMode(.middle)
                if preferred {
                    Image(systemName: "pin.fill").foregroundStyle(.orange).help("Dossier prioritaire : ses copies sont toujours gardées")
                }
            }
            Text(location(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if let total {
                Text(pair.count >= total && !pair.isInternal
                     ? "Tout son contenu (\(total.formatted()) éléments) existe aussi dans l'autre dossier"
                     : "\(pair.count.formatted()) de ses \(total.formatted()) éléments sont en double")
                    .font(.caption)
                    .foregroundStyle(pair.count >= total && !pair.isInternal ? .orange : .secondary)
            }
            HStack {
                Button(pair.isInternal ? "Garder une seule copie…" : "Garder ce dossier…") { pending = (pair, path) }
                    .disabled(library.isTrashing)
                    .help(pair.isInternal ? "Les copies en trop de ce dossier vont à la corbeille"
                                          : "Les fichiers identiques de l'autre dossier vont à la corbeille")
                Menu {
                    Toggle("Toujours garder les copies de ce dossier", isOn: Binding(
                        get: { preferred }, set: { library.setPreferredFolder(path, $0) }))
                    Button("Afficher dans le Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
