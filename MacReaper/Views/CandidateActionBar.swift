import ReaperEngine
import ReaperRules
import SwiftUI
import System

/// Below the table: marking for the rows shown, what the marked candidates add up to, and
/// deleting them.
struct CandidateActionBar: View {

    let model: ScanModel
    @State private var confirmsDeletion = false

    var body: some View {
        let shown = model.rows.map(\.id)
        let marked = model.markedCandidates
        let size = model.totalSize(of: marked)
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                marking(shown)
                Spacer()
                Text("\(marked.count) of \(model.candidates.count) marked")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let size {
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
                Button("Delete…", role: .destructive) {
                    confirmsDeletion = true
                }
                .disabled(!model.canDelete)
                .help("Delete the marked candidates permanently")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.bar)
        // A dialog's title is plain text, so the inflection is applied before it gets there.
        .confirmationDialog(
            String(AttributedString(localized: "Delete ^[\(marked.count) candidate](inflect: true) permanently?").characters),
            isPresented: $confirmsDeletion
        ) {
            Button("Delete", role: .destructive, action: model.deleteMarked)
        } message: {
            Text(Self.warning(marked, size: size))
        }
        .dialogSeverity(.critical)
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
            .help("Mark the candidates shown as suggested: the safe ones")
        }
        .buttonStyle(.borderless)
        .disabled(shown.isEmpty)
    }

    /// What deleting takes away, and which candidates need the most care.
    private static func warning(_ candidates: [Claim], size: CandidateSize?) -> AttributedString {
        var paragraphs: [AttributedString] = []
        if let size {
            paragraphs.append(size.mayFreeLess
                ? AttributedString(localized: "They take up \(size.formatted), and deleting them may free less, since some of their files share space with other files.")
                : AttributedString(localized: "This frees \(size.allocated.formattedBytes)."))
        }
        let dangerous = candidates.count { $0.safety == .dangerous }
        if dangerous > 0 {
            paragraphs.append(AttributedString(localized: "^[\(dangerous) candidate](inflect: true) may hold the only copy of something."))
        }
        let review = candidates.count { $0.safety == .review }
        if review > 0 {
            paragraphs.append(AttributedString(localized: "^[\(review) candidate](inflect: true) should be reviewed before deleting."))
        }
        paragraphs.append(AttributedString(localized: "They don’t go to the Trash, and this can’t be undone."))
        return paragraphs.dropFirst().reduce(paragraphs[0]) { $0 + "\n\n" + $1 }
    }
}
