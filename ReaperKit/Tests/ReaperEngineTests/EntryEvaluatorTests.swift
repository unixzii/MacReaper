import ReaperEngine
import ReaperFSTesting
import ReaperRules
import Testing

@Suite("EntryEvaluator: conditions")
struct ConditionTests {

    @Test("name and contains")
    func nameAndContains() throws {
        let harness = try Harness(rules: """
              - id: t.target
                when: { name: target, contains: CACHEDIR.TAG }
                action: { claim: a }
            """) {
            File("tagged/target/CACHEDIR.TAG")
            Directory("untagged/target")
        }

        #expect(try harness.claim("tagged/target") != nil)
        #expect(try harness.outcome("untagged/target").isDescend)
    }

    @Test("A contains path is probed on the file system")
    func containsPath() throws {
        let harness = try Harness(rules: """
              - id: t.unity
                when: { contains: "ProjectSettings/ProjectVersion.txt" }
                action: { claim: a }
            """) {
            File("game/ProjectSettings/ProjectVersion.txt")
            Directory("not-game/ProjectSettings")
        }

        #expect(try harness.claim("game") != nil)
        #expect(try harness.outcome("not-game").isDescend)
    }

    @Test("containsAny with a suffix glob")
    func containsAny() throws {
        let harness = try Harness(rules: """
              - id: t.dotnet
                when: { containsAny: ["*.csproj", "*.fsproj"] }
                action: { claim: a }
            """) {
            File("service/App.fsproj")
            File("library/README.md")
        }

        #expect(try harness.claim("service") != nil)
        #expect(try harness.outcome("library").isDescend)
    }

    @Test("Scope distance counts from the entry that pushed the scope")
    func scopeDistance() throws {
        let harness = try Harness(rules: """
              - id: t.project
                when: { contains: Cargo.toml }
                action: { pushScope: project }
              - id: t.near
                when: { name: target, scope: { name: project, distance: 1 } }
                action: { claim: a }
              - id: t.within
                when: { name: cache, scope: { name: project, maxDistance: 2 } }
                action: { claim: a }
            """) {
            File("crate/Cargo.toml")
            Directory("crate/target")
            Directory("crate/tests/fixtures/target")
            Directory("crate/tests/cache")
            Directory("crate/tests/fixtures/cache")
            Directory("loose/target")
        }

        #expect(try harness.claim("crate/target") != nil)
        #expect(try harness.outcome("crate/tests/fixtures/target").isDescend)
        #expect(try harness.claim("crate/tests/cache") != nil)
        #expect(try harness.outcome("crate/tests/fixtures/cache").isDescend)
        #expect(try harness.outcome("loose/target").isDescend)
    }

    @Test("The innermost scope wins, and its variables reach templates")
    func innermostScope() throws {
        let harness = try Harness(rules: """
              - id: t.project
                when: { contains: package.json }
                action: { pushScope: { name: project, set: { package: "{name}" } } }
              - id: t.modules
                when: { name: node_modules, scope: { name: project, distance: 1 } }
                action: { claim: { category: a, set: { owner: "{scope.project.package}", root: "{scope.project.root}" } } }
            """) {
            File("webapp/package.json")
            File("webapp/packages/ui/package.json")
            Directory("webapp/packages/ui/node_modules")
        }

        let claim = try #require(try harness.claim("webapp/packages/ui/node_modules"))

        #expect(claim.variables == ["owner": "ui", "root": "/Users/test/webapp/packages/ui"])
        #expect(claim.provenance.map(\.root.string) == ["/Users/test/webapp", "/Users/test/webapp/packages/ui"])
    }

    @Test("olderThan compares with the evaluator's clock")
    func olderThan() throws {
        let harness = try Harness(rules: """
              - id: t.installers
                when: { kind: file, name: "*.dmg", olderThan: 60d }
                action: { claim: a }
            """) {
            File("Downloads/old.dmg", modified: .daysBefore(Harness.now, 90))
            File("Downloads/new.dmg", modified: .daysBefore(Harness.now, 3))
        }

        #expect(try harness.claim("Downloads/old.dmg") != nil)
        #expect(try harness.outcome("Downloads/new.dmg").isDescend)
    }

    @Test("Captured groups feed the sibling template")
    func captureAndSibling() throws {
        let harness = try Harness(rules: """
              - id: t.aux
                when: { kind: file, name: ["*.aux", "*.log"], capture: '^(?<stem>.+)\\.(aux|log)$', sibling: "{stem}.tex" }
                action: { claim: { category: a, set: { source: "{stem}.tex" } } }
            """) {
            File("thesis/paper.tex")
            File("thesis/paper.aux")
            File("thesis/notes.log")
        }

        #expect(try harness.claim("thesis/paper.aux")?.variables == ["source": "paper.tex"])
        #expect(try harness.outcome("thesis/notes.log").isDescend)
    }

    @Test("Symlinks are never evaluated")
    func symlinks() throws {
        let harness = try Harness(rules: """
              - id: t.modules
                when: { name: node_modules }
                action: { claim: a }
            """) {
            Directory("real/node_modules")
            Symlink("linked", to: "real/node_modules")
            Symlink("node_modules", to: "real/node_modules")
        }

        #expect(try harness.claim("real/node_modules") != nil)
        #expect(try harness.outcome("node_modules").isDescend)
    }
}

@Suite("EntryEvaluator: outcomes")
struct OutcomeTests {

    @Test("A skip wins over a claim on the same entry")
    func skipWins() throws {
        let harness = try Harness(rules: """
              - id: t.skip-git
                when: { name: .git }
                action: { skip: true }
              - id: t.claim-git
                when: { name: .git }
                action: { claim: a }
            """) {
            Directory("repo/.git/objects")
        }

        guard case .skip(let rule) = try harness.outcome("repo/.git") else {
            Issue.record("expected a skip")
            return
        }
        #expect(harness.name(rule) == "t.skip-git")
    }

    @Test("Fallback claims count only when nothing else claims")
    func fallback() throws {
        let harness = try Harness(categories: ["specific": .safe, "generic": .review], rules: """
              - id: t.generic
                when: { contains: CACHEDIR.TAG }
                action: { claim: { category: generic, fallback: true } }
              - id: t.target
                when: { name: target }
                action: { claim: specific }
            """) {
            File("crate/target/CACHEDIR.TAG")
            File("tool/cache/CACHEDIR.TAG")
        }

        let specific = try #require(try harness.claim("crate/target"))
        let generic = try #require(try harness.claim("tool/cache"))

        // crate/target holds both claims: the specific one decides although it is less strict.
        #expect(harness.name(specific.category) == "t.specific")
        #expect(harness.name(generic.category) == "t.generic")
    }

    @Test("When several claims hold, the strictest decides alone")
    func strictestClaim() throws {
        let harness = try Harness(categories: ["calm": .safe, "careful": .review], rules: """
              - id: t.b-second
                when: { name: shared }
                action: { claim: { category: careful, set: { label: second, only: b } } }
              - id: t.a-first
                when: { name: shared }
                action: { claim: { category: calm, set: { label: first } } }
            """) {
            Directory("shared")
        }

        let claim = try #require(try harness.claim("shared"))

        #expect(harness.name(claim.rule) == "t.b-second")
        #expect(harness.name(claim.category) == "t.careful")
        #expect(claim.safety == .review)
        #expect(!claim.isPreselected)
        #expect(claim.variables == ["label": "second", "only": "b"])
    }

    @Test("Between equally strict claims, the lowest rule id decides")
    func lowestIDClaim() throws {
        let harness = try Harness(categories: ["one": .safe, "two": .safe], rules: """
              - id: t.b-second
                when: { name: shared }
                action: { claim: two }
              - id: t.a-first
                when: { name: shared }
                action: { claim: one }
            """) {
            Directory("shared")
        }

        let claim = try #require(try harness.claim("shared"))

        #expect(harness.name(claim.rule) == "t.a-first")
        #expect(harness.name(claim.category) == "t.one")
    }

    @Test("Scopes pushed twice at one entry merge into one instance")
    func scopeMerge() throws {
        let harness = try Harness(rules: """
              - id: t.by-cargo
                when: { contains: Cargo.toml }
                action: { pushScope: { name: project, set: { project: cargo, kind: rust } } }
              - id: t.by-package
                when: { contains: package.json }
                action: { pushScope: { name: project, set: { project: npm } } }
            """) {
            File("hybrid/Cargo.toml")
            File("hybrid/package.json")
        }

        guard case .descend(let scopes) = try harness.outcome("hybrid") else {
            Issue.record("expected the folder to be descended into")
            return
        }
        let instance = try #require(scopes.instances.last)
        #expect(scopes.instances.count == 1)
        #expect(instance.variables == ["project": "cargo", "kind": "rust"])
        #expect(harness.names(instance.rules) == ["t.by-cargo", "t.by-package"])
    }

    @Test("Safe claims are preselected, and the claim records the entry's identity")
    func claimDetails() throws {
        let harness = try Harness(rules: """
              - id: t.modules
                when: { name: node_modules }
                action: { claim: a }
            """) {
            Directory("app/node_modules", modified: .daysBefore(Harness.now, 5))
        }

        let claim = try #require(try harness.claim("app/node_modules"))
        let listed = try harness.fileSystem.listDirectory(at: "/Users/test/app").entries.first!

        #expect(claim.isPreselected)
        #expect(claim.path == "/Users/test/app/node_modules")
        #expect(claim.identity == listed.identity)
        #expect(claim.modified == .daysBefore(Harness.now, 5))
        #expect(claim.provenance.isEmpty)
    }
}
