import ReaperFS
import ReaperRules
import System

/// What a successful check reports, by fact name.
public typealias Facts = [String: ScalarValue]

/// The implementation of one of the checks declared in `CheckSpec.builtins`.
protocol Check: Sendable {

    /// The name rules call the check by.
    var name: String { get }

    /// Returns facts when the check succeeds, or `nil` when it fails. A check that cannot read
    /// what it needs fails rather than reporting an error.
    func evaluate(_ entry: EntryContext, arguments: [String: ScalarValue], fileSystem: any FileSystem) -> Facts?
}

enum BuiltinChecks {

    static let all: [String: any Check] = Dictionary(
        uniqueKeysWithValues: ([CacheDirSignature(), CMakeCache(), XcodeDerivedData(), VersionSuperseded()] as [any Check])
            .map { ($0.name, $0) }
    )
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
        // Validation guarantees that every check a rule calls exists.
        let facts = BuiltinChecks.all[check.name]!.evaluate(entry, arguments: check.arguments, fileSystem: fileSystem)
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
