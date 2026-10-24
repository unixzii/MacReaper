import ReaperEngine
import ReaperRules
import SwiftUI
import System

/// The scan window: categories on the left, candidates in the middle, the selected candidate
/// on the right.
struct ContentView: View {

    @Bindable var model: ScanModel
    @SceneStorage("showsInspector") private var showsInspector = true

    var body: some View {
        NavigationSplitView {
            CandidateSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            detail
        }
        // In the sidebar: a toolbar field would sit at the toolbar's trailing end, which belongs
        // to the inspector.
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Filter Candidates")
        // On the split view rather than its detail, the inspector is a full-height column with
        // its own part of the toolbar, as in Xcode.
        .inspector(isPresented: $showsInspector) {
            CandidateInspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .toolbar {
                    Spacer()
                    Button("Inspector", systemImage: "sidebar.trailing") {
                        showsInspector.toggle()
                    }
                    .help("Hide the inspector")
                }
        }
        .navigationTitle("MacReaper")
        // The location menu says what is being scanned, and the activity view takes the middle.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                LocationMenu(model: model)
                    .disabled(model.isScanning || model.isCleaning)
            }
            ToolbarItem(placement: .principal) {
                ScanActivity(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning || model.isCleaning {
                    Button("Stop", systemImage: "stop.fill", action: model.stop)
                        .disabled(model.cleanup?.isStopping == true)
                        .help(model.isCleaning ? "Stop deleting once the candidates being deleted are done" : "Stop scanning")
                } else if model.session != nil {
                    // Before the first scan, the window's own Scan button starts one.
                    Button("Scan Again", systemImage: "arrow.clockwise", action: model.scan)
                        .disabled(!model.canScan)
                        .help("Scan again")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.session {
            CandidateTable(model: model)
                .overlay {
                    EmptyResultsView(model: model, session: session)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CandidateActionBar(model: model)
                }
        } else {
            ReadyView(model: model)
        }
    }
}

/// Where scans start: the standard locations and the folders the user chose, and a way to
/// choose another.
private struct LocationMenu: View {

    @Bindable var model: ScanModel

    var body: some View {
        Menu {
            Picker("Location", selection: $model.location) {
                ForEach(model.locations) { location in
                    Label(location.title, systemImage: location.systemImage)
                        .tag(location)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Choose Folder…", action: chooseFolder)
        } label: {
            Label(model.location.title, systemImage: model.location.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .help(model.location.root.string)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder to scan. The scan stays on the folder’s volume.")
        if panel.runModal() == .OK, let url = panel.url {
            model.chooseFolder(FilePath(url.path(percentEncoded: false)))
        }
    }
}

/// Before the first scan: where it looks, or why the rules cannot scan.
private struct ReadyView: View {

    let model: ScanModel

    var body: some View {
        switch model.library.rules {
        case .success:
            ContentUnavailableView {
                Label("Ready to Scan", systemImage: "magnifyingglass")
            } description: {
                Text("Looks through \(model.location.title) for build products, caches and other files the rules say can be cleaned. Scanning never deletes anything.")
            } actions: {
                Button("Scan", action: model.scan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .failure(let diagnostics):
            VStack(alignment: .leading, spacing: 12) {
                Label("The rules don’t load", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
                ScrollView {
                    Text(diagnostics.description)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
}

/// Shown over the table when it has no rows.
private struct EmptyResultsView: View {

    let model: ScanModel
    let session: ScanSession

    var body: some View {
        if !model.candidates.isEmpty {
            if model.rows.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Candidates", systemImage: "line.3.horizontal.decrease", description: Text("Nothing here matches the sidebar selection."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        } else {
            switch session.state {
            case .idle, .scanning:
                ContentUnavailableView("Looking for Candidates", systemImage: "magnifyingglass")
            case .finished where model.cleanup != nil:
                ContentUnavailableView("All Clean", systemImage: "sparkles", description: Text("Everything the scan found was deleted."))
            case .finished:
                ContentUnavailableView("Nothing to Clean", systemImage: "sparkles", description: Text("No rule matched anything in the scanned folders."))
            case .cancelled:
                ContentUnavailableView("Scan Stopped", systemImage: "stop.circle", description: Text("Nothing was found before the scan stopped."))
            case .failed(let error):
                ContentUnavailableView("Scan Failed", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
    }
}

#if DEBUG
#Preview("Scanning") {
    let model = ScanModel.preview()
    ContentView(model: model)
        .frame(width: 1100, height: 640)
        .task { model.scan() }
}

#Preview("Ready") {
    ContentView(model: .preview())
        .frame(width: 1100, height: 640)
}
#endif
