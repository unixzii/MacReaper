/// Identifies a compiled rule. Rules are numbered in order of their qualified ids, so a lower id
/// means a rule whose id sorts first, which is the rule that wins when merged values conflict.
public struct RuleID: Hashable, Comparable, Sendable {

    public let index: Int

    public static func < (lhs: RuleID, rhs: RuleID) -> Bool {
        lhs.index < rhs.index
    }
}

/// Identifies a category of a compiled profile. Numbered in order of qualified ids.
public struct CategoryID: Hashable, Comparable, Sendable {

    public let index: Int

    public static func < (lhs: CategoryID, rhs: CategoryID) -> Bool {
        lhs.index < rhs.index
    }
}

/// Identifies a scope of a compiled profile. Numbered in order of qualified names.
public struct ScopeID: Hashable, Comparable, Sendable {

    public let index: Int

    public static func < (lhs: ScopeID, rhs: ScopeID) -> Bool {
        lhs.index < rhs.index
    }
}

/// A loaded profile, compiled for scanning: references resolved to ids, `~` expanded, globs and
/// templates prepared, and rules indexed by the entries they can apply to.
public struct CompiledRules: Sendable {

    /// Indexed by ``RuleID``, in order of qualified id.
    public let rules: [CompiledRule]
    /// Indexed by ``CategoryID``.
    public let categories: [CompiledCategory]
    /// Qualified scope names, indexed by ``ScopeID``.
    public let scopes: [String]
    /// Absolute paths, without roots that lie inside other roots.
    public let roots: [String]
    public let exclude: [Glob]
    public let maxDepth: Int
    public let preselect: Set<Safety>
    /// The rules that apply to directories.
    public let directoryIndex: RuleIndex
    /// The rules that apply to files.
    public let fileIndex: RuleIndex
    /// Each rule's place in ``inEvaluationOrder(_:)``, indexed by ``RuleID``.
    private let evaluationRanks: [Int]

    /// Compiles a profile that ``RuleLoader`` loaded, so it is known to be valid.
    ///
    /// - Parameter home: The absolute path `~` stands for.
    public init(_ loaded: LoadedProfile, home: String) {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let ruleSets = loaded.ruleSets
        let rulesByID = ruleSets
            .flatMap { ruleSet in ruleSet.rules.map { (ruleSet, $0) } }
            .sorted { $0.1.id.value < $1.1.id.value }
        let interner = Interner(ruleSets: ruleSets)

        rules = rulesByID.enumerated().map { index, entry in
            CompiledRule(entry.1, in: entry.0, id: RuleID(index: index), interner: interner, home: home)
        }
        categories = interner.categoryNames.enumerated().map { index, name in
            CompiledCategory(id: CategoryID(index: index), name: name, profile: loaded.profile, ruleSets: ruleSets)
        }
        scopes = interner.scopeNames

        let expandedRoots = Set(loaded.profile.roots.map { Self.expand($0.value, home: home) })
        roots = expandedRoots
            .filter { root in !expandedRoots.contains { root.hasPrefix($0 + "/") } }
            .sorted()
        exclude = loaded.profile.exclude.map { $0.value.expandingHome(home) }
        maxDepth = loaded.profile.maxDepth
        preselect = Set(loaded.profile.preselect.map(\.value))
        directoryIndex = RuleIndex(rules.filter { $0.condition.kind == .directory }, capacity: rules.count)
        fileIndex = RuleIndex(rules.filter { $0.condition.kind == .file }, capacity: rules.count)

        var ranks = Array(repeating: 0, count: rules.count)
        let categories = categories
        let ordered = rules.sorted { lhs, rhs in
            (Self.evaluationKey(lhs, categories), lhs.id.index) < (Self.evaluationKey(rhs, categories), rhs.id.index)
        }
        for (rank, rule) in ordered.enumerated() {
            ranks[rule.id.index] = rank
        }
        evaluationRanks = ranks
    }

    /// `rules` in the order an entry tries them: skips, then claims, then scope pushes. Claims
    /// that are not fallbacks come first, and among those the strictest category first, so that
    /// when several claims would hold, the first one tried is the one that decides. Ties go to
    /// the lowest rule id.
    public func inEvaluationOrder(_ rules: some Sequence<RuleID>) -> [RuleID] {
        rules.sorted { evaluationRanks[$0.index] < evaluationRanks[$1.index] }
    }

    private static func evaluationKey(_ rule: CompiledRule, _ categories: [CompiledCategory]) -> Int {
        switch rule.action {
        case .skip:
            0
        case .claim(let category, _, let isFallback):
            // 1 to 6: non-fallback before fallback, then dangerous before review before safe.
            1 + (isFallback ? Safety.allCases.count : 0) + (Safety.allCases.count - 1 - Safety.allCases.firstIndex(of: categories[category.index].safety)!)
        case .pushScope:
            1 + 2 * Safety.allCases.count
        }
    }

    public subscript(id: RuleID) -> CompiledRule {
        rules[id.index]
    }

    public subscript(id: CategoryID) -> CompiledCategory {
        categories[id.index]
    }

    public subscript(id: ScopeID) -> String {
        scopes[id.index]
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + path.dropFirst()
        }
        return path
    }
}

public struct CompiledCategory: Sendable {

    public let id: CategoryID
    /// The qualified id.
    public let name: String
    public let title: String
    public let detail: String?
    /// The category's safety, made stricter by the profile where it says so.
    public let safety: Safety
}

extension CompiledCategory {

    init(id: CategoryID, name: String, profile: Profile, ruleSets: [RuleSet]) {
        let (ruleSetID, categoryID) = Interner.split(name)
        let ruleSet = ruleSets.first { $0.id.value == ruleSetID }!
        let category = ruleSet.categories.first { $0.id.value == categoryID }!
        let override = profile.categorySafety.first { $0.category.value == name }?.safety.value
        self.init(
            id: id,
            name: name,
            title: category.title,
            detail: category.detail,
            safety: max(category.safety, override ?? category.safety)
        )
    }
}

/// Numbers categories and scopes in order of their qualified names, and resolves the bare or
/// qualified references rules make to them.
struct Interner {

    let categoryNames: [String]
    let scopeNames: [String]
    private let categoryIDs: [String: CategoryID]
    private let scopeIDs: [String: ScopeID]

    init(ruleSets: [RuleSet]) {
        categoryNames = ruleSets
            .flatMap { ruleSet in ruleSet.categories.map { "\(ruleSet.id.value).\($0.id.value)" } }
            .sorted()
        scopeNames = Set(ruleSets.flatMap { ruleSet in
            ruleSet.rules.compactMap { rule -> String? in
                guard case .pushScope(let name, _) = rule.action else {
                    return nil
                }
                return "\(ruleSet.id.value).\(name.value)"
            }
        }).sorted()
        categoryIDs = Dictionary(uniqueKeysWithValues: categoryNames.enumerated().map { ($1, CategoryID(index: $0)) })
        scopeIDs = Dictionary(uniqueKeysWithValues: scopeNames.enumerated().map { ($1, ScopeID(index: $0)) })
    }

    func category(_ reference: String, in ruleSet: RuleSet) -> CategoryID {
        categoryIDs[Self.qualified(reference, in: ruleSet)]!
    }

    func scope(_ reference: String, in ruleSet: RuleSet) -> ScopeID {
        scopeIDs[Self.qualified(reference, in: ruleSet)]!
    }

    static func qualified(_ reference: String, in ruleSet: RuleSet) -> String {
        reference.contains(".") ? reference : "\(ruleSet.id.value).\(reference)"
    }

    static func split(_ qualified: String) -> (owner: String, id: String) {
        let parts = qualified.split(separator: ".", maxSplits: 1)
        return (String(parts[0]), String(parts[1]))
    }
}
