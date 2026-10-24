import ReaperEngine
import ReaperRules
import SwiftUI
import System

/// Below the table: marking for the rows shown, what the marked ones among them add up to, and
/// deleting those, where the sidebar shows all candidates or the marked ones.
struct CandidateActionBar: View {

    let model: ScanModel
    /// The rows the table shows.
    let rows: [CandidateRow]
    @State private var confirmsDeletion = false

    var body: some View {
        let marked = rows.filter(\.isMarked).map(\.claim)
        let size = model.totalSize(of: marked)
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                marking(rows.map(\.id))
                Spacer(minLength: 0)
                Text("\(marked.count) of \(rows.count) marked")
                    .fixedSize()
                separator
                if let size {
                    Text(size.formatted)
                        .fixedSize()
                        .help(size.mayFreeLess
                            ? "The space the marked candidates shown take up. Some of their files share space with other files, so deleting them may free less."
                            : "The space the marked candidates shown take up, which deleting them frees.")
                } else {
                    Text(model.isScanning ? "Measuring…" : "Not measured")
                        .fixedSize()
                }
                if model.offersDeleting {
                    separator
                    QuickAction("Delete Marked…", systemImage: "trash", tint: .red) {
                        confirmsDeletion = true
                    }
                    .disabled(!model.canDelete(marked))
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .background(.bar)
        // A dialog's title is plain text, so the inflection is applied before it gets there.
        .confirmationDialog(
            String(AttributedString(localized: "Delete ^[\(marked.count) candidate](inflect: true) permanently?").characters),
            isPresented: $confirmsDeletion
        ) {
            Button("Delete", role: .destructive) {
                model.delete(marked)
            }
        } message: {
            Text(Self.warning(marked, size: size))
        }
        .dialogSeverity(.critical)
    }

    private var separator: some View {
        Divider()
            .frame(height: 16)
    }

    /// Marking for the rows shown, as icon buttons named in their tooltips, like the buttons
    /// in Xcode's debug bar.
    private func marking(_ shown: [FilePath]) -> some View {
        HStack(spacing: 2) {
            // Everything the Marked view shows is marked already.
            if model.filter != .marked {
                QuickAction("Mark All", systemImage: "checklist.checked") {
                    model.setMarked(true, shown)
                }
            }
            QuickAction("Unmark All", systemImage: "checklist.unchecked") {
                model.setMarked(false, shown)
            }
            QuickAction("Mark Suggested", systemImage: "wand.and.stars") {
                model.restoreSuggestedMarks(shown)
            }
        }
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

/// An icon button, named in its tooltip and to accessibility.
private struct QuickAction: View {

    let title: LocalizedStringKey
    let systemImage: String
    /// The icon's color while enabled; secondary when `nil`.
    let tint: Color?
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 14))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuickActionStyle(tint: tint))
        .help(title)
    }
}

/// Like the icon buttons in Xcode's toolbars: no bezel, and a stronger color while pressed, darker
/// in light mode and lighter in dark mode.
private struct QuickActionStyle: ButtonStyle {

    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, tint: tint)
    }

    private struct Appearance: View {

        let configuration: Configuration
        let tint: Color?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
        }

        private var foreground: AnyShapeStyle {
            if !isEnabled {
                return AnyShapeStyle(.tertiary)
            }
            if let tint {
                // Mixed toward the text color, which is black in light mode and white in dark.
                return AnyShapeStyle(configuration.isPressed ? tint.mix(with: .primary, by: 0.35) : tint)
            }
            return configuration.isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        }
    }
}
