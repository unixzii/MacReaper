import ReaperRules
import SwiftUI

extension Safety {

    var title: LocalizedStringKey {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .dangerous: "Dangerous"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .dangerous: .red
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "exclamationmark.shield.fill"
        case .dangerous: "xmark.shield.fill"
        }
    }

    /// What the level means for the user.
    var meaning: LocalizedStringKey {
        switch self {
        case .safe: "Can be recreated without effort, for example by building again."
        case .review: "Probably fine to delete, but you should decide."
        case .dangerous: "May hold the only copy of something. Check it before deleting."
        }
    }
}

/// A safety level as a colored capsule. Clicking it explains the level, among the others, and
/// whether the candidate was marked for cleanup on its own.
struct SafetyBadge: View {

    let safety: Safety
    let isMarkedAutomatically: Bool
    @State private var showsExplanation = false
    @State private var isHovered = false

    var body: some View {
        Button {
            showsExplanation.toggle()
        } label: {
            Text(safety.title)
                .font(.caption.bold())
                .foregroundStyle(safety.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                // A little stronger under the pointer, so it reads as something to click.
                .background(safety.color.opacity(isHovered || showsExplanation ? 0.25 : 0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("About Safety Levels")
        .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
            SafetyExplanation(safety: safety, isMarkedAutomatically: isMarkedAutomatically)
        }
    }
}

/// Every safety level, with the candidate's own picked out, and what it means for marking.
private struct SafetyExplanation: View {

    let safety: Safety
    let isMarkedAutomatically: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Safety")
                .font(.headline)
            VStack(spacing: 4) {
                ForEach(Safety.allCases, id: \.self) { level in
                    LevelRow(level: level, isCurrent: level == safety)
                }
            }
            Divider()
            Label {
                Text(isMarkedAutomatically
                    ? "Marked for cleanup automatically, as safe candidates are."
                    : "Not marked automatically: only safe candidates are.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: isMarkedAutomatically ? "checkmark.circle" : "circle.dashed")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private struct LevelRow: View {

        let level: Safety
        let isCurrent: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: level.symbol)
                    .foregroundStyle(level.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.title)
                        .fontWeight(.semibold)
                    Text(level.meaning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isCurrent ? level.color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isCurrent ? 1 : 0.5)
        }
    }
}
