import ReaperEngine
import ReaperRules
import Testing

@Suite("RuleLoader")
struct RuleLoaderTests {

    @Test("Shipped rule sets load, in order of id")
    func shippedRuleSetsLoad() throws {
        let sources = try RuleSources.builtin()

        let loaded = try RuleLoader.load(sources)

        #expect(loaded.ruleSets.map(\.id.value) == sources.ruleSets.keys.sorted())
        #expect(loaded.ruleSets.allSatisfy { !$0.rules.isEmpty })
    }

    @Test("Scalars follow YAML 1.2: yes and on are strings, not booleans")
    func yaml12Scalars() throws {
        let loaded = try loadRules(ruleSet: ruleSet(extraRules: """
              - id: t.yes
                when: { name: [yes, on, "no"] }
                action: { claim: c }
            """)).get()

        let names = loaded.ruleSets[0].rules[0].when.name.map(\.value.pattern)
        #expect(names == ["yes", "on", "no"])
    }

    @Test("Plain true is a boolean where a string is expected")
    func booleanWhereStringExpected() {
        let result = loadRules(ruleSet: ruleSet(extraRules: """
              - id: t.bool
                when: { name: true }
                action: { claim: c }
            """))

        #expect(codes(result) == [.wrongType])
    }

    @Test("One pass reports every structural problem, with line and column")
    func reportsEveryProblem() throws {
        let result = loadRules(ruleSet: ruleSet(extraRules: """
              - id: t.broken
                when: { name: a/b, olderThan: soon, size: 1 }
                action: { claim: c, skip: true }
            """))

        let diagnostics = try #require(result.failure).diagnostics
        #expect(diagnostics.map(\.code) == [.invalidGlob, .invalidDuration, .unknownKey, .actionNotSingle])
        #expect(diagnostics.allSatisfy { $0.ruleID == "t.broken" })
        let unknownKey = try #require(diagnostics.first { $0.code == .unknownKey })
        #expect(unknownKey.location == SourceLocation(file: "rule-sets/t.yaml", line: 9, column: 41))
    }

    @Test("Cross-document checks run only on well-formed documents")
    func semanticChecksWaitForStructure() {
        let result = loadRules(ruleSet: ruleSet(extraRules: """
              - id: t.both
                when: { name: z, size: 1 }
                action: { claim: nope }
            """))

        #expect(codes(result) == [.unknownKey])
    }

    private func ruleSet(extraRules: String) -> String {
        """
        format: 1
        id: t
        title: T
        description: Test rule set.
        categories:
          c: { title: C, safety: safe }
        rules:
        \(extraRules)
        """
    }

    private func codes(_ result: Result<LoadedRules, RuleDiagnostics>) -> [DiagnosticCode] {
        result.failure?.diagnostics.map(\.code) ?? []
    }
}

private extension Result {

    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
