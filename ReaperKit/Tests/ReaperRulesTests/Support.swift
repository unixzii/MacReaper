import Foundation
import ReaperRules
import Yams

/// One case of the conformance corpus in `Conformance/` (see its README).
struct ConformanceCase: Decodable {

    enum Expectation: Decodable {
        case valid
        case rejected(code: String, file: String, line: Int?)

        private struct Rejection: Decodable {

            var code: String
            var file: String
            var line: Int?
        }

        init(from decoder: Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self), word == "valid" {
                self = .valid
                return
            }
            let rejection = try Rejection(from: decoder)
            self = .rejected(code: rejection.code, file: rejection.file, line: rejection.line)
        }
    }

    var description: String
    var expect: Expectation
    var files: [String: String]

    static let directory = Bundle.module.url(forResource: "Conformance", withExtension: nil)!

    static var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return files.filter { $0.hasSuffix(".yaml") }.map { String($0.dropLast(".yaml".count)) }.sorted()
    }

    static func load(_ name: String) throws -> ConformanceCase {
        let text = try String(contentsOf: directory.appending(path: "\(name).yaml"), encoding: .utf8)
        return try YAMLDecoder().decode(ConformanceCase.self, from: text)
    }

    var sources: RuleSources {
        RuleSources(
            ruleSets: files.filter { $0.key.hasPrefix("rule-sets/") }.map { RuleSource(file: $0.key, text: $0.value) },
            profiles: files.filter { $0.key.hasPrefix("profiles/") }.map { RuleSource(file: $0.key, text: $0.value) }
        )
    }
}

/// Loads profile `p` from documents given inline, for focused tests.
func loadProfile(ruleSet: String, profile: String = defaultProfile) -> Result<LoadedProfile, RuleDiagnostics> {
    let sources = RuleSources(
        ruleSets: [RuleSource(file: "rule-sets/t.yaml", text: ruleSet)],
        profiles: [RuleSource(file: "profiles/p.yaml", text: profile)]
    )
    return Result { () throws(RuleDiagnostics) in try RuleLoader.loadProfile("p", from: sources) }
}

let defaultProfile = """
    format: 1
    id: p
    title: P
    roots: ["~"]
    maxDepth: 3
    ruleSets: [t]
    preselect: [safe]
    """
