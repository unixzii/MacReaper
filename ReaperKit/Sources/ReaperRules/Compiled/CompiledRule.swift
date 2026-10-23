/// A rule, ready to evaluate.
public struct CompiledRule: Sendable {

    public let id: RuleID
    /// The qualified id, for provenance and diagnostics.
    public let name: String
    /// What the rule is for, as written in the rule set.
    public let description: String?
    public let ruleSet: String
    public let condition: CompiledCondition
    public let action: CompiledAction
}

/// A rule's conditions, with `~` expanded in path globs and references resolved to ids.
public struct CompiledCondition: Sendable {

    public let kind: Condition.Kind
    public let name: [Glob]
    public let path: [Glob]
    public let capture: CaptureRegex?
    public let contains: [ChildPattern]
    public let containsAny: [ChildPattern]
    /// Rendered for each entry, then matched as a name glob against its siblings.
    public let sibling: CompiledTemplate?
    public let scope: CompiledScopeTest?
    public let olderThan: Duration?
    public let check: CompiledCheck?
}

public struct CompiledScopeTest: Sendable {

    public let scope: ScopeID
    public let distance: ScopeTest.Distance
}

public struct CompiledCheck: Sendable {

    public let name: String
    public let arguments: [String: ScalarValue]
    public let expectations: [String: ScalarValue]
}

public enum CompiledAction: Sendable {
    case pushScope(ScopeID, assignments: [CompiledAssignment])
    case claim(CategoryID, assignments: [CompiledAssignment], isFallback: Bool)
    case skip
}

public struct CompiledAssignment: Sendable {

    public let variable: String
    public let template: CompiledTemplate
}

/// A `capture` regex.
///
/// `Regex<AnyRegexOutput>` is not `Sendable` because its output may hold arbitrary types. One
/// built from a pattern string holds only strings and ranges, and its lazily compiled program is
/// published atomically, so sharing it between scanning threads is safe.
public struct CaptureRegex: @unchecked Sendable {

    public let pattern: String
    public let regex: Regex<AnyRegexOutput>
}

// MARK: - Compiling

extension CompiledRule {

    init(_ rule: Rule, in ruleSet: RuleSet, id: RuleID, interner: Interner, home: String) {
        self.init(
            id: id,
            name: rule.id.value,
            description: rule.description,
            ruleSet: ruleSet.id.value,
            condition: CompiledCondition(rule.when, in: ruleSet, interner: interner, home: home),
            action: CompiledAction(rule.action, in: ruleSet, interner: interner)
        )
    }
}

extension CompiledCondition {

    init(_ condition: Condition, in ruleSet: RuleSet, interner: Interner, home: String) {
        self.init(
            kind: condition.kind,
            name: condition.name.map(\.value),
            path: condition.path.map { $0.value.expandingHome(home) },
            // Validation compiled the same pattern, so this cannot fail.
            capture: condition.capture.map { CaptureRegex(pattern: $0.value, regex: try! Regex($0.value)) },
            contains: condition.contains.map(\.value),
            containsAny: condition.containsAny.map(\.value),
            sibling: condition.sibling.map { CompiledTemplate($0.value, in: ruleSet, interner: interner) },
            scope: condition.scope.map { scope in
                CompiledScopeTest(scope: interner.scope(scope.name.value, in: ruleSet), distance: scope.distance)
            },
            olderThan: condition.olderThan?.value,
            check: condition.check.map { check in
                CompiledCheck(
                    name: check.name.value,
                    arguments: Dictionary(uniqueKeysWithValues: check.arguments.map { ($0.key.value, $0.value.value) }),
                    expectations: Dictionary(uniqueKeysWithValues: check.expectations.map { ($0.key.value, $0.value.value) })
                )
            }
        )
    }
}

extension CompiledAction {

    init(_ action: Action, in ruleSet: RuleSet, interner: Interner) {
        func compile(_ assignments: [Assignment]) -> [CompiledAssignment] {
            assignments.map { assignment in
                CompiledAssignment(
                    variable: assignment.variable.value,
                    template: CompiledTemplate(assignment.template.value, in: ruleSet, interner: interner)
                )
            }
        }

        switch action {
        case .pushScope(let name, let assignments):
            self = .pushScope(interner.scope(name.value, in: ruleSet), assignments: compile(assignments))
        case .claim(let category, let assignments, let isFallback):
            self = .claim(interner.category(category.value, in: ruleSet), assignments: compile(assignments), isFallback: isFallback)
        case .skip:
            self = .skip
        }
    }
}
