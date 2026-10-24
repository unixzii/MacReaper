/// A position in a rule file. Lines and columns start at 1.
public struct SourceLocation: Hashable, Comparable, Sendable, CustomStringConvertible {

    public var file: String
    public var line: Int
    public var column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        (lhs.file, lhs.line, lhs.column) < (rhs.file, rhs.line, rhs.column)
    }

    public var description: String {
        "\(file):\(line):\(column)"
    }
}

/// A value read from a rule file, together with where it was written.
public struct Located<Value> {

    public var value: Value
    public var location: SourceLocation

    public init(_ value: Value, at location: SourceLocation) {
        self.value = value
        self.location = location
    }
}

extension Located: Sendable where Value: Sendable {}
extension Located: Equatable where Value: Equatable {}
extension Located: Hashable where Value: Hashable {}

/// What went wrong, as a stable identifier. The raw values are the codes used by the shared
/// conformance corpus in `Rules/conformance`.
public enum DiagnosticCode: String, Hashable, Sendable, CaseIterable {
    // Syntax and structure, as the JSON Schemas describe it.
    case yamlSyntax = "yaml-syntax"
    case unsupportedFormat = "unsupported-format"
    case unknownKey = "unknown-key"
    case reservedKey = "reserved-key"
    case missingKey = "missing-key"
    case duplicateKey = "duplicate-key"
    case wrongType = "wrong-type"
    case invalidID = "invalid-id"
    case invalidValue = "invalid-value"
    case invalidGlob = "invalid-glob"
    case invalidDuration = "invalid-duration"
    case conflictingDistance = "conflicting-distance"
    case actionNotSingle = "action-not-single"
    case notIndexable = "not-indexable"
    case fileRuleNeedsNameOrPath = "file-rule-needs-name-or-path"
    case fileNameMismatch = "file-name-mismatch"

    // Identifiers.
    case duplicateID = "duplicate-id"
    case missingRuleSetPrefix = "missing-rule-set-prefix"

    // References.
    case unknownCategory = "unknown-category"
    case unknownScope = "unknown-scope"

    // Checks.
    case unknownCheck = "unknown-check"
    case unknownCheckArgument = "unknown-check-argument"
    case missingCheckArgument = "missing-check-argument"
    case invalidCheckArgument = "invalid-check-argument"
    case unknownFact = "unknown-fact"
    case factTypeMismatch = "fact-type-mismatch"

    // Regular expressions and templates.
    case invalidRegex = "invalid-regex"
    case malformedTemplate = "malformed-template"
    case unavailableVariable = "unavailable-variable"

    // Indexability.
    case globWithoutLiteral = "glob-without-literal"
}

/// One problem found while loading rules.
public struct RuleDiagnostic: Hashable, Sendable, CustomStringConvertible {

    public var code: DiagnosticCode
    public var message: String
    public var location: SourceLocation
    /// The id of the rule the problem is in, if it is in a rule.
    public var ruleID: String?

    public init(code: DiagnosticCode, message: String, location: SourceLocation, ruleID: String? = nil) {
        self.code = code
        self.message = message
        self.location = location
        self.ruleID = ruleID
    }

    public var description: String {
        let rule = ruleID.map { "\($0): " } ?? ""
        return "\(location): \(rule)\(message) [\(code.rawValue)]"
    }
}

/// Every problem found while loading rule sets.
public struct RuleDiagnostics: Error, Sendable, CustomStringConvertible {

    /// Sorted by location.
    public var diagnostics: [RuleDiagnostic]

    public init(_ diagnostics: [RuleDiagnostic]) {
        self.diagnostics = diagnostics.sorted { $0.location < $1.location }
    }

    public var description: String {
        diagnostics.map(\.description).joined(separator: "\n")
    }
}
