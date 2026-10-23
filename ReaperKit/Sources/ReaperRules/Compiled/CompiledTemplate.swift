/// A template whose variables are resolved to what they read at scan time.
public struct CompiledTemplate: Hashable, Sendable {

    public enum Segment: Hashable, Sendable {
        case literal(String)
        /// The entry's name.
        case name
        /// The entry's absolute path.
        case path
        /// The path of the entry's parent.
        case parent
        /// A named group from the rule's `capture`.
        case capture(String)
        /// A fact returned by the rule's check.
        case fact(String)
        /// The path of the entry that pushed the scope.
        case scopeRoot(ScopeID)
        /// A variable the scope set.
        case scopeVariable(ScopeID, String)
    }

    public let segments: [Segment]

    /// Joins the segments, asking `resolve` for the value of every segment that is not literal.
    public func render(_ resolve: (Segment) -> String) -> String {
        segments.map { segment in
            if case .literal(let text) = segment { text } else { resolve(segment) }
        }.joined()
    }
}

// MARK: - Compiling

extension CompiledTemplate {

    /// Compiles a template that validation accepted, so it parses and every variable resolves.
    init(_ text: String, in ruleSet: RuleSet, interner: Interner) {
        let template = try! Template(text)
        self.init(segments: template.segments.map { segment in
            switch segment {
            case .literal(let text):
                .literal(text)
            case .variable(let variable):
                Self.segment(for: variable, in: ruleSet, interner: interner)
            }
        })
    }

    private static func segment(for variable: String, in ruleSet: RuleSet, interner: Interner) -> Segment {
        switch variable {
        case "name":
            return .name
        case "path":
            return .path
        case "parent":
            return .parent
        default:
            break
        }
        let parts = variable.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "check" {
            return .fact(parts[1])
        }
        if parts.count == 3 || parts.count == 4, parts[0] == "scope" {
            let scope = interner.scope(parts.dropFirst().dropLast().joined(separator: "."), in: ruleSet)
            return parts.last == "root" ? .scopeRoot(scope) : .scopeVariable(scope, parts.last!)
        }
        return .capture(variable)
    }
}
