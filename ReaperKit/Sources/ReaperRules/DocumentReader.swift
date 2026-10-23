import Yams

/// Reads YAML nodes into values, turning every structural problem into a diagnostic. Reading
/// continues after a problem, so one pass reports as many problems as possible.
///
/// Document types read themselves with an `init?(_:reader:)` built from these primitives.
///
/// Scalars are interpreted by the YAML 1.2 core schema rather than by Yams's YAML 1.1 resolver,
/// so `name: yes` is the string `yes`. Plain `~`, `null` and empty values are null, and plain
/// `true` and `false` are booleans.
struct DocumentReader {

    let file: String
    private(set) var diagnostics: [RuleDiagnostic] = []
    /// The rule being read, attached to diagnostics.
    var ruleID: String?

    init(file: String) {
        self.file = file
    }

    // MARK: Documents

    /// Parses `text`, reporting syntax errors and duplicate keys.
    mutating func root(of text: String) -> Node? {
        do {
            guard let node = try Yams.compose(yaml: text) else {
                report(.wrongType, "the document is empty", at: SourceLocation(file: file, line: 1, column: 1))
                return nil
            }
            return node
        } catch let error as YamlError {
            switch error {
            case .duplicatedKeysInMapping(let duplicates, let context):
                let keys = duplicates.map { "`\($0)`" }.joined(separator: ", ")
                report(.duplicateKey, "\(keys) appears more than once", at: location(of: context.mark))
            case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _),
                 .composer(_, let problem, let mark, _):
                report(.yamlSyntax, problem, at: location(of: mark))
            default:
                report(.yamlSyntax, "\(error)", at: SourceLocation(file: file, line: 1, column: 1))
            }
            return nil
        } catch {
            report(.yamlSyntax, "\(error)", at: SourceLocation(file: file, line: 1, column: 1))
            return nil
        }
    }

    /// Reads `format`, which must be the integer 1.
    mutating func format(_ node: Node) {
        guard let format = integer(node, "`format`") else {
            return
        }
        if format.value != 1 {
            report(.unsupportedFormat, "format \(format.value) is not supported; this loader reads format 1", at: format.location)
        }
    }

    // MARK: Diagnostics

    mutating func report(_ code: DiagnosticCode, _ message: String, at location: SourceLocation) {
        diagnostics.append(RuleDiagnostic(code: code, message: message, location: location, ruleID: ruleID))
    }

    func location(of node: Node) -> SourceLocation {
        node.mark.map(location(of:)) ?? SourceLocation(file: file, line: 1, column: 1)
    }

    private func location(of mark: Mark) -> SourceLocation {
        SourceLocation(file: file, line: mark.line, column: mark.column)
    }

    // MARK: Mappings

    /// Reads a mapping whose keys must come from `allowed`. Unknown and `reserved` keys are
    /// reported and dropped, and missing `required` keys are reported.
    mutating func mapping(
        _ node: Node,
        _ what: String,
        allowed: Set<String>,
        required: [String] = [],
        reserved: Set<String> = []
    ) -> Mapping? {
        guard case .mapping(let pairs) = node else {
            report(.wrongType, "\(what) must be a mapping", at: location(of: node))
            return nil
        }
        var mapping = Mapping(location: location(of: node))
        for (key, value) in pairs {
            guard let name = string(key, "a key") else {
                continue
            }
            if reserved.contains(name.value) {
                report(.reservedKey, "`\(name.value)` is reserved for a later format version", at: name.location)
            } else if !allowed.contains(name.value) {
                report(.unknownKey, "\(what) has no key `\(name.value)`", at: name.location)
            } else {
                mapping.entries.append((name, value))
            }
        }
        for key in required where mapping[key] == nil {
            report(.missingKey, "\(what) needs `\(key)`", at: mapping.location)
        }
        return mapping
    }

    /// Reads a mapping with arbitrary string keys, like `categories` or `set`.
    mutating func dictionary(_ node: Node, _ what: String) -> [(key: Located<String>, value: Node)]? {
        guard case .mapping(let pairs) = node else {
            report(.wrongType, "\(what) must be a mapping", at: location(of: node))
            return nil
        }
        var entries: [(key: Located<String>, value: Node)] = []
        for (key, value) in pairs {
            if let name = string(key, "a key") {
                entries.append((name, value))
            }
        }
        return entries
    }

    // MARK: Sequences

    /// Reads a sequence, or a single value where the format allows one in place of a list.
    mutating func list<Element>(
        _ node: Node,
        _ what: String,
        allowsSingle: Bool = false,
        allowsEmpty: Bool = false,
        element: (inout DocumentReader, Node) -> Element?
    ) -> [Element]? {
        guard case .sequence(let items) = node else {
            if allowsSingle {
                return element(&self, node).map { [$0] }
            }
            report(.wrongType, "\(what) must be a list", at: location(of: node))
            return nil
        }
        if items.isEmpty, !allowsEmpty {
            report(.invalidValue, "\(what) must not be empty", at: location(of: node))
        }
        return items.compactMap { element(&self, $0) }
    }

    // MARK: Scalars

    private enum ScalarForm {
        case null
        case boolean(Bool)
        case integer(Int)
        case string(String)
    }

    private func form(of scalar: Node.Scalar) -> ScalarForm {
        let text = scalar.string
        guard scalar.style == .plain else {
            return .string(text)
        }
        switch text {
        case "", "~", "null", "Null", "NULL":
            return .null
        case "true", "True", "TRUE":
            return .boolean(true)
        case "false", "False", "FALSE":
            return .boolean(false)
        default:
            if let value = Int(text) {
                return .integer(value)
            }
            return .string(text)
        }
    }

    mutating func string(_ node: Node, _ what: String) -> Located<String>? {
        guard case .scalar(let scalar) = node else {
            report(.wrongType, "\(what) must be a string", at: location(of: node))
            return nil
        }
        switch form(of: scalar) {
        case .null:
            report(.wrongType, "\(what) must be a string, not null; quote it, as in \"~\"", at: location(of: node))
            return nil
        case .boolean:
            report(.wrongType, "\(what) must be a string; quote it", at: location(of: node))
            return nil
        case .integer, .string:
            return Located(scalar.string, at: location(of: node))
        }
    }

    /// A string that must not be empty, like a title.
    mutating func text(_ node: Node, _ what: String) -> Located<String>? {
        guard let text = string(node, what) else {
            return nil
        }
        if text.value.isEmpty {
            report(.invalidValue, "\(what) must not be empty", at: text.location)
            return nil
        }
        return text
    }

    mutating func integer(_ node: Node, _ what: String, in range: ClosedRange<Int>? = nil) -> Located<Int>? {
        guard case .scalar(let scalar) = node, case .integer(let value) = form(of: scalar) else {
            report(.wrongType, "\(what) must be an integer", at: location(of: node))
            return nil
        }
        if let range, !range.contains(value) {
            report(.invalidValue, "\(what) must be between \(range.lowerBound) and \(range.upperBound)", at: location(of: node))
            return nil
        }
        return Located(value, at: location(of: node))
    }

    mutating func boolean(_ node: Node, _ what: String) -> Located<Bool>? {
        guard case .scalar(let scalar) = node, case .boolean(let value) = form(of: scalar) else {
            report(.wrongType, "\(what) must be true or false", at: location(of: node))
            return nil
        }
        return Located(value, at: location(of: node))
    }

    /// Any scalar, for check arguments and expectations.
    mutating func scalarValue(_ node: Node, _ what: String) -> Located<ScalarValue>? {
        guard case .scalar(let scalar) = node else {
            report(.wrongType, "\(what) must be a boolean, integer or string", at: location(of: node))
            return nil
        }
        switch form(of: scalar) {
        case .null:
            report(.wrongType, "\(what) must not be null", at: location(of: node))
            return nil
        case .boolean(let value):
            return Located(.boolean(value), at: location(of: node))
        case .integer(let value):
            return Located(.integer(value), at: location(of: node))
        case .string(let value):
            return Located(.string(value), at: location(of: node))
        }
    }

    mutating func value<Value: RawRepresentable<String>>(
        _ node: Node,
        _ what: String,
        as type: Value.Type,
        expected: String
    ) -> Located<Value>? {
        guard let text = string(node, what) else {
            return nil
        }
        guard let value = Value(rawValue: text.value) else {
            report(.invalidValue, "\(what) must be \(expected), not `\(text.value)`", at: text.location)
            return nil
        }
        return Located(value, at: text.location)
    }

    // MARK: Values

    mutating func glob(_ node: Node, _ what: String, flavor: Glob.Flavor) -> Located<Glob>? {
        guard let text = text(node, what) else {
            return nil
        }
        do {
            return Located(try Glob(text.value, flavor: flavor), at: text.location)
        } catch {
            report(.invalidGlob, "`\(text.value)` is not a valid glob: \(error.message)", at: text.location)
            return nil
        }
    }

    mutating func safety(_ node: Node, _ what: String) -> Located<Safety>? {
        value(node, what, as: Safety.self, expected: "safe, review or dangerous")
    }

    mutating func reportRepeats(_ values: [Located<String>], _ what: String) {
        var seen: Set<String> = []
        for value in values where !seen.insert(value.value).inserted {
            report(.invalidValue, "\(what) lists `\(value.value)` more than once", at: value.location)
        }
    }

    // MARK: Identifiers

    enum IdentifierForm {
        /// `rust`, `node-modules`.
        case id
        /// `rust.target`.
        case qualified
        /// `target` or `node.project`.
        case reference
        /// `project`, `sourceDir`.
        case variable

        var pattern: Regex<Substring> {
            switch self {
            case .id: /[a-z0-9]+(?:-[a-z0-9]+)*/
            case .qualified: /[a-z0-9]+(?:-[a-z0-9]+)*\.[a-z0-9]+(?:-[a-z0-9]+)*/
            case .reference: /(?:[a-z0-9]+(?:-[a-z0-9]+)*\.)?[a-z0-9]+(?:-[a-z0-9]+)*/
            case .variable: /[a-z][A-Za-z0-9]*/
            }
        }

        var expectation: String {
            switch self {
            case .id: "a kebab-case id like `node-modules`"
            case .qualified: "a qualified id like `rust.target`"
            case .reference: "an id like `target` or `node.project`"
            case .variable: "a camelCase name like `sourceDir`"
            }
        }
    }

    mutating func identifier(_ node: Node, _ what: String, form: IdentifierForm) -> Located<String>? {
        string(node, what).flatMap { identifier($0, what, form: form) }
    }

    /// Checks an already-read string, such as a mapping key, against an identifier form.
    mutating func identifier(_ text: Located<String>, _ what: String, form: IdentifierForm) -> Located<String>? {
        guard (try? form.pattern.wholeMatch(in: text.value)) != nil else {
            report(.invalidID, "\(what) must be \(form.expectation), not `\(text.value)`", at: text.location)
            return nil
        }
        return text
    }
}

/// A mapping whose keys have been checked by ``DocumentReader/mapping(_:_:allowed:required:reserved:)``.
struct Mapping {

    let location: SourceLocation
    var entries: [(key: Located<String>, value: Node)] = []

    init(location: SourceLocation) {
        self.location = location
    }

    subscript(key: String) -> Node? {
        entries.first { $0.key.value == key }?.value
    }

    func contains(_ key: String) -> Bool {
        self[key] != nil
    }
}
