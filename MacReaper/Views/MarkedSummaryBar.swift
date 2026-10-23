import ReaperEngine
import SwiftUI

/// How much the marked candidates add up to, below the table.
struct MarkedSummaryBar: View {

    let model: ScanModel

    var body: some View {
        let marked = model.markedCandidates
        let bytes = marked.reduce(0) { $0 + ($1.size?.bytesFreed ?? 0) }
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(marked.count) of \(model.candidates.count) marked")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.isScanning && marked.contains { $0.size == nil } ? "Measuring…" : "\(bytes.formattedBytes) to free")
                    .bold()
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
