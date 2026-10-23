import Yams

public struct Rule: Sendable {

    public var id: Located<String>
    public var description: String?
    public var when: Condition
    public var action: Action
}

// MARK: - Reading

extension Rule {

    /// Returns `nil` when a required part is unusable. Diagnostics found inside the rule carry
    /// its id.
    init?(_ node: Node, reader: inout DocumentReader) {
        guard let fields = reader.mapping(
            node,
            "a rule",
            allowed: ["id", "description", "when", "action"],
            required: ["id", "when", "action"]
        ) else {
            return nil
        }
        let id = fields["id"].flatMap { reader.identifier($0, "the rule id", form: .qualified) }
        let outerRuleID = reader.ruleID
        reader.ruleID = id?.value
        defer { reader.ruleID = outerRuleID }

        let description = fields["description"].flatMap { reader.string($0, "`description`") }
        let when = fields["when"].flatMap { Condition($0, reader: &reader) }
        let action = fields["action"].flatMap { Action($0, reader: &reader) }
        guard let id, let when, let action else {
            return nil
        }
        self.init(id: id, description: description?.value, when: when, action: action)
    }
}

// MARK: - Validation

extension Rule {

    func validate(in ruleSet: RuleSet, context: inout ValidationContext) {
        let ruleID = id.value
        if !ruleID.hasPrefix(ruleSet.id.value + ".") {
            context.report(.missingRuleSetPrefix, "the rule id must start with `\(ruleSet.id.value).`", at: id.location, ruleID: ruleID)
        }
        if !context.ruleIDs.insert(ruleID).inserted {
            context.report(.duplicateID, "another rule already has the id `\(ruleID)`", at: id.location, ruleID: ruleID)
        }

        let variables = when.validate(in: ruleSet, ruleID: ruleID, context: &context)
        action.validate(in: ruleSet, ruleID: ruleID, variables: variables, context: &context)
    }
}
