import ReaperEngine
import SwiftUI
import System

/// Below the table: marking for the rows shown, and what the marked candidates add up to.
struct CandidateActionBar: View {

    let model: ScanModel

    var body: some View {
        let shown = model.rows.map(\.id)
        let marked = model.markedCandidates
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                marking(shown)
                Spacer()
                Text("\(marked.count) of \(model.candidates.count) marked")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let size = model.totalSize(of: marked) {
                    Text(size.formatted)
                        .bold()
                        .monospacedDigit()
                        .help(size.mayFreeLess
                            ? "The space the marked candidates take up. Some of their files share space with other files, so deleting them may free less."
                            : "The space the marked candidates take up, which deleting them frees.")
                } else {
                    Text("Measuring…")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    private func marking(_ shown: [FilePath]) -> some View {
        HStack(spacing: 12) {
            Button("Mark All", systemImage: "checkmark.circle") {
                model.setMarked(true, shown)
            }
            .help("Mark every candidate shown")
            Button("Unmark All", systemImage: "circle") {
                model.setMarked(false, shown)
            }
            .help("Unmark every candidate shown")
            Button("Suggested", systemImage: "arrow.uturn.backward") {
                model.restoreSuggestedMarks(shown)
            }
            .help("Mark the candidates shown as their profile suggests: the safe ones")
        }
        .buttonStyle(.borderless)
        .disabled(shown.isEmpty)
    }
}
