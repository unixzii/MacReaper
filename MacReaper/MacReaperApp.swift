import ReaperFS
import SwiftUI
import System

@main
struct MacReaperApp: App {

    @State private var model: ScanModel = {
        // Resolved by realpath(3) as the walk resolves its root, so that `~` is spelled the way
        // the walk spells paths. URL's resolvingSymlinksInPath would drop a leading /private.
        let fileSystem = DarwinFileSystem()
        let given = FilePath(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
        let home = (try? fileSystem.resolvingSymlinks(given)) ?? given
        return ScanModel(
            library: .builtin(),
            fileSystem: fileSystem,
            home: home,
            locations: ScanLocation.standard(home: home)
        )
    }()

    var body: some Scene {
        Window("MacReaper", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CommandMenu("Scan") {
                Button("Scan") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(!model.canScan)
                // The bottom bar's delete: the marked candidates shown, after a confirmation.
                Button("Delete Marked…") { model.requestDeletion(model.markedShown) }
                    .disabled(!model.canDeleteMarkedShown)
                Divider()
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning && !model.isCleaning)
            }
        }
    }
}
