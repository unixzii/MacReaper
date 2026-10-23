import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import System

/// An in-memory home folder plus compiled rules, evaluated the way the walker will: every
/// ancestor of an entry is evaluated first, from the scan root down, so scopes build up.
struct Harness {

    static let home: FilePath = "/Users/test"
    /// The time `olderThan` conditions measure from.
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    let fileSystem: InMemoryFileSystem
    let evaluator: EntryEvaluator

    var rules: CompiledRules {
        evaluator.rules
    }

    /// Uses one inline rule set `t` with the given categories (`name: safety`) and rules.
    init(
        categories: [String: Safety] = ["a": .safe],
        rules: String,
        roots: [String] = ["~"],
        maxDepth: Int = 20,
        exclude: [String] = [],
        @TreeBuilder tree: () -> [TreeNode]
    ) throws {
        let loaded = try loadInlineProfile(categories: categories, rules: rules, roots: roots, maxDepth: maxDepth, exclude: exclude)
        try self.init(loaded: loaded, order: .byName, tree: Tree(tree))
    }

    /// Uses a profile that ships with ReaperRules.
    ///
    /// - Parameters:
    ///   - order: The order the in-memory file system lists directories in.
    ///   - edit: Changes the shipped rule files before loading, to test that a rule matters.
    init(
        shippedProfile profile: String,
        order: InMemoryFileSystem.ListingOrder = .byName,
        editing edit: (inout RuleSources) -> Void = { _ in },
        tree: Tree
    ) throws {
        var sources = try RuleSources.builtin()
        edit(&sources)
        try self.init(loaded: RuleLoader.loadProfile(profile, from: sources), order: order, tree: tree)
    }

    init(shippedProfile profile: String, @TreeBuilder tree: () -> [TreeNode]) throws {
        try self.init(shippedProfile: profile, tree: Tree(tree))
    }

    private init(loaded: LoadedProfile, order: InMemoryFileSystem.ListingOrder, tree: Tree) throws {
        fileSystem = InMemoryFileSystem(root: Self.home, order: order, tree: tree)
        evaluator = EntryEvaluator(
            rules: CompiledRules(loaded, home: Self.home.string),
            fileSystem: fileSystem,
            now: Self.now
        )
    }

    func scan(workers: Int = 1) async throws -> ScanResult {
        try await DiskScanner(rules: rules, fileSystem: fileSystem, now: Self.now, workerCount: workers).scan()
    }

    /// `path` relative to the home folder.
    func relative(_ path: FilePath) -> String {
        String(path.string.dropFirst(Self.home.string.count + 1))
    }

    /// Evaluates the entry at `relativePath` under the home folder. If an ancestor is skipped
    /// or claimed, the entry is never reached and that ancestor's outcome is returned.
    func outcome(_ relativePath: String) throws -> EntryOutcome {
        var scopes = ScopeStack.empty
        var path = Self.home
        let components = relativePath.split(separator: "/").map(String.init)
        for depth in 0...components.count {
            if depth > 0 {
                path.append(components[depth - 1])
            }
            let outcome = evaluator.evaluate(try context(path, depth: depth, scopes: scopes))
            guard depth < components.count, case .descend(let inner) = outcome else {
                return outcome
            }
            scopes = inner
        }
        preconditionFailure("unreachable")
    }

    /// The claim for the entry at `relativePath`, or `nil` if it is not claimed.
    func claim(_ relativePath: String) throws -> Claim? {
        if case .claim(let claim) = try outcome(relativePath) { claim } else { nil }
    }

    /// The context of an entry with no inherited scopes, for calling checks directly.
    func context(_ relativePath: String) throws -> EntryContext {
        let path = relativePath.isEmpty ? Self.home : Self.home.appending(relativePath)
        return try context(path, depth: 0, scopes: .empty)
    }

    private func context(_ path: FilePath, depth: Int, scopes: ScopeStack) throws -> EntryContext {
        let siblings = try fileSystem.listDirectory(at: path.removingLastComponent())
        let name = path.lastComponent!.string
        let attributes = siblings.entries.first { $0.name == name }!
        let children = attributes.kind == .directory ? try fileSystem.listDirectory(at: path) : nil
        return EntryContext(path: path, attributes: attributes, depth: depth, children: children, siblings: siblings, scopes: scopes)
    }

    func name(_ category: CategoryID) -> String {
        rules[category].name
    }

    func name(_ rule: RuleID) -> String {
        rules[rule].name
    }

    func names(_ ruleIDs: [RuleID]) -> [String] {
        ruleIDs.map { rules[$0].name }
    }
}

/// Loads a profile `p` with one inline rule set `t`, holding the given categories
/// (`name: safety`) and rules.
func loadInlineProfile(
    categories: [String: Safety] = ["a": .safe],
    rules: String,
    roots: [String] = ["~"],
    maxDepth: Int = 20,
    exclude: [String] = [],
    categorySafety: [String: Safety] = [:]
) throws -> LoadedProfile {
    let categoryLines = categories.keys.sorted()
        .map { "  \($0): { title: \($0), safety: \(categories[$0]!.rawValue) }" }
        .joined(separator: "\n")
    let ruleSet = """
        format: 1
        id: t
        title: T
        description: Test rule set.
        categories:
        \(categoryLines)
        rules:
        \(rules)
        """
    let profile = """
        format: 1
        id: p
        title: P
        roots: [\(roots.map { "\"\($0)\"" }.joined(separator: ", "))]
        exclude: [\(exclude.map { "\"\($0)\"" }.joined(separator: ", "))]
        maxDepth: \(maxDepth)
        ruleSets: [t]
        preselect: [safe]
        categorySafety: {\(categorySafety.keys.sorted().map { "\($0): \(categorySafety[$0]!.rawValue)" }.joined(separator: ", "))}
        """
    let sources = RuleSources(
        ruleSets: [RuleSource(file: "rule-sets/t.yaml", text: ruleSet)],
        profiles: [RuleSource(file: "profiles/p.yaml", text: profile)]
    )
    return try RuleLoader.loadProfile("p", from: sources)
}

extension Date {

    static func daysBefore(_ date: Date, _ days: Double) -> Date {
        date.addingTimeInterval(-days * 86_400)
    }
}

extension EntryOutcome {

    var isDescend: Bool {
        if case .descend = self { true } else { false }
    }
}
