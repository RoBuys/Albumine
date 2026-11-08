import AppKit
import SwiftUI

/// Update window: new version and its notes, or the result of a manual check.
struct UpdateSheet: View {
    private let updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    if let r = updater.available {
                        Text("Albumine \(r.version) est disponible").font(.title3.weight(.semibold))
                        Text("Vous avez la version \(Updater.currentVersion).").foregroundStyle(.secondary)
                    } else {
                        Text("Mises à jour").font(.title3.weight(.semibold))
                    }
                }
            }

            if let r = updater.available {
                ScrollView {
                    Text(notes(r.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 220)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Link("Voir la page de la version sur GitHub", destination: r.page).font(.caption)
            }

            status

            HStack {
                if let r = updater.available {
                    Button("Ignorer cette version") { updater.skip(r) }
                        .disabled(busy)
                    Spacer()
                    Button("Plus tard") { updater.showSheet = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(busy)
                    Button("Installer et relancer") { Task { await updater.install(r) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                } else {
                    Spacer()
                    Button("OK") { updater.showSheet = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            if updater.available != nil {
                Text("Vos photos, votre bibliothèque et vos réglages ne sont pas modifiés. La mise à jour est vérifiée (signature de l'auteur) avant d'être installée.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var busy: Bool { updater.phase == .downloading || updater.phase == .installing }

    @ViewBuilder
    private var status: some View {
        switch updater.phase {
        case .downloading:
            ProgressView { Text("Téléchargement…").font(.caption) }
        case .installing:
            ProgressView { Text("Vérification et installation… Albumine va redémarrer.").font(.caption) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        case .checking:
            ProgressView { Text("Recherche de mises à jour…").font(.caption) }
        case .idle:
            if updater.available == nil, let m = updater.upToDateMessage {
                Label(m, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
    }

    private func notes(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
