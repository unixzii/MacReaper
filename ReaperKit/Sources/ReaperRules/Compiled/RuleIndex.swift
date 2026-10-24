/// Finds the rules worth evaluating for an entry without testing every rule against it.
///
/// Every rule is filed under one of its conditions that the entry's name, path or children can
/// settle with a hash lookup: a literal name, a name suffix like `*.app`, a literal path, the
/// parent of a `dir/*` path, or a child name. Rules with no such condition are kept on a short
/// list and tested one by one. A lookup may return rules whose other conditions fail, but it
/// never leaves out a rule that could hold.
public struct RuleIndex: Sendable {

    private enum Key: Equatable {
        case name(String)
        case nameSuffix(String)
        case path(String)
        case parentPath(String)
        case child(String)
        case childSuffix(String)
    }

    /// A condition no table can answer, tested directly.
    private enum Residual: Sendable {
        case name([Glob])
        case path([Glob])
        /// Holds when a child matches the glob.
        case child(Glob)
        /// Holds when a child matches any of the globs.
        case anyChild([Glob])
    }

    /// The number of rules compiled together, which sizes every ``RuleSelection``.
    private let capacity: Int
    private var byName: [String: [RuleID]] = [:]
    private var byNameSuffix = SuffixTable()
    private var byPath: [String: [RuleID]] = [:]
    private var byParentPath: [String: [RuleID]] = [:]
    private var byChild: [String: [RuleID]] = [:]
    private var byChildSuffix = SuffixTable()
    private var residuals: [(rule: RuleID, condition: Residual)] = []

    /// - Parameters:
    ///   - rules: The rules to index, all for the same kind of entry.
    ///   - capacity: The number of rules compiled together.
    init(_ rules: [CompiledRule], capacity: Int) {
        self.capacity = capacity
        for rule in rules {
            if let keys = Self.keys(for: rule.condition) {
                for key in keys {
                    insert(rule.id, under: key)
                }
            } else {
                residuals.append((rule.id, Self.residual(for: rule.condition)))
            }
        }
    }

    /// The rules that could hold for an entry.
    ///
    /// - Parameters:
    ///   - name: The entry's name.
    ///   - path: The entry's absolute path.
    ///   - children: The names of the entry's children; empty for files.
    public func candidates(name: String, path: String, children: some Collection<String>) -> RuleSelection {
        var selection = RuleSelection(capacity: capacity)
        let name = name.precomposedForMatching
        selection.insert(contentsOf: byName[name])
        byNameSuffix.lookUp(name, into: &selection)

        if !byPath.isEmpty || !byParentPath.isEmpty {
            let path = path.precomposedForMatching
            selection.insert(contentsOf: byPath[path])
            if let slash = path.lastIndex(of: "/"), slash != path.startIndex {
                selection.insert(contentsOf: byParentPath[String(path[..<slash])])
            }
        }

        if !byChild.isEmpty || !byChildSuffix.isEmpty {
            for child in children {
                let child = child.precomposedForMatching
                selection.insert(contentsOf: byChild[child])
                byChildSuffix.lookUp(child, into: &selection)
            }
        }

        for (rule, condition) in residuals where !selection.contains(rule) {
            if Self.holds(condition, name: name, path: path, children: children) {
                selection.insert(rule)
            }
        }
        return selection
    }

    // MARK: Filing

    /// The keys to file a rule under, from the most selective condition that has them, or `nil`
    /// when no condition can be keyed. One condition suffices: all conditions must hold, so any
    /// one of them is a necessary condition.
    private static func keys(for condition: CompiledCondition) -> [Key]? {
        let nameShapes = condition.name.map(\.shape)
        if !nameShapes.isEmpty, let keys = keys(nameShapes, allowingSuffix: false) {
            return keys
        }
        let pathKeys = condition.path.map { glob -> Key? in
            switch glob.shape {
            case .literal(let path): .path(path)
            case .child(let parent): .parentPath(parent)
            case .suffix, .other: nil
            }
        }
        if !pathKeys.isEmpty, !pathKeys.contains(where: { $0 == nil }) {
            return pathKeys.compactMap { $0 }
        }
        if !nameShapes.isEmpty, let keys = keys(nameShapes, allowingSuffix: true) {
            return keys
        }
        // `contains` needs every child, so any one of them will do.
        if let key = condition.contains.lazy.compactMap(childKey).first {
            return [key]
        }
        // `containsAny` needs one of its children, so all of them must be keyed.
        let anyKeys = condition.containsAny.map(childKey)
        if !anyKeys.isEmpty, !anyKeys.contains(where: { $0 == nil }) {
            return anyKeys.compactMap { $0 }
        }
        return nil
    }

    private static func keys(_ shapes: [Glob.Shape], allowingSuffix: Bool) -> [Key]? {
        var keys: [Key] = []
        for shape in shapes {
            switch shape {
            case .literal(let name):
                keys.append(.name(name))
            case .suffix(let suffix) where allowingSuffix:
                keys.append(.nameSuffix(suffix))
            default:
                return nil
            }
        }
        return keys
    }

    private static func childKey(_ pattern: ChildPattern) -> Key? {
        switch pattern {
        case .path(let path):
            .child(String(path.prefix { $0 != "/" }))
        case .name(let glob):
            switch glob.shape {
            case .literal(let name): .child(name)
            case .suffix(let suffix): .childSuffix(suffix)
            case .child, .other: nil
            }
        }
    }

    /// Picks the condition to test directly for a rule with no keyable condition. Validation
    /// guarantees the rule has at least one of these.
    private static func residual(for condition: CompiledCondition) -> Residual {
        if !condition.name.isEmpty {
            return .name(condition.name)
        }
        if !condition.path.isEmpty {
            return .path(condition.path)
        }
        if case .name(let glob) = condition.contains.first {
            return .child(glob)
        }
        return .anyChild(condition.containsAny.compactMap { pattern in
            if case .name(let glob) = pattern { glob } else { nil }
        })
    }

    private mutating func insert(_ rule: RuleID, under key: Key) {
        switch key {
        case .name(let name): byName[name, default: []].append(rule)
        case .nameSuffix(let suffix): byNameSuffix.insert(rule, under: suffix)
        case .path(let path): byPath[path, default: []].append(rule)
        case .parentPath(let path): byParentPath[path, default: []].append(rule)
        case .child(let name): byChild[name, default: []].append(rule)
        case .childSuffix(let suffix): byChildSuffix.insert(rule, under: suffix)
        }
    }

    private static func holds(_ condition: Residual, name: String, path: String, children: some Collection<String>) -> Bool {
        switch condition {
        case .name(let globs):
            globs.contains { $0.matches(name) }
        case .path(let globs):
            globs.contains { $0.matches(path) }
        case .child(let glob):
            children.contains { glob.matches($0) }
        case .anyChild(let globs):
            children.contains { child in globs.contains { $0.matches(child) } }
        }
    }
}

/// Rules filed by name suffix, looked up by trying each suffix length that occurs.
private struct SuffixTable: Sendable {

    private var rulesBySuffix: [String: [RuleID]] = [:]
    /// The distinct UTF-8 lengths of the suffixes.
    private var lengths: [Int] = []

    var isEmpty: Bool {
        rulesBySuffix.isEmpty
    }

    mutating func insert(_ rule: RuleID, under suffix: String) {
        rulesBySuffix[suffix, default: []].append(rule)
        if !lengths.contains(suffix.utf8.count) {
            lengths.append(suffix.utf8.count)
        }
    }

    func lookUp(_ name: String, into selection: inout RuleSelection) {
        let bytes = name.utf8
        for length in lengths where length <= bytes.count {
            let suffix = String(decoding: bytes.suffix(length), as: UTF8.self)
            selection.insert(contentsOf: rulesBySuffix[suffix])
        }
    }
}

/// A set of rule ids. Iterating it yields ids in ascending order, which is the order of the
/// rules' qualified ids.
///
/// The first 64 ids are kept inline, so rules compiled together, up to 64 of them, never allocate one.
public struct RuleSelection: Sequence, Sendable {

    private var low: UInt64 = 0
    /// Ids from 64 up, 64 to a word.
    private var high: [UInt64]

    init(capacity: Int) {
        high = capacity > 64 ? Array(repeating: 0, count: (capacity - 1) / 64) : []
    }

    public var isEmpty: Bool {
        low == 0 && high.allSatisfy { $0 == 0 }
    }

    public func contains(_ rule: RuleID) -> Bool {
        let bit: UInt64 = 1 << UInt64(rule.index % 64)
        return rule.index < 64 ? low & bit != 0 : high[rule.index / 64 - 1] & bit != 0
    }

    mutating func insert(_ rule: RuleID) {
        let bit: UInt64 = 1 << UInt64(rule.index % 64)
        if rule.index < 64 {
            low |= bit
        } else {
            high[rule.index / 64 - 1] |= bit
        }
    }

    mutating func insert(contentsOf rules: [RuleID]?) {
        for rule in rules ?? [] {
            insert(rule)
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(low: low, high: high)
    }

    public struct Iterator: IteratorProtocol {

        private let high: [UInt64]
        /// The word being iterated: 0 for `low`, then 1 + an index into `high`.
        private var wordIndex = 0
        private var remaining: UInt64

        init(low: UInt64, high: [UInt64]) {
            self.high = high
            remaining = low
        }

        public mutating func next() -> RuleID? {
            while remaining == 0 {
                guard wordIndex < high.count else {
                    return nil
                }
                remaining = high[wordIndex]
                wordIndex += 1
            }
            let bit = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            return RuleID(index: wordIndex * 64 + bit)
        }
    }
}
