import ReaperEngine
import ReaperRules
import SwiftUI

/// Narrows the table to all candidates, the marked ones, or one category.
struct CandidateSidebar: View {

    @Bindable var model: ScanModel

    var body: some View {
        List(selection: $model.filter) {
            Section {
                row("All Candidates", systemImage: "tray.full", count: model.candidates.count, bytes: total(model.candidates))
                    .tag(CandidateFilter.all)
                let marked = model.markedCandidates
                row("Marked", systemImage: "checkmark.circle", count: marked.count, bytes: total(marked))
                    .tag(CandidateFilter.marked)
            }
            let categories = model.categories
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories) { summary in
                        row(summary.category.title, safety: summary.category.safety, count: summary.count, bytes: summary.bytes)
                            .tag(CandidateFilter.category(summary.id))
                            .help(summary.category.detail ?? summary.category.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, count: Int, bytes: UInt64) -> some View {
        SidebarRow(count: count, bytes: bytes) {
            Label(title, systemImage: systemImage)
        }
    }

    private func row(_ title: String, safety: Safety, count: Int, bytes: UInt64) -> some View {
        SidebarRow(count: count, bytes: bytes) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(safety.color)
                    .imageScale(.small)
            }
        }
    }

    private func total(_ candidates: [Claim]) -> UInt64 {
        candidates.reduce(0) { $0 + ($1.size?.bytesFreed ?? 0) }
    }
}

private struct SidebarRow<Title: View>: View {

    let count: Int
    let bytes: UInt64
    @ViewBuilder let title: Title

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            title
                .lineLimit(1)
            Text(bytes == 0 ? "\(count)" : "\(count) · \(bytes.formattedBytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.leading, 26)
        }
    }
}
