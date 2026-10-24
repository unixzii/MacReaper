import ReaperFS
import ReaperRules
import System

/// What a successful check reports, by fact name.
public typealias Facts = [String: ScalarValue]

/// A built-in check: its declaration, which the rule loader validates calls against, and its
/// implementation, side by side.
protocol Check: Sendable {

    /// The check's name, arguments and facts. ``evaluate(_:arguments:fileSystem:)`` reports
    /// exactly the declared facts.
    var spec: CheckSpec { get }

    /// Returns facts when the check succeeds, or `nil` when it fails. A check that cannot read
    /// what it needs fails rather than reporting an error. `arguments` passed validation
    /// against ``spec``.
    func evaluate(_ entry: EntryContext, arguments: [String: ScalarValue], fileSystem: any FileSystem) -> Facts?
}

/// The checks the engine implements.
public enum BuiltinChecks {

    static let all: [any Check] = [CacheDirSignature(), CMakeCache(), XcodeDerivedData(), VersionSuperseded()]

    static let byName: [String: any Check] = Dictionary(uniqueKeysWithValues: all.map { ($0.spec.name, $0) })

    /// What the rule loader needs to validate calls to the checks.
    public static var specs: [CheckSpec] {
        all.map(\.spec)
    }
}

extension RuleLoader {

    /// Loads every rule set in `sources`, validating calls to checks against the engine's checks.
    public static func load(_ sources: RuleSources) throws(RuleDiagnostics) -> LoadedRules {
        try load(sources, checks: BuiltinChecks.specs)
    }
}

/// Results of the checks run for one entry, so rules sharing a check with the same arguments
/// run it once.
struct CheckCache {

    private struct Key: Hashable {

        let name: String
        let arguments: [String: ScalarValue]
    }

    private var results: [Key: Facts?] = [:]

    mutating func facts(for check: CompiledCheck, entry: EntryContext, fileSystem: any FileSystem) -> Facts? {
        let key = Key(name: check.name, arguments: check.arguments)
        if let cached = results[key] {
            return cached
        }
        guard let implementation = BuiltinChecks.byName[check.name] else {
            preconditionFailure("No check `\(check.name)`: load rules with the engine's checks, BuiltinChecks.specs")
        }
        let facts = implementation.evaluate(entry, arguments: check.arguments, fileSystem: fileSystem)
        assert(facts.map(implementation.spec.describes) ?? true, "\(check.name) reported facts it does not declare: \(facts!)")
        results[key] = .some(facts)
        return facts
    }
}

extension FileSystem {

    /// Reads a small text file, or returns `nil` if it cannot be read.
    func readText(at path: FilePath, maxBytes: Int) -> String? {
        guard let bytes = try? readFile(at: path, maxBytes: maxBytes) else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
