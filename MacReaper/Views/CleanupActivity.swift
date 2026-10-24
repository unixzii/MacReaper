import ReaperEngine
import ReaperFS
import SwiftUI
import System

/// What cleanup is doing or did, in the toolbar's activity view: a ring that fills up while it
/// deletes, then what it deleted, with what it couldn't a click away.
struct CleanupActivity: View {

    let model: ScanModel
    let cleanup: CleanupSession
    @State private var showsFailures = false

    var body: some View {
        indicator
            .frame(width: 16)
        Text(message)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer(minLength: 4)
        if case .finished(let result) = cleanup.state, !result.failures.isEmpty {
            Button {
                showsFailures = true
            } label: {
                Label("\(result.failures.count)", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .help("Candidates that weren’t deleted completely")
            .popover(isPresented: $showsFailures, arrowEdge: .bottom) {
                CleanupFailureList(model: model, failures: result.failures)
            }
        }
        Text(trailing)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var indicator: some View {
        switch cleanup.state {
        case .running:
            ProgressView(value: cleanup.progress?.fraction ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.small)
        // What wasn't deleted has its own button, so the indicator only says whether anything was.
        case .finished(let result):
            if !result.notStarted.isEmpty {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.secondary)
            } else if result.removed.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var message: AttributedString {
        switch cleanup.state {
        case .running:
            if cleanup.isStopping {
                return AttributedString(localized: "Stopping after the candidates being deleted…")
            }
            let finished = cleanup.progress?.finishedCandidates ?? 0
            return AttributedString(localized: "Deleting \(min(finished + 1, cleanup.candidates.count)) of \(cleanup.candidates.count) candidates")
        case .finished(let result):
            let size = result.removedSize
            let freed = size.mayFreeLess
                ? String(localized: "up to \(size.allocated.formattedBytes)")
                : size.allocated.formattedBytes
            if result.removed.isEmpty, result.notStarted.isEmpty {
                return AttributedString(localized: "Nothing was deleted")
            }
            if !result.notStarted.isEmpty {
                return AttributedString(localized: "Stopped after deleting \(result.removed.count) of \(cleanup.candidates.count) candidates (\(freed))")
            }
            return AttributedString(localized: "Deleted ^[\(result.removed.count) candidate](inflect: true), freeing \(freed)")
        }
    }

    /// Elapsed time while deleting, the duration once finished.
    private var trailing: String {
        if case .finished(let result) = cleanup.state {
            return result.duration.formattedSeconds
        }
        return cleanup.progress?.elapsed.formattedSeconds ?? ""
    }
}

/// The candidates cleanup didn't delete, or not completely, and why.
private struct CleanupFailureList: View {

    let model: ScanModel
    let failures: [CleanupFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not Deleted Completely")
                .font(.headline)
            List(failures, id: \.candidate.path) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayPath(failure.candidate.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reason(failure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(failure.candidate.path.string)
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: failure.candidate.path.string)])
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
        }
        .padding()
        .frame(width: 420, height: 340)
    }

    private func reason(_ failure: CleanupFailure) -> String {
        switch failure.reason {
        case .changed:
            return String(localized: "Deleted or replaced since the scan, so it was left alone.")
        case .incomplete(let entries):
            guard let first = entries.first else {
                return ""
            }
            if first.path == failure.candidate.path {
                return String(localized: "Couldn’t be deleted: \(first.error.removalExplanation).")
            }
            let inside = first.path.string.dropFirst(failure.candidate.path.string.count + 1).description
            let more = entries.count > 1 ? String(localized: " and \(entries.count - 1) more") : ""
            return String(localized: "\(inside)\(more) couldn’t be deleted: \(first.error.removalExplanation). Everything else was.")
        }
    }
}
