import Yams

/// A profile document: where to scan, how deep, and with which rule sets.
public struct Profile: Sendable {

    public var id: Located<String>
    public var title: String
    public var roots: [Located<String>]
    public var exclude: [Located<Glob>]
    public var maxDepth: Int
    public var ruleSets: [Located<String>]
    public var preselect: [Located<Safety>]
    public var categorySafety: [CategoryOverride]
}

public struct CategoryOverride: Sendable {

    /// A qualified category id.
    public var category: Located<String>
    public var safety: Located<Safety>
}

// MARK: - Reading

extension Profile {

    /// Returns `nil` when a required part is unusable.
    init?(_ node: Node, reader: inout DocumentReader) {
        guard let fields = reader.mapping(
            node,
            "a profile",
            allowed: ["format", "id", "title", "roots", "exclude", "maxDepth", "ruleSets", "preselect", "categorySafety"],
            required: ["format", "id", "title", "roots", "maxDepth", "ruleSets", "preselect"]
        ) else {
            return nil
        }

        if let format = fields["format"] {
            reader.format(format)
        }
        let id = fields["id"].flatMap { reader.identifier($0, "the profile id", form: .id) }
        let title = fields["title"].flatMap { reader.text($0, "`title`") }
        let roots = fields["roots"].flatMap { node in
            reader.list(node, "`roots`") { reader, node in Self.root(node, reader: &reader) }
        }
        let exclude = fields["exclude"].flatMap { node in
            reader.list(node, "`exclude`", allowsEmpty: true) { $0.glob($1, "an exclude glob", flavor: .path) }
        } ?? []
        let maxDepth = fields["maxDepth"].flatMap { reader.integer($0, "`maxDepth`", in: 1...64) }
        let ruleSets = fields["ruleSets"].flatMap { node in
            reader.list(node, "`ruleSets`") { $0.identifier($1, "a rule set", form: .id) }
        }
        if let ruleSets {
            reader.reportRepeats(ruleSets, "`ruleSets`")
        }
        let preselect = fields["preselect"].flatMap { node in
            reader.list(node, "`preselect`", allowsEmpty: true) { reader, node in Self.preselectedSafety(node, reader: &reader) }
        }
        let categorySafety = fields["categorySafety"].flatMap { Self.categoryOverrides($0, reader: &reader) } ?? []

        guard let id, let title, let roots, let maxDepth, let ruleSets, let preselect else {
            return nil
        }
        self.init(
            id: id,
            title: title.value,
            roots: roots,
            exclude: exclude,
            maxDepth: maxDepth.value,
            ruleSets: ruleSets,
            preselect: preselect,
            categorySafety: categorySafety
        )
    }

    /// A root must have a parent directory, because the walker lists it to find the root's own
    /// attributes and siblings. That rules out `/`.
    private static func root(_ node: Node, reader: inout DocumentReader) -> Located<String>? {
        guard let root = reader.text(node, "a root") else {
            return nil
        }
        let value = root.value
        guard value == "~" || value.hasPrefix("~/") || (value.hasPrefix("/") && value.contains(where: { $0 != "/" })) else {
            reader.report(.invalidValue, "a root must be \"~\", start with ~/, or be an absolute path other than /", at: root.location)
            return nil
        }
        return root
    }

    private static func preselectedSafety(_ node: Node, reader: inout DocumentReader) -> Located<Safety>? {
        guard let safety = reader.safety(node, "a preselected safety level") else {
            return nil
        }
        if safety.value == .dangerous {
            reader.report(.dangerousPreselect, "dangerous candidates are never preselected", at: safety.location)
            return nil
        }
        return safety
    }

    private static func categoryOverrides(_ node: Node, reader: inout DocumentReader) -> [CategoryOverride]? {
        reader.dictionary(node, "`categorySafety`")?.compactMap { key, value in
            guard let category = reader.identifier(key, "a category", form: .qualified),
                  let safety = reader.safety(value, "`\(key.value)`") else {
                return nil
            }
            return CategoryOverride(category: category, safety: safety)
        }
    }
}

// MARK: - Validation

extension Profile {

    /// Validates the profile against the rule sets it loads.
    func validate(loading ruleSets: [RuleSet], context: inout ValidationContext) {
        validateRequires(of: ruleSets, context: &context)
        validateCategorySafety(context: &context)
    }

    /// A profile must load everything its rule sets require.
    private func validateRequires(of ruleSets: [RuleSet], context: inout ValidationContext) {
        let loaded = Set(ruleSets.map(\.id.value))
        for ruleSet in ruleSets {
            for required in ruleSet.requires where !loaded.contains(required.value) {
                let entry = self.ruleSets.first { $0.value == ruleSet.id.value }
                context.report(
                    .profileMissingRequiredRuleSet,
                    "`\(ruleSet.id.value)` requires `\(required.value)`, which the profile does not load",
                    at: entry?.location ?? id.location
                )
            }
        }
    }

    /// Overrides may only make a category stricter.
    private func validateCategorySafety(context: inout ValidationContext) {
        for override in categorySafety {
            guard let category = context.categories[override.category.value] else {
                context.report(
                    .unknownCategory,
                    "no loaded rule set declares `\(override.category.value)`",
                    at: override.category.location
                )
                continue
            }
            if override.safety.value < category.safety {
                context.report(
                    .safetyLowered,
                    "a profile may only make `\(override.category.value)` stricter than \(category.safety.rawValue)",
                    at: override.safety.location
                )
            }
        }
    }
}
