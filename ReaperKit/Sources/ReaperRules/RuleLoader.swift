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

/// The rule sets and profiles available for loading, keyed by file name without extension.
public struct RuleSources: Sendable {

    public var ruleSets: [String: RuleSource]
    public var profiles: [String: RuleSource]

    public init(ruleSets: [RuleSource], profiles: [RuleSource]) {
        self.ruleSets = Dictionary(ruleSets.map { ($0.stem, $0) }) { _, last in last }
        self.profiles = Dictionary(profiles.map { ($0.stem, $0) }) { _, last in last }
    }

    /// The rule sets and profiles that ship with MacReaper.
    public static func builtin() throws -> RuleSources {
        try RuleSources(directory: Bundle.module.url(forResource: "BuiltinRules", withExtension: nil)!)
    }

    /// Reads `rule-sets/*.yaml` and `profiles/*.yaml` under `directory`.
    public init(directory: URL) throws {
        func sources(in folder: String) throws -> [RuleSource] {
            let url = directory.appending(path: folder)
            return try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
                .filter { $0.hasSuffix(".yaml") }
                .map { name in
                    RuleSource(file: "\(folder)/\(name)", text: try String(contentsOf: url.appending(path: name), encoding: .utf8))
                }
        }
        self.init(ruleSets: try sources(in: "rule-sets"), profiles: try sources(in: "profiles"))
    }
}

/// A profile and the rule sets it names, validated together.
public struct LoadedProfile: Sendable {

    public var profile: Profile
    /// In the order the profile lists them.
    public var ruleSets: [RuleSet]
}

public enum RuleLoader {

    /// Loads the profile `id` and every rule set it names, and validates them together.
    ///
    /// Structural problems in any document are reported first; the cross-document checks run
    /// only when every document is well-formed.
    ///
    /// - Parameter checks: The checks rules may call. The engine that runs the rules supplies
    ///   them, so that rules are validated against the checks it implements.
    public static func loadProfile(_ id: String, from sources: RuleSources, checks: [CheckSpec]) throws(RuleDiagnostics) -> LoadedProfile {
        guard let profileSource = sources.profiles[id] else {
            let location = SourceLocation(file: "profiles/\(id).yaml", line: 1, column: 1)
            throw RuleDiagnostics([RuleDiagnostic(code: .unknownProfile, message: "there is no profile `\(id)`", location: location)])
        }

        var diagnostics: [RuleDiagnostic] = []
        var reader = DocumentReader(file: profileSource.file)
        let profile = reader.root(of: profileSource.text).flatMap { Profile($0, reader: &reader) }
        diagnostics += reader.diagnostics
        guard let profile else {
            throw RuleDiagnostics(diagnostics)
        }
        diagnostics += fileNameDiagnostics(profile.id, source: profileSource)

        var ruleSets: [RuleSet] = []
        for reference in profile.ruleSets {
            guard let source = sources.ruleSets[reference.value] else {
                diagnostics.append(RuleDiagnostic(
                    code: .unknownRuleSet,
                    message: "there is no rule set `\(reference.value)`",
                    location: reference.location
                ))
                continue
            }
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
        profile.validate(loading: ruleSets, context: &context)
        for ruleSet in ruleSets {
            ruleSet.validate(&context)
        }
        guard context.diagnostics.isEmpty else {
            throw RuleDiagnostics(context.diagnostics)
        }
        return LoadedProfile(profile: profile, ruleSets: ruleSets)
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
