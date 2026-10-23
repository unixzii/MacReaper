import AppKit
import ReaperEngine
import ReaperRules
import SwiftUI
import System

/// The candidates, with a checkbox each for marking them for cleanup.
struct CandidateTable: View {

    @Bindable var model: ScanModel

    var body: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                Toggle("Marked", isOn: Binding(
                    get: { row.isMarked },
                    set: { model.setMarked($0, [row.id]) }
                ))
                .labelsHidden()
                .help(row.isMarked ? "Marked for cleanup" : "Not marked for cleanup")
            }
            .width(20)

            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.claim.path.string))
                        .resizable()
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        Text(row.location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                }
                .help(row.claim.path.string)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Size", value: \.bytes) { row in
                SizeCell(size: row.claim.size, isMeasuring: model.isScanning)
            }
            .width(min: 76, ideal: 92)
            .alignment(.trailing)

            TableColumn("Project", value: \.project) { row in
                Text(row.project)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Category", value: \.categoryTitle)
                .width(min: 80, ideal: 130)

            TableColumn("Safety", value: \.safetyRank) { row in
                SafetyLabel(safety: row.claim.safety)
            }
            .width(min: 56, ideal: 64)

            TableColumn("Modified", value: \.modified) { row in
                Text(row.modified, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .help(row.modified.formatted(date: .long, time: .shortened))
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: FilePath.self) { paths in
            if !paths.isEmpty {
                Button("Mark") { model.setMarked(true, paths) }
                Button("Unmark") { model.setMarked(false, paths) }
                Divider()
                Button("Show in Finder") { revealInFinder(paths) }
                Button("Copy Path") { copyPaths(paths) }
            }
        } primaryAction: { paths in
            revealInFinder(paths)
        }
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else {
                return .ignored
            }
            model.toggleMarks(model.selection)
            return .handled
        }
    }

    private func revealInFinder(_ paths: Set<FilePath>) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0.string) })
    }

    private func copyPaths(_ paths: Set<FilePath>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.map(\.string).sorted().joined(separator: "\n"), forType: .string)
    }
}

struct SafetyLabel: View {

    let safety: Safety

    var body: some View {
        Text(safety.title)
            .foregroundStyle(safety.color)
    }
}

/// A candidate's size, or a spinner while the scan measures it.
private struct SizeCell: View {

    let size: CandidateSize?
    let isMeasuring: Bool

    var body: some View {
        if let size {
            Text(size.formatted)
                .monospacedDigit()
                .help(size.mayFreeLess
                    ? "Deleting it may free less: some of its files share space with other files."
                    : "Deleting it frees this much.")
        } else if isMeasuring {
            ProgressView()
                .controlSize(.mini)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }
}
