import ReaperFS
import SwiftUI
import System

@main
struct MacReaperApp: App {

    @State private var model: ScanModel = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return ScanModel(library: .builtin(home: trimmed), fileSystem: DarwinFileSystem(), home: FilePath(trimmed))
    }()

    var body: some Scene {
        Window("MacReaper", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 440)
        }
        .commands {
            CommandMenu("Scan") {
                Button("Scan") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(!model.canScan)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
        }
    }
}
