import Yams

/// A rule's flat `when` map. Absent list conditions are empty.
public struct Condition: Sendable {

    public enum Kind: String, Hashable, Sendable {
        case directory = "dir"
        case file
    }

    public var kind: Kind
    public var name: [Located<Glob>]
    public var path: [Located<Glob>]
    public var capture: Located<String>?
    public var contains: [Located<ChildPattern>]
    public var containsAny: [Located<ChildPattern>]
    public var sibling: Located<String>?
    public var scope: ScopeTest?
    public var olderThan: Located<Duration>?
    public var check: CheckCall?
    public var location: SourceLocation
}

/// An entry of `contains` or `containsAny`: a glob over child names, or a literal relative path.
public enum ChildPattern: Hashable, Sendable {
    case name(Glob)
    case path(String)
}

/// A `scope` condition.
public struct ScopeTest: Sendable {

    public enum Distance: Hashable, Sendable {
        case any
        case exactly(Int)
        case atMost(Int)
    }

    /// A scope reference, bare or qualified.
    public var name: Located<String>
    public var distance: Distance
}

// MARK: - Reading

extension Condition {

    init?(_ node: Node, reader: inout DocumentReader) {
        guard let fields = reader.mapping(
            node,
            "`when`",
            allowed: [
                "kind", "name", "path", "capture", "contains", "containsAny", "sibling", "scope", "olderThan", "check",
            ]
        ) else {
            return nil
        }

        let kind = fields["kind"].flatMap { reader.value($0, "`kind`", as: Kind.self, expected: "dir or file") }
        let name = fields["name"].flatMap { node in
            reader.list(node, "`name`", allowsSingle: true) { $0.glob($1, "a name glob", flavor: .name) }
        } ?? []
        let path = fields["path"].flatMap { node in
            reader.list(node, "`path`", allowsSingle: true) { $0.glob($1, "a path glob", flavor: .path) }
        } ?? []
        let capture = fields["capture"].flatMap { reader.text($0, "`capture`") }
        let contains = fields["contains"].flatMap { node in
            reader.list(node, "`contains`", allowsSingle: true) { reader, node in Self.childPattern(node, reader: &reader) }
        } ?? []
        let containsAny = fields["containsAny"].flatMap { node in
            reader.list(node, "`containsAny`") { reader, node in Self.childPattern(node, reader: &reader) }
        } ?? []
        let sibling = fields["sibling"].flatMap { reader.text($0, "`sibling`") }
        let scope = fields["scope"].flatMap { ScopeTest($0, reader: &reader) }
        let olderThan = fields["olderThan"].flatMap { Self.duration($0, reader: &reader) }
        let check = fields["check"].flatMap { CheckCall($0, reader: &reader) }

        // Every rule must be reachable from the scanner's index.
        if !["name", "path", "contains", "containsAny"].contains(where: fields.contains) {
            reader.report(.notIndexable, "`when` needs at least one of name, path, contains or containsAny", at: fields.location)
        }
        if kind?.value == .file, !fields.contains("name"), !fields.contains("path") {
            reader.report(.fileRuleNeedsNameOrPath, "a `kind: file` rule needs name or path", at: fields.location)
        }

        self.init(
            kind: kind?.value ?? .directory,
            name: name,
            path: path,
            capture: capture,
            contains: contains,
            containsAny: containsAny,
            sibling: sibling,
            scope: scope,
            olderThan: olderThan,
            check: check,
            location: fields.location
        )
    }

    private static func childPattern(_ node: Node, reader: inout DocumentReader) -> Located<ChildPattern>? {
        guard let text = reader.text(node, "a child") else {
            return nil
        }
        guard text.value.contains("/") else {
            return reader.glob(node, "a child", flavor: .name).map { Located(.name($0.value), at: $0.location) }
        }
        if text.value.hasPrefix("/") || text.value.contains(where: { "*?[\\".contains($0) }) {
            reader.report(.invalidGlob, "a child path like `\(text.value)` must be relative and literal", at: text.location)
            return nil
        }
        return Located(.path(text.value), at: text.location)
    }

    private static func duration(_ node: Node, reader: inout DocumentReader) -> Located<Duration>? {
        guard let text = reader.string(node, "`olderThan`") else {
            return nil
        }
        guard let match = text.value.wholeMatch(of: /([0-9]+)([smhdw])/), let count = Int64(match.1) else {
            reader.report(.invalidDuration, "`\(text.value)` is not a duration like 30d, 12h or 8w", at: text.location)
            return nil
        }
        let unit: Int64 = switch match.2 {
        case "s": 1
        case "m": 60
        case "h": 3_600
        case "d": 86_400
        default: 604_800
        }
        return Located(.seconds(count * unit), at: text.location)
    }
}

extension ScopeTest {

    init?(_ node: Node, reader: inout DocumentReader) {
        if case .scalar = node {
            guard let name = reader.identifier(node, "the scope", form: .reference) else {
                return nil
            }
            self.init(name: name, distance: .any)
            return
        }
        guard let fields = reader.mapping(node, "`scope`", allowed: ["name", "distance", "maxDistance"], required: ["name"]) else {
            return nil
        }
        let name = fields["name"].flatMap { reader.identifier($0, "the scope", form: .reference) }
        let distance = fields["distance"].flatMap { reader.integer($0, "`distance`", in: 1...Int.max) }
        let maxDistance = fields["maxDistance"].flatMap { reader.integer($0, "`maxDistance`", in: 1...Int.max) }
        if fields.contains("distance"), fields.contains("maxDistance") {
            reader.report(.conflictingDistance, "use either `distance` or `maxDistance`, not both", at: fields.location)
            return nil
        }
        guard let name else {
            return nil
        }
        if let distance {
            self.init(name: name, distance: .exactly(distance.value))
        } else if let maxDistance {
            self.init(name: name, distance: .atMost(maxDistance.value))
        } else {
            self.init(name: name, distance: .any)
        }
    }
}

// MARK: - Validation

extension Condition {

    /// Validates the conditions and returns the variables they make available to templates.
    func validate(in ruleSet: RuleSet, ruleID: String, context: inout ValidationContext) -> AvailableVariables {
        validateIndexability(ruleID: ruleID, context: &context)

        var variables = AvailableVariables()
        if let capture {
            switch RegexSyntax.groupNames(in: capture.value) {
            case .success(let names):
                variables.names.formUnion(names)
            case .failure(let error):
                context.report(.invalidRegex, "`capture` does not compile: \(error.message)", at: capture.location, ruleID: ruleID)
            }
        }
        if let check {
            variables.names.formUnion(check.validate(ruleID: ruleID, context: &context))
        }
        variables.scope = scope.flatMap { context.resolve($0.name, in: ruleSet, as: .scope, ruleID: ruleID) }
        if let sibling {
            context.validateTemplate(sibling, variables: variables, in: ruleSet, ruleID: ruleID)
        }
        return variables
    }

    /// The globs the index is keyed by need a literal character.
    private func validateIndexability(ruleID: String, context: inout ValidationContext) {
        var globs = name
        for child in contains + containsAny {
            if case .name(let glob) = child.value {
                globs.append(Located(glob, at: child.location))
            }
        }
        for glob in globs where !glob.value.hasLiteral {
            context.report(
                .globWithoutLiteral,
                "`\(glob.value.pattern)` has no literal character, so the rule cannot be indexed",
                at: glob.location,
                ruleID: ruleID
            )
        }
    }
}
