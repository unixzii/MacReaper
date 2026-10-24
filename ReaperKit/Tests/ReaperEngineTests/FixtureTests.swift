import ReaperEngine
import ReaperFSTesting
import ReaperRules
import Testing

/// The shipped rules, scanned over ``Fixture``.
@Suite("Fixture scan")
struct FixtureTests {

    @Test("Every expected candidate, and nothing else")
    func candidates() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)

        let result = try await harness.scan()

        let found = Self.summary(result, harness)
        for (path, category) in Fixture.expected.sorted(by: { $0.key < $1.key }) {
            #expect(found[path] == category, "\(path)")
        }
        for path in Set(found.keys).subtracting(Fixture.expected.keys).sorted() {
            Issue.record("Unexpected candidate \(path): \(found[path]!.sorted())")
        }
        #expect(result.errors.isEmpty)
    }

    @Test("Scopes, preselection and nesting")
    func details() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)

        let result = try await harness.scan()

        let byPath = Dictionary(uniqueKeysWithValues: result.candidates.map { (harness.relative($0.path), $0) })
        for (path, scope) in Fixture.expectedInnermostScopes {
            let candidate = try #require(byPath[path], "\(path) was not claimed")
            let innermost = candidate.provenance.last.map { "\(harness.rules[$0.scope])@\(harness.relative($0.root))" }
            #expect(innermost == scope, "\(path)")
        }
        for candidate in result.candidates {
            #expect(candidate.isPreselected == (candidate.safety == .safe), "\(candidate.path)")
        }
        let paths = result.candidates.map(\.path.string)
        for path in paths {
            #expect(!paths.contains { path.hasPrefix($0 + "/") }, "\(path) lies inside another candidate")
        }
    }

    @Test("Skips and symlinks are counted")
    func stats() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)

        let stats = try await harness.scan().stats

        // .Trash, Tool.app, repo/.git, CloudStorage, CoreSimulator/Devices, Mobile Documents.
        #expect(stats.skipped == 6)
        // Developer/linked/node_modules.
        #expect(stats.symlinks == 1)
        #expect(stats.otherVolumes == 0)
    }

    /// Each mutation weakens one guard in a shipped rule set. If the fixture had no case that
    /// depends on the guard, the scan would not change, and the guard would be untested.
    @Test("Every guard matters", arguments: Mutation.all)
    func mutation(_ mutation: Mutation) async throws {
        let baseline = try Harness.shipped(tree: Fixture.tree)
        let mutated = try Harness.shipped(editing: mutation.apply, tree: Fixture.tree)

        let before = Self.summary(try await baseline.scan(), baseline)
        let after = Self.summary(try await mutated.scan(), mutated)

        #expect(before != after)
    }

    static func summary(_ result: ScanResult, _ harness: Harness) -> [String: String] {
        Dictionary(uniqueKeysWithValues: result.candidates.map { candidate in
            (harness.relative(candidate.path), harness.name(candidate.category))
        })
    }
}

/// A one-line edit to a shipped rule file.
struct Mutation: CustomTestStringConvertible, Sendable {

    var description: String
    var ruleSet: String
    var original: String
    var replacement: String

    var testDescription: String {
        description
    }

    func apply(_ sources: inout RuleSources) {
        let text = sources.ruleSets[ruleSet]!.text
        precondition(text.contains(original), "\(ruleSet).yaml no longer contains \(original)")
        sources.ruleSets[ruleSet]!.text = text.replacingOccurrences(of: original, with: replacement)
    }

    static let all = [
        Mutation(description: "rust.target without its scope", ruleSet: "rust",
                 original: "      scope: { name: project, distance: 1 }\n", replacement: ""),
        Mutation(description: "rust.target at any distance", ruleSet: "rust",
                 original: "scope: { name: project, distance: 1 }", replacement: "scope: project"),
        Mutation(description: "rust.target without a Cargo file", ruleSet: "rust",
                 original: "      containsAny: [CACHEDIR.TAG, .rustc_info.json]\n", replacement: ""),
        Mutation(description: "rust.target needing CACHEDIR.TAG", ruleSet: "rust",
                 original: "containsAny: [CACHEDIR.TAG, .rustc_info.json]", replacement: "containsAny: [CACHEDIR.TAG]"),
        Mutation(description: "meson.build not claiming", ruleSet: "meson",
                 original: "      claim: build", replacement: "      pushScope: neutered"),
        Mutation(description: "simulator devices walked", ruleSet: "xcode",
                 original: "path: ~/Library/Developer/CoreSimulator/Devices\n    action:\n      skip: true",
                 replacement: "path: ~/Library/Developer/CoreSimulator/Devices\n    action:\n      pushScope: neutered"),
        Mutation(description: "generic tag rule not a fallback", ruleSet: "core",
                 original: "fallback: true", replacement: "fallback: false"),
        Mutation(description: "tag signature not checked", ruleSet: "core",
                 original: "      check: cachedir.signature\n", replacement: ""),
        Mutation(description: "cmake.build without expectations", ruleSet: "cmake",
                 original: "check: { name: cmake.cache, expect: { valid: true, inSource: false, sourceExists: true } }",
                 replacement: "check: cmake.cache"),
        Mutation(description: "gradle build/ without a project", ruleSet: "gradle",
                 original: "      name: build\n      scope: { name: project, distance: 1 }\n", replacement: "      name: build\n"),
        Mutation(description: "maven target/ without Maven output", ruleSet: "maven",
                 original: "      containsAny: [classes, maven-status, maven-archiver, surefire-reports]\n", replacement: ""),
        Mutation(description: "Unity detected by Assets alone", ruleSet: "unity",
                 original: "contains: [Assets, ProjectSettings/ProjectVersion.txt]", replacement: "contains: Assets"),
        Mutation(description: "LaTeX files without their .tex", ruleSet: "latex",
                 original: "      sibling: \"{stem}.tex\"\n", replacement: ""),
        Mutation(description: "venvs recognised by name", ruleSet: "python",
                 original: "contains: pyvenv.cfg", replacement: "name: [.venv, venv]"),
        Mutation(description: "iCloud walked", ruleSet: "core",
                 original: "path: [\"~/Library/Mobile Documents\", \"~/Library/CloudStorage\"]\n    action:\n      skip: true",
                 replacement: "path: [\"~/Library/Mobile Documents\", \"~/Library/CloudStorage\"]\n    action:\n      pushScope: neutered"),
        Mutation(description: "bundles recognised by name", ruleSet: "core",
                 original: "      contains: Contents/Info.plist\n", replacement: ""),
        Mutation(description: "all device support claimed", ruleSet: "xcode",
                 original: "      check:\n        name: version.superseded\n"
                     + #"        args: { pattern: '^(?<group>.+?) (?<version>\d+(\.\d+)*) \(' }"# + "\n",
                 replacement: ""),
        Mutation(description: "installers of any age", ruleSet: "macos",
                 original: "      olderThan: 60d\n", replacement: ""),
    ]
}
