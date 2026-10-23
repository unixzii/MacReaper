/// What cross-document validation knows about everything a profile loads: the categories and
/// scopes the rule sets declare, the rule ids seen so far, and the problems found.
///
/// Document types validate themselves with a `validate` method that takes this context. It only
/// runs on documents that ``DocumentReader`` read without problems, so it can trust their
/// structure.
struct ValidationContext {

    enum ReferenceKind {
        case category
        case scope
    }

    /// Categories by qualified id.
    let categories: [String: Category]
    /// Scopes by qualified name, with the variables that every rule pushing the scope sets.
    let scopeVariables: [String: Set<String>]
    /// Rule ids validated so far, to find duplicates across rule sets.
    var ruleIDs: Set<String> = []
    private(set) var diagnostics: [RuleDiagnostic] = []

    init(ruleSets: [RuleSet]) {
        var categories: [String: Category] = [:]
        var scopeVariables: [String: Set<String>] = [:]
        for ruleSet in ruleSets {
            for category in ruleSet.categories {
                categories["\(ruleSet.id.value).\(category.id.value)"] = category
            }
            for rule in ruleSet.rules {
                guard case .pushScope(let name, let assignments) = rule.action else {
                    continue
                }
                let variables = Set(assignments.map(\.variable.value))
                scopeVariables["\(ruleSet.id.value).\(name.value)", default: variables].formIntersection(variables)
            }
        }
        self.categories = categories
        self.scopeVariables = scopeVariables
    }

    mutating func report(_ code: DiagnosticCode, _ message: String, at location: SourceLocation, ruleID: String? = nil) {
        diagnostics.append(RuleDiagnostic(code: code, message: message, location: location, ruleID: ruleID))
    }

    // MARK: References

    /// The qualified form of a bare or qualified reference written in `ruleSet`.
    func qualifiedName(_ reference: String, in ruleSet: RuleSet) -> String {
        reference.contains(".") ? reference : "\(ruleSet.id.value).\(reference)"
    }

    /// Resolves a reference written in `ruleSet`, reporting a reference to another rule set that
    /// is not in `requires`, or to something nobody declares.
    mutating func resolve(
        _ reference: Located<String>,
        in ruleSet: RuleSet,
        as kind: ReferenceKind,
        ruleID: String
    ) -> String? {
        let qualified = qualifiedName(reference.value, in: ruleSet)
        let owner = String(qualified.prefix { $0 != "." })
        if owner != ruleSet.id.value, !ruleSet.requires.contains(where: { $0.value == owner }) {
            report(
                .missingRequires,
                "`\(reference.value)` belongs to rule set `\(owner)`, which `\(ruleSet.id.value)` does not list in requires",
                at: reference.location,
                ruleID: ruleID
            )
            return nil
        }
        switch kind {
        case .category where categories[qualified] == nil:
            report(.unknownCategory, "no rule set declares the category `\(qualified)`", at: reference.location, ruleID: ruleID)
            return nil
        case .scope where scopeVariables[qualified] == nil:
            report(.unknownScope, "no rule pushes the scope `\(qualified)`", at: reference.location, ruleID: ruleID)
            return nil
        default:
            return qualified
        }
    }

    // MARK: Templates

    /// Checks that a template parses and that every variable it uses is available.
    mutating func validateTemplate(
        _ text: Located<String>,
        variables: AvailableVariables,
        in ruleSet: RuleSet,
        ruleID: String
    ) {
        let template: Template
        do {
            template = try Template(text.value)
        } catch {
            report(.malformedTemplate, "`\(text.value)` is malformed: \(error.message)", at: text.location, ruleID: ruleID)
            return
        }
        for variable in template.variables where !isAvailable(variable, variables, in: ruleSet) {
            report(.unavailableVariable, "{\(variable)} is not available in this rule", at: text.location, ruleID: ruleID)
        }
    }

    /// Scope variables need a `scope` condition naming that scope, and every rule pushing it must
    /// set the variable. `root` is always set.
    private func isAvailable(_ variable: String, _ variables: AvailableVariables, in ruleSet: RuleSet) -> Bool {
        if variables.names.contains(variable) {
            return true
        }
        let parts = variable.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let scope = variables.scope, parts.first == "scope", parts.count == 3 || parts.count == 4 else {
            return false
        }
        let reference = parts.dropFirst().dropLast().joined(separator: ".")
        guard qualifiedName(reference, in: ruleSet) == scope else {
            return false
        }
        return parts.last == "root" || scopeVariables[scope, default: []].contains(parts.last!)
    }
}

/// The variables a rule's templates may use.
struct AvailableVariables {

    var names: Set<String> = ["name", "path", "parent"]
    /// The qualified scope the rule tests, whose root and variables are available too.
    var scope: String?
}
