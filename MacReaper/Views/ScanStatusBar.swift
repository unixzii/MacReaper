import ReaperEngine
import ReaperFS
import SwiftUI
import System

/// What the scan is doing, above the table: a spinner while looking for candidates, a progress
/// bar while sizing them, and a summary once finished.
struct ScanStatusBar: View {

    let model: ScanModel
    let session: ScanSession
    @State private var showsErrors = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                indicator
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if case .finished(let result) = session.state, !result.errors.isEmpty {
                    Button {
                        showsErrors = true
                    } label: {
                        Label("\(result.errors.count) Unreadable", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("Folders the scan couldn’t read")
                    .popover(isPresented: $showsErrors, arrowEdge: .bottom) {
                        ScanErrorList(model: model, errors: result.errors)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if session.isScanning, let progress = session.progress, progress.phase == .sizing {
                ProgressView(value: Double(progress.sizedCandidates), total: Double(max(progress.candidates, 1)))
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    private var indicator: some View {
        switch session.state {
        case .idle, .scanning:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var headline: String {
        let progress = session.progress
        switch session.state {
        case .idle, .scanning:
            switch progress?.phase {
            case nil:
                return String(localized: "Starting…")
            case .detecting:
                return String(localized: "Looking for candidates… \(progress!.candidates) found")
            case .sizing, .finished:
                return String(localized: "Measuring \(progress!.sizedCandidates) of \(progress!.candidates) candidates…")
            }
        case .finished(let result):
            let bytes = result.totalSize?.bytesFreed ?? 0
            return String(localized: "\(result.candidates.count) candidates · \(bytes.formattedBytes)")
        case .cancelled:
            return String(localized: "Scan stopped · \(progress?.candidates ?? 0) candidates found")
        case .failed(let error):
            return String(localized: "Scan failed: \(error.localizedDescription)")
        }
    }

    private var detail: String {
        switch session.state {
        case .finished(let result):
            return String(localized: "Scanned \(result.stats.directories) folders and \(result.stats.files) files in \(result.stats.duration.formattedSeconds)")
        default:
            guard let progress = session.progress else {
                return " "
            }
            let counts = String(localized: "\(progress.directories) folders · \(progress.files) files · \(progress.elapsed.formattedSeconds)")
            if session.isScanning, let directory = progress.currentDirectory {
                return counts + " · " + model.displayPath(directory)
            }
            return counts
        }
    }
}

/// The folders a scan couldn't read, and how to let it read protected ones.
private struct ScanErrorList: View {

    let model: ScanModel
    let errors: [ScanError]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders the Scan Couldn’t Read")
                .font(.headline)
            if errors.contains(where: { $0.error == .permissionDenied }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS protects some folders. Give MacReaper Full Disk Access to scan them, then scan again.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
                .font(.callout)
            }
            List(errors, id: \.path) { error in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayPath(error.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(error.error.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(error.path.string)
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
        }
        .padding()
        .frame(width: 420, height: 340)
    }
}
