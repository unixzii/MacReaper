import ReaperEngine
import SwiftUI

/// How big the marked candidates are, below the table.
struct MarkedSummaryBar: View {

    let model: ScanModel

    var body: some View {
        let marked = model.markedCandidates
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(marked.count) of \(model.candidates.count) marked")
                    .foregroundStyle(.secondary)
                Spacer()
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
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
