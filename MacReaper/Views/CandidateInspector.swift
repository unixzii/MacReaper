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
            let bytes = selected.reduce(0) { $0 + ($1.size?.bytesFreed ?? 0) }
            ContentUnavailableView {
                Label("\(selected.count) Candidates", systemImage: "square.stack")
            } description: {
                Text(bytes.formattedBytes)
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

            Section("Size") {
                if let size = candidate.size {
                    if let reclaimable = size.reclaimable {
                        LabeledContent("Frees", value: reclaimable.formattedBytes)
                    }
                    LabeledContent("Allocated", value: size.allocated.formattedBytes)
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
