import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the executable runs outside an .app bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AlbumineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Etat private var library = PhotoLibrary()

    var body: some Scene {
        WindowGroup("Albumine") {
            ContentView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher les mises à jour…") { Task { await Updater.shared.check(manual: true) } }
            }
            CommandGroup(after: .newItem) {
                Button("Ajouter un dossier…") { library.addFolderWithPanel() }
                    .keyboardShortcut("o")
                Button("Rescanner les dossiers") { library.rescan() }
                    .keyboardShortcut("r")
                Divider()
                Button("Importer depuis Picasa…") { library.importPicasa() }
                    .disabled(library.isImportingPicasa)
            }
            CommandMenu("Bibliothèque") {
                Button("Importer les fichiers XMP (Mylio, Lightroom…)") { library.importSidecars() }
                    .disabled(library.isImportingXMP || library.sidecarCount == 0)
                Divider()
                Toggle("Écrire les annotations dans des fichiers XMP", isOn: Binding(
                    get: { library.writeXMP }, set: { library.setWriteXMP($0) }))
                Button("Écrire les fichiers XMP maintenant") { library.setWriteXMP(true) }
                    .disabled(library.isWritingXMP)
                Divider()
                Button("Rescanner les dossiers") { library.rescan() }
                Button(library.contentPaused ? "Reprendre l'analyse du contenu" : "Mettre en pause l'analyse du contenu") {
                    library.toggleContentPause()
                }
            }
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}
