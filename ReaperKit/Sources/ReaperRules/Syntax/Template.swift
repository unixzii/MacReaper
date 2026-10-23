/// A parsed template: literal text with `{variable}` references. `{{` and `}}` stand for
/// literal braces.
public struct Template: Hashable, Sendable {

    public enum Segment: Hashable, Sendable {
        case literal(String)
        case variable(String)
    }

    public let segments: [Segment]

    public init(_ text: String) throws(TemplateSyntaxError) {
        var segments: [Segment] = []
        var literal = ""
        var characters = text[...]
        while let character = characters.popFirst() {
            switch character {
            case "{" where characters.first == "{":
                characters.removeFirst()
                literal.append("{")
            case "}" where characters.first == "}":
                characters.removeFirst()
                literal.append("}")
            case "{":
                guard let end = characters.firstIndex(of: "}") else {
                    throw TemplateSyntaxError("a { has no closing }")
                }
                let name = characters[..<end]
                guard !name.isEmpty, !name.contains("{") else {
                    throw TemplateSyntaxError("{\(name)} is not a variable reference")
                }
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal = ""
                }
                segments.append(.variable(String(name)))
                characters = characters[characters.index(after: end)...]
            case "}":
                throw TemplateSyntaxError("a } has no opening {; write }} for a literal brace")
            default:
                literal.append(character)
            }
        }
        if !literal.isEmpty {
            segments.append(.literal(literal))
        }
        self.segments = segments
    }

    public var variables: [String] {
        segments.compactMap { segment in
            if case .variable(let name) = segment { name } else { nil }
        }
    }
}

public struct TemplateSyntaxError: Error, Sendable {

    public var message: String

    init(_ message: String) {
        self.message = message
    }
}
