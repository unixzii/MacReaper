import Yams

/// A rule's action. Exactly one of these.
public enum Action: Sendable {
    /// `name` is a bare scope id, declared in the rule's own rule set.
    case pushScope(name: Located<String>, assignments: [Assignment])
    /// `category` is a category reference, bare or qualified.
    case claim(category: Located<String>, assignments: [Assignment], isFallback: Bool)
    case skip
}

/// One entry of a `set` map: a variable and the template that computes it.
public struct Assignment: Sendable {

    public var variable: Located<String>
    public var template: Located<String>
}

// MARK: - Reading

extension Action {

    init?(_ node: Node, reader: inout DocumentReader) {
        guard let fields = reader.mapping(node, "`action`", allowed: ["pushScope", "claim", "skip"], reserved: ["run"]) else {
            return nil
        }
        guard fields.entries.count == 1, let entry = fields.entries.first else {
            // An action holding only unknown or reserved keys has already been reported.
            if fields.entries.count > 1 || node.mapping?.isEmpty == true {
                reader.report(.actionNotSingle, "`action` must have exactly one of pushScope, claim or skip", at: fields.location)
            }
            return nil
        }

        let (key, value) = entry
        switch key.value {
        case "pushScope":
            guard let action = Self.pushScope(value, reader: &reader) else {
                return nil
            }
            self = action
        case "claim":
            guard let action = Self.claim(value, reader: &reader) else {
                return nil
            }
            self = action
        default:
            guard let skip = reader.boolean(value, "`skip`") else {
                return nil
            }
            guard skip.value else {
                reader.report(.invalidValue, "`skip` can only be true; remove the action instead", at: skip.location)
                return nil
            }
            self = .skip
        }
    }

    private static func pushScope(_ node: Node, reader: inout DocumentReader) -> Action? {
        if case .scalar = node {
            return reader.identifier(node, "the scope", form: .id).map { .pushScope(name: $0, assignments: []) }
        }
        guard let fields = reader.mapping(node, "`pushScope`", allowed: ["name", "set"], required: ["name"]) else {
            return nil
        }
        let name = fields["name"].flatMap { reader.identifier($0, "the scope", form: .id) }
        let assignments = fields["set"].flatMap { assignments($0, reader: &reader) } ?? []
        return name.map { .pushScope(name: $0, assignments: assignments) }
    }

    private static func claim(_ node: Node, reader: inout DocumentReader) -> Action? {
        if case .scalar = node {
            return reader.identifier(node, "the category", form: .reference)
                .map { .claim(category: $0, assignments: [], isFallback: false) }
        }
        guard let fields = reader.mapping(node, "`claim`", allowed: ["category", "set", "fallback"], required: ["category"]) else {
            return nil
        }
        let category = fields["category"].flatMap { reader.identifier($0, "the category", form: .reference) }
        let assignments = fields["set"].flatMap { assignments($0, reader: &reader) } ?? []
        let fallback = fields["fallback"].flatMap { reader.boolean($0, "`fallback`") }
        return category.map { .claim(category: $0, assignments: assignments, isFallback: fallback?.value ?? false) }
    }

    private static func assignments(_ node: Node, reader: inout DocumentReader) -> [Assignment]? {
        reader.dictionary(node, "`set`")?.compactMap { key, value in
            guard let variable = reader.identifier(key, "a variable", form: .variable) else {
                return nil
            }
            return reader.string(value, "`\(key.value)`").map { Assignment(variable: variable, template: $0) }
        }
    }
}

// MARK: - Validation

extension Action {

    func validate(in ruleSet: RuleSet, ruleID: String, variables: AvailableVariables, context: inout ValidationContext) {
        let assignments: [Assignment]
        switch self {
        case .pushScope(_, let pushed):
            assignments = pushed
        case .claim(let category, let claimed, _):
            _ = context.resolve(category, in: ruleSet, as: .category, ruleID: ruleID)
            assignments = claimed
        case .skip:
            assignments = []
        }
        for assignment in assignments {
            context.validateTemplate(assignment.template, variables: variables, in: ruleSet, ruleID: ruleID)
        }
    }
}
