import ReaperFS
import SwiftUI
import System

@main
struct MacReaperApp: App {

    @State private var model: ScanModel = {
        // Resolved, so that `~` is spelled the way the walk spells paths.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return ScanModel(
            library: .builtin(),
            fileSystem: DarwinFileSystem(),
            home: FilePath(trimmed),
            locations: ScanLocation.standard(home: FilePath(trimmed))
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
                Button("Delete Marked…") { model.isConfirmingDeletion = true }
                    .disabled(!model.canDeleteMarkedShown)
                Divider()
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning && !model.isCleaning)
            }
        }
    }
}
