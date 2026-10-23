@testable import ReaperRules
import Testing

@Suite("CompiledRules")
struct CompiledRulesTests {

    static let home = "/Users/test"

    static func shipped() throws -> CompiledRules {
        let loaded = try RuleLoader.loadProfile("home", from: RuleSources.builtin())
        return CompiledRules(loaded, home: home)
    }

    @Test("Rules, categories and scopes are numbered in order of qualified id")
    func interning() throws {
        let compiled = try Self.shipped()

        #expect(compiled.rules.map(\.name) == compiled.rules.map(\.name).sorted())
        #expect(compiled.rules.map(\.id.index) == Array(compiled.rules.indices))
        #expect(compiled.categories.map(\.name) == compiled.categories.map(\.name).sorted())
        #expect(compiled.scopes == compiled.scopes.sorted())
        #expect(compiled.scopes.contains("rust.project"))
    }

    @Test("References resolve to ids")
    func references() throws {
        let compiled = try Self.shipped()
        let target = try #require(compiled.rules.first { $0.name == "rust.target" })

        guard case .claim(let category, _, let isFallback) = target.action else {
            Issue.record("rust.target should claim")
            return
        }
        #expect(compiled[category].name == "rust.target")
        #expect(compiled[category].safety == .safe)
        #expect(!isFallback)
        #expect(target.condition.scope.map { compiled[$0.scope] } == "rust.project")
        #expect(target.condition.scope?.distance == .exactly(1))
    }

    @Test("~ is expanded in path globs")
    func pathExpansion() throws {
        let compiled = try Self.shipped()
        let archives = try #require(compiled.rules.first { $0.name == "xcode.archives" })

        #expect(archives.condition.path.map(\.pattern) == ["/Users/test/Library/Developer/Xcode/Archives/*"])
    }

    @Test("Templates compile to segments")
    func templates() throws {
        let compiled = try Self.shipped()
        func assignments(of rule: String) throws -> [CompiledAssignment] {
            switch try #require(compiled.rules.first { $0.name == rule }).action {
            case .pushScope(_, let assignments), .claim(_, let assignments, _): assignments
            case .skip: []
            }
        }

        #expect(try assignments(of: "rust.project").isEmpty)
        #expect(try assignments(of: "cmake.build").map(\.template.segments) == [[.fact("sourceDir")]])
        #expect(try assignments(of: "xcode.derived-data").map(\.template.segments) == [[.fact("workspacePath")]])
        let latex = try #require(compiled.rules.first { $0.name == "latex.aux" })
        #expect(latex.condition.sibling?.segments == [.capture("stem"), .literal(".tex")])
        #expect(latex.condition.capture != nil)
    }

    @Test("Scope variables and roots resolve to the scope's id")
    func scopeVariables() throws {
        let loaded = try loadProfile(ruleSet: """
            format: 1
            id: t
            title: T
            description: Test rule set.
            categories:
              c: { title: C, safety: safe }
            rules:
              - id: t.project
                when: { contains: x }
                action: { pushScope: { name: project, set: { label: "{name}" } } }
              - id: t.claim
                when: { name: a, scope: project }
                action: { claim: { category: c, set: { p: "{scope.project.label} at {scope.t.project.root}" } } }
            """).get()
        let compiled = CompiledRules(loaded, home: Self.home)
        let project = ScopeID(index: 0)

        guard case .claim(_, let assignments, _) = compiled.rules[0].action else {
            Issue.record("t.claim should sort first and claim")
            return
        }
        #expect(compiled[project] == "t.project")
        #expect(assignments.first?.template.segments == [
            .scopeVariable(project, "label"), .literal(" at "), .scopeRoot(project),
        ])
        let rendered = assignments[0].template.render { segment in
            switch segment {
            case .scopeVariable: "app"
            case .scopeRoot: "/Users/test/app"
            default: "?"
            }
        }
        #expect(rendered == "app at /Users/test/app")
    }

    @Test("Roots expand, and roots inside other roots are dropped")
    func roots() throws {
        let profile = defaultProfile.replacingOccurrences(of: #"roots: ["~"]"#, with: #"roots: ["~/Developer", "~", "/Volumes/Work"]"#)
        let loaded = try loadProfile(ruleSet: Self.minimalRuleSet, profile: profile).get()

        #expect(CompiledRules(loaded, home: "/Users/test/").roots == ["/Users/test", "/Volumes/Work"])
    }

    @Test("Profile overrides make categories stricter")
    func categorySafety() throws {
        let loaded = try loadProfile(ruleSet: Self.minimalRuleSet, profile: defaultProfile + "\ncategorySafety:\n  t.c: dangerous\n").get()

        #expect(CompiledRules(loaded, home: Self.home).categories.map(\.safety) == [.dangerous])
    }

    static let minimalRuleSet = """
        format: 1
        id: t
        title: T
        description: Test rule set.
        categories:
          c: { title: C, safety: safe }
        rules:
          - id: t.claim
            when: { name: a }
            action: { claim: c }
        """
}
