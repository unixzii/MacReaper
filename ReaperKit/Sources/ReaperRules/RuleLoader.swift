import Foundation

/// The text of one rule file.
public struct RuleSource: Sendable {

    /// The path shown in diagnostics, like `rule-sets/rust.yaml`. The file name without its
    /// extension must equal the document's id.
    public var file: String
    public var text: String

    public init(file: String, text: String) {
        self.file = file
        self.text = text
    }

    var stem: String {
        let name = file.split(separator: "/").last.map(String.init) ?? file
        return name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }
}

/// The rule sets available for loading, keyed by file name without extension.
public struct RuleSources: Sendable {

    public var ruleSets: [String: RuleSource]

    public init(ruleSets: [RuleSource]) {
        self.ruleSets = Dictionary(ruleSets.map { ($0.stem, $0) }) { _, last in last }
    }

    /// The rule sets that ship with MacReaper.
    public static func builtin() throws -> RuleSources {
        try RuleSources(directory: Bundle.module.url(forResource: "BuiltinRules", withExtension: nil)!)
    }

    /// Reads `rule-sets/*.yaml` under `directory`.
    public init(directory: URL) throws {
        let url = directory.appending(path: "rule-sets")
        self.init(ruleSets: try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            .filter { $0.hasSuffix(".yaml") }
            .map { name in
                RuleSource(file: "rule-sets/\(name)", text: try String(contentsOf: url.appending(path: name), encoding: .utf8))
            })
    }
}

/// Rule sets validated together.
public struct LoadedRules: Sendable {

    /// In order of id.
    public var ruleSets: [RuleSet]
}

public enum RuleLoader {

    /// Loads every rule set in `sources`, and validates them together.
    ///
    /// Structural problems in any document are reported first; the cross-document checks run
    /// only when every document is well-formed.
    ///
    /// - Parameter checks: The checks rules may call. The engine that runs the rules supplies
    ///   them, so that rules are validated against the checks it implements.
    public static func load(_ sources: RuleSources, checks: [CheckSpec]) throws(RuleDiagnostics) -> LoadedRules {
        var diagnostics: [RuleDiagnostic] = []
        var ruleSets: [RuleSet] = []
        for source in sources.ruleSets.values.sorted(by: { $0.stem < $1.stem }) {
            var reader = DocumentReader(file: source.file)
            let ruleSet = reader.root(of: source.text).flatMap { RuleSet($0, reader: &reader) }
            diagnostics += reader.diagnostics
            if let ruleSet {
                diagnostics += fileNameDiagnostics(ruleSet.id, source: source)
                ruleSets.append(ruleSet)
            }
        }
        guard diagnostics.isEmpty else {
            throw RuleDiagnostics(diagnostics)
        }

        var context = ValidationContext(ruleSets: ruleSets, checks: checks)
        for ruleSet in ruleSets {
            ruleSet.validate(&context)
        }
        guard context.diagnostics.isEmpty else {
            throw RuleDiagnostics(context.diagnostics)
        }
        return LoadedRules(ruleSets: ruleSets)
    }

    private static func fileNameDiagnostics(_ id: Located<String>, source: RuleSource) -> [RuleDiagnostic] {
        guard id.value != source.stem else {
            return []
        }
        return [RuleDiagnostic(
            code: .fileNameMismatch,
            message: "the file is named `\(source.stem)`, so its id must be `\(source.stem)`",
            location: id.location
        )]
    }
}
