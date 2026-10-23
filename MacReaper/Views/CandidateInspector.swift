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
                        Toggle("Marked for Cleanup", isOn: Binding(
                            get: { model.isMarked(candidate) },
                            set: { model.setMarked($0, [candidate.path]) }
                        ))
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: candidate.path.string)])
                        }
                    }
                }
            }

            SizeSections(model: model, candidate: candidate)

            Section("Why It Was Found") {
                ForEach(candidate.categories, id: \.self) { id in
                    let category = rules[id]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(category.title)
                                .bold()
                            Spacer()
                            SafetyLabel(safety: category.safety)
                        }
                        if let detail = category.detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(candidate.rules, id: \.self) { id in
                    RuleRow(rule: rules[id])
                }
            }

            if candidate.group != nil || !candidate.provenance.isEmpty {
                Section("Project") {
                    if let group = candidate.group {
                        LabeledContent("Name", value: group)
                    }
                    ForEach(Array(candidate.provenance.enumerated()), id: \.offset) { _, scope in
                        LabeledContent(rules[scope.scope]) {
                            Text(model.displayPath(scope.root))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(scope.root.string)
                        }
                    }
                }
            }

            if !candidate.variables.isEmpty {
                Section("Variables") {
                    ForEach(candidate.variables.sorted { $0.key < $1.key }, id: \.key) { name, value in
                        LabeledContent(name, value: value)
                    }
                }
            }
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
                LabeledContent("Contents", value: String(localized: "\(size.files) files in \(size.directories) folders"))
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

private struct RuleRow: View {

    let rule: CompiledRule

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rule.name)
                .font(.callout.monospaced())
            if let description = rule.description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
