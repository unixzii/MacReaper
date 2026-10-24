import ReaperEngine
import ReaperFS
import SwiftUI
import System

/// What the scan is doing, in the middle of the toolbar like Xcode's activity view: always one
/// line of the same size, so the window does not shift while a scan runs. While candidates are
/// measured, the indicator is a ring that fills up.
struct ScanActivity: View {

    let model: ScanModel
    @State private var showsErrors = false

    var body: some View {
        HStack(spacing: 8) {
            if let cleanup = model.cleanup {
                CleanupActivity(model: model, cleanup: cleanup)
            } else {
                scan(model.session)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(width: 420, height: 28)
    }

    @ViewBuilder
    private func scan(_ session: ScanSession?) -> some View {
        indicator(session)
            .frame(width: 16)
        Text(message(session))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(detail(session))
        Spacer(minLength: 4)
        if case .finished(let result)? = session?.state, !result.errors.isEmpty {
            Button {
                showsErrors = true
            } label: {
                Label("\(result.errors.count)", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .help("Folders the scan couldn’t read")
            .popover(isPresented: $showsErrors, arrowEdge: .bottom) {
                ScanErrorList(model: model, errors: result.errors)
            }
        }
        Text(trailing(session))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    @ViewBuilder
    private func indicator(_ session: ScanSession?) -> some View {
        switch session?.state {
        case nil, .idle?:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        case .scanning?:
            if let fraction = measuredFraction(session) {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .finished?:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled?:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
        case .failed?:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func message(_ session: ScanSession?) -> String {
        guard let session else {
            return String(localized: "Ready to scan")
        }
        let progress = session.progress
        switch session.state {
        case .idle, .scanning:
            switch progress?.phase {
            case nil:
                return String(localized: "Starting…")
            case .detecting:
                return String(localized: "Looking for candidates (\(progress!.candidates) found)")
            case .sizing, .finished:
                return String(localized: "Measuring \(progress!.sizedCandidates) of \(progress!.candidates) candidates")
            }
        case .finished(let result):
            return String(localized: "\(result.candidates.count) candidates found")
        case .cancelled:
            return String(localized: "Stopped (\(progress?.candidates ?? 0) candidates found)")
        case .failed(let error):
            return String(localized: "Scan failed: \(error.localizedDescription)")
        }
    }

    /// Elapsed time while scanning, the duration once finished.
    private func trailing(_ session: ScanSession?) -> String {
        if case .finished(let result)? = session?.state {
            return result.stats.duration.formattedSeconds
        }
        return session?.progress?.elapsed.formattedSeconds ?? ""
    }

    private func measuredFraction(_ session: ScanSession?) -> Double? {
        guard let session, session.isScanning, let progress = session.progress, progress.phase == .sizing else {
            return nil
        }
        return Double(progress.sizedCandidates) / Double(max(progress.candidates, 1))
    }

    /// The counts behind the message, for the tooltip.
    private func detail(_ session: ScanSession?) -> String {
        guard let session else {
            return String(localized: "Scan “\(model.location.title)” to find candidates")
        }
        if case .finished(let result) = session.state {
            return String(localized: "Scanned \(result.stats.directories) folders and \(result.stats.files) files")
        }
        guard let progress = session.progress else {
            return ""
        }
        var text = String(localized: "\(progress.directories) folders and \(progress.files) files so far")
        if let directory = progress.currentDirectory {
            text += "\n" + model.displayPath(directory)
        }
        return text
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
