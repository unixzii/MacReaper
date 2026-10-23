import Yams

/// A `check` condition: a call to one of the engine's built-in checks.
public struct CheckCall: Sendable {

    public var name: Located<String>
    public var arguments: [Field]
    public var expectations: [Field]
}

/// A key and scalar value from a `check`'s `args` or `expect`.
public struct Field: Sendable {

    public var key: Located<String>
    public var value: Located<ScalarValue>
}

public enum ScalarValue: Hashable, Sendable {
    case boolean(Bool)
    case integer(Int)
    case string(String)

    public var type: ScalarType {
        switch self {
        case .boolean: .boolean
        case .integer: .integer
        case .string: .string
        }
    }
}

public enum ScalarType: String, Hashable, Sendable {
    case boolean
    case integer
    case string
}

/// What the loader needs to know about a built-in check to validate calls to it. The engine
/// supplies the implementations.
public struct CheckSpec: Sendable {

    public struct Argument: Sendable {

        public var name: String
        public var type: ScalarType
        public var isRequired: Bool
    }

    public enum ArgumentProblem: Sendable {
        case invalidRegex(argument: String, message: String)
        case invalid(argument: String, message: String)
    }

    public var name: String
    public var arguments: [Argument]
    public var facts: [String: ScalarType]
    /// Checks argument values beyond their types. Called only when all arguments have the right
    /// type and the required ones are present.
    var validate: @Sendable ([String: ScalarValue]) -> ArgumentProblem? = { _ in nil }

    public static let builtins: [String: CheckSpec] = Dictionary(
        uniqueKeysWithValues: [
            CheckSpec(name: "cachedir.signature", arguments: [], facts: [:]),
            CheckSpec(
                name: "cmake.cache",
                arguments: [],
                facts: [
                    "valid": .boolean,
                    "inSource": .boolean,
                    "sourceDir": .string,
                    "sourceExists": .boolean,
                    "project": .string,
                ]
            ),
            CheckSpec(
                name: "xcode.derived-data",
                arguments: [],
                facts: ["workspacePath": .string, "workspaceExists": .boolean]
            ),
            CheckSpec(
                name: "version.superseded",
                arguments: [Argument(name: "pattern", type: .string, isRequired: true)],
                facts: ["supersededBy": .string],
                validate: validateVersionPattern
            ),
        ].map { ($0.name, $0) }
    )

    private static func validateVersionPattern(_ arguments: [String: ScalarValue]) -> ArgumentProblem? {
        guard case .string(let pattern) = arguments["pattern"] else {
            return nil
        }
        switch RegexSyntax.groupNames(in: pattern) {
        case .failure(let error):
            return .invalidRegex(argument: "pattern", message: error.message)
        case .success(let names) where !names.isSuperset(of: ["group", "version"]):
            return .invalid(argument: "pattern", message: "the pattern needs named groups `group` and `version`")
        case .success:
            return nil
        }
    }
}

// MARK: - Reading

extension CheckCall {

    init?(_ node: Node, reader: inout DocumentReader) {
        if case .scalar = node {
            guard let name = reader.text(node, "the check") else {
                return nil
            }
            self.init(name: name, arguments: [], expectations: [])
            return
        }
        guard let fields = reader.mapping(node, "`check`", allowed: ["name", "args", "expect"], required: ["name"]) else {
            return nil
        }
        let name = fields["name"].flatMap { reader.text($0, "the check") }
        let arguments = fields["args"].flatMap { Self.fields($0, "`args`", reader: &reader) } ?? []
        let expectations = fields["expect"].flatMap { Self.fields($0, "`expect`", reader: &reader) } ?? []
        guard let name else {
            return nil
        }
        self.init(name: name, arguments: arguments, expectations: expectations)
    }

    private static func fields(_ node: Node, _ what: String, reader: inout DocumentReader) -> [Field]? {
        reader.dictionary(node, what)?.compactMap { key, value in
            reader.scalarValue(value, "`\(key.value)`").map { Field(key: key, value: $0) }
        }
    }
}

// MARK: - Validation

extension CheckCall {

    /// Validates the call against its check and returns the variables the check's facts provide.
    func validate(ruleID: String, context: inout ValidationContext) -> Set<String> {
        guard let spec = CheckSpec.builtins[name.value] else {
            context.report(.unknownCheck, "there is no check `\(name.value)`", at: name.location, ruleID: ruleID)
            return []
        }
        validateArguments(against: spec, ruleID: ruleID, context: &context)
        validateExpectations(against: spec, ruleID: ruleID, context: &context)
        return Set(spec.facts.keys.map { "check.\($0)" })
    }

    private func validateArguments(against spec: CheckSpec, ruleID: String, context: inout ValidationContext) {
        var values: [String: ScalarValue] = [:]
        var isWellTyped = true
        for field in arguments {
            guard let argument = spec.arguments.first(where: { $0.name == field.key.value }) else {
                context.report(
                    .unknownCheckArgument,
                    "\(spec.name) takes no argument `\(field.key.value)`",
                    at: field.key.location,
                    ruleID: ruleID
                )
                isWellTyped = false
                continue
            }
            guard field.value.value.type == argument.type else {
                context.report(
                    .invalidCheckArgument,
                    "`\(argument.name)` must be a \(argument.type.rawValue)",
                    at: field.value.location,
                    ruleID: ruleID
                )
                isWellTyped = false
                continue
            }
            values[argument.name] = field.value.value
        }
        for argument in spec.arguments where argument.isRequired && values[argument.name] == nil {
            if !arguments.contains(where: { $0.key.value == argument.name }) {
                context.report(
                    .missingCheckArgument,
                    "\(spec.name) needs the argument `\(argument.name)`",
                    at: name.location,
                    ruleID: ruleID
                )
            }
            isWellTyped = false
        }

        guard isWellTyped, let problem = spec.validate(values) else {
            return
        }
        switch problem {
        case .invalidRegex(let argument, let message):
            context.report(.invalidRegex, "`\(argument)` does not compile: \(message)", at: location(of: argument), ruleID: ruleID)
        case .invalid(let argument, let message):
            context.report(.invalidCheckArgument, message, at: location(of: argument), ruleID: ruleID)
        }
    }

    private func validateExpectations(against spec: CheckSpec, ruleID: String, context: inout ValidationContext) {
        for field in expectations {
            guard let type = spec.facts[field.key.value] else {
                context.report(
                    .unknownFact,
                    "\(spec.name) returns no fact `\(field.key.value)`",
                    at: field.key.location,
                    ruleID: ruleID
                )
                continue
            }
            if field.value.value.type != type {
                context.report(
                    .factTypeMismatch,
                    "the fact `\(field.key.value)` is a \(type.rawValue)",
                    at: field.value.location,
                    ruleID: ruleID
                )
            }
        }
    }

    private func location(of argument: String) -> SourceLocation {
        arguments.first { $0.key.value == argument }?.value.location ?? name.location
    }
}
