import AppKit
import ReaperEngine
import ReaperRules
import SwiftUI
import System

/// Why the selected candidate was found, and how big it is.
struct CandidateInspector: View {

    let model: ScanModel

    var body: some View {
        let selected = model.selectedCandidates
        if selected.count == 1, let rules = model.rules {
            CandidateDetails(model: model, candidate: selected[0], rules: rules)
        } else if selected.count > 1 {
            ContentUnavailableView {
                Label("\(selected.count) Candidates", systemImage: "square.stack")
            } description: {
                if let size = model.totalSize(of: selected) {
                    Text(size.formatted)
                }
            } actions: {
                Button("Mark All") { model.setMarked(true, model.selection) }
                Button("Unmark All") { model.setMarked(false, model.selection) }
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select a candidate to see why it was found."))
        }
    }
}

private struct CandidateDetails: View {

    let model: ScanModel
    let candidate: Claim
    let rules: CompiledRules

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.path.string))
                            .resizable()
                            .frame(width: 32, height: 32)
                        Text(candidate.path.lastComponent?.string ?? candidate.path.string)
                            .font(.title3.bold())
                            .lineLimit(2)
                    }
                    Text(model.displayPath(candidate.path))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Toggle("Marked", isOn: Binding(
                            get: { model.isMarked(candidate) },
                            set: { model.setMarked($0, [candidate.path]) }
                        ))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: candidate.path.string)])
                        }
                    }
                }
            }

            ReasonSection(model: model, candidate: candidate, rules: rules)
            SizeSections(model: model, candidate: candidate)
        }
        .formStyle(.grouped)
    }
}

/// How big the candidate is, and why deleting it may free less.
private struct SizeSections: View {

    let model: ScanModel
    let candidate: Claim

    var body: some View {
        Section("Size") {
            if let size = candidate.size {
                LabeledContent("Size", value: size.formatted)
                if size.directories > 0 {
                    LabeledContent("Contents") {
                        Text("^[\(size.files) file](inflect: true) in ^[\(size.directories) folder](inflect: true)")
                    }
                }
                if !size.isComplete {
                    Label("Part of it couldn’t be read, so it may be larger.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Text(model.isScanning ? "Measuring…" : "Not measured")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Modified") {
                Text(candidate.modified, format: .dateTime)
            }
        }

        if let size = candidate.size, size.mayFreeLess {
            Section("Why It May Free Less") {
                Text("Up to \(size.sharedBytes.formattedBytes) of it is in files that share space with other files, and may stay on disk after deleting it.")
                    .fixedSize(horizontal: false, vertical: true)
                if size.hardLinkedBytes > 0 {
                    Explanation(
                        title: "Hard links",
                        systemImage: "link",
                        text: "\(size.hardLinkedFiles) files (\(size.hardLinkedBytes.formattedBytes)) also have hard links elsewhere. A hard-linked file is one file under several names: deleting this removes the names here, but the file stays until every name is deleted."
                    )
                }
                if size.clonedBytes > 0 {
                    Explanation(
                        title: "Clones",
                        systemImage: "square.on.square",
                        text: "\(size.clonedFiles) files (\(size.clonedBytes.formattedBytes)) are copies that share their data with other copies. On APFS, a copied file shares its data with the original until one of them changes, so deleting a copy frees only what no other copy uses."
                    )
                }
            }
        }
    }
}

private struct Explanation: View {

    let title: LocalizedStringKey
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .bold()
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// Why the candidate is here, in one place: its category and safety, the rule that found it,
/// what the rule noted about it, and the folder it was found inside.
private struct ReasonSection: View {

    let model: ScanModel
    let candidate: Claim
    let rules: CompiledRules

    var body: some View {
        let category = rules[candidate.category]
        let rule = rules[candidate.rule]
        Section("Why It’s Here") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.title)
                        .bold()
                    Spacer()
                    SafetyBadge(safety: candidate.safety)
                }
                if let detail = category.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(candidate.safety.explanation(isMarkedAutomatically: candidate.isPreselected))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Found by")
                if let description = rule.description {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
                Text(rule.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

            ForEach(candidate.variables.sorted { $0.key < $1.key }, id: \.key) { name, value in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.label(for: name))
                    if value.hasPrefix("/") {
                        PathText(model.displayPath(FilePath(value)), full: value)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(value)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // The scope the rule asked for, nearest first, rather than every scope it lies in.
            if let test = rule.condition.scope, let scope = candidate.provenance.last(where: { $0.scope == test.scope }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inside")
                    PathText(model.displayPath(scope.root), full: scope.root.string)
                        .foregroundStyle(.secondary)
                    Text(rules[scope.scope])
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A variable's name as a label: `supersededBy` reads "Superseded by".
    static func label(for variable: String) -> String {
        var words = ""
        for character in variable {
            if character.isUppercase, !words.isEmpty {
                words += " " + character.lowercased()
            } else {
                words.append(character)
            }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A path shortened for display, in full on hover.
private struct PathText: View {

    let text: String
    let full: String

    init(_ text: String, full: String) {
        self.text = text
        self.full = full
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(full)
    }
}
