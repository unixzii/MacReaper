import Yams

/// A rule set document, as written. References are not resolved yet.
public struct RuleSet: Sendable {

    public var id: Located<String>
    public var title: String
    public var description: String
    public var categories: [Category]
    public var rules: [Rule]
}

// MARK: - Reading

extension RuleSet {

    /// Returns `nil` when a required part is unusable.
    init?(_ node: Node, reader: inout DocumentReader) {
        guard let fields = reader.mapping(
            node,
            "a rule set",
            allowed: ["format", "id", "title", "description", "categories", "rules"],
            required: ["format", "id", "title", "description", "rules"]
        ) else {
            return nil
        }

        if let format = fields["format"] {
            reader.format(format)
        }
        let id = fields["id"].flatMap { reader.identifier($0, "the rule set id", form: .id) }
        let title = fields["title"].flatMap { reader.text($0, "`title`") }
        let description = fields["description"].flatMap { reader.text($0, "`description`") }
        let categories = fields["categories"].flatMap { node in
            reader.dictionary(node, "`categories`")?.compactMap { key, value in
                Category(id: key, value, reader: &reader)
            }
        } ?? []
        let rules = fields["rules"].flatMap { node in
            reader.list(node, "`rules`", allowsEmpty: true) { reader, node in Rule(node, reader: &reader) }
        } ?? []

        guard let id, let title, let description else {
            return nil
        }
        self.init(
            id: id,
            title: title.value,
            description: description.value,
            categories: categories,
            rules: rules
        )
    }
}

// MARK: - Validation

extension RuleSet {

    func validate(_ context: inout ValidationContext) {
        for rule in rules {
            rule.validate(in: self, context: &context)
        }
    }
}
