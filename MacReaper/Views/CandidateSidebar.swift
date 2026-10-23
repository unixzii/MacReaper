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
                        row(summary.category.title, systemImage: summary.category.displaySymbol, count: summary.count, bytes: summary.bytes)
                            .tag(CandidateFilter.category(summary.id))
                            .help(summary.category.detail ?? summary.category.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, count: Int, bytes: UInt64) -> some View {
        SidebarRow(title: Text(title), systemImage: systemImage, count: count, bytes: bytes)
    }

    private func row(_ title: String, systemImage: String, count: Int, bytes: UInt64) -> some View {
        SidebarRow(title: Text(title), systemImage: systemImage, count: count, bytes: bytes)
    }

    private func total(_ candidates: [Claim]) -> UInt64 {
        candidates.reduce(0) { $0 + ($1.size?.allocated ?? 0) }
    }
}

/// A sidebar row: an icon, and the title with the count and size under it.
private struct SidebarRow: View {

    let title: Text
    let systemImage: String
    let count: Int
    let bytes: UInt64

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                title
                    .lineLimit(1)
                Text(bytes == 0 ? "\(count)" : "\(bytes.formattedBytes) (\(count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            SidebarIcon(systemImage: systemImage)
        }
        .labelStyle(CenteredIconLabelStyle())
    }
}

/// A sidebar symbol in the accent color, or the row's text color when the row is selected.
/// Every symbol is drawn at the same point size, where SF Symbols share one stroke weight and
/// are optically balanced, and centered in the same frame so titles line up. Scaling symbols
/// to one size instead would scale their strokes too.
private struct SidebarIcon: View {

    let systemImage: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16))
            .frame(width: 22, height: 22)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
    }
}

/// A label whose icon is centered on the whole title, which here spans two lines, rather than
/// on its first line.
private struct CenteredIconLabelStyle: LabelStyle {

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}
