import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire quand l'exécutable est lancé hors d'un .app (swift run).
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
            CommandGroup(after: .newItem) {
                Button("Ajouter un dossier…") { library.addFolderWithPanel() }
                    .keyboardShortcut("o")
                Button("Rescanner les dossiers") { library.rescan() }
                    .keyboardShortcut("r")
            }
        }
    }
}
