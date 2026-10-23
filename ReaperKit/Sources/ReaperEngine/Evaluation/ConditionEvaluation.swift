import Foundation
import ReaperFS
import ReaperRules

/// Values a rule's conditions produced, for its templates.
struct Bindings {

    var captures: [String: String] = [:]
    var facts: Facts = [:]
}

extension CompiledCondition {

    /// Evaluates the conditions against `entry`, cheapest first, and returns what they bound
    /// when all of them hold.
    ///
    /// The entry's kind is not checked: the index only offers rules of the entry's kind.
    func evaluate(_ entry: EntryContext, fileSystem: any FileSystem, now: Date, checks: inout CheckCache) -> Bindings? {
        if !name.isEmpty, !name.contains(where: { $0.matches(entry.name) }) {
            return nil
        }
        if !path.isEmpty, !path.contains(where: { $0.matches(entry.pathString) }) {
            return nil
        }
        if !contains.allSatisfy({ exists($0, in: entry, fileSystem: fileSystem) }) {
            return nil
        }
        if !containsAny.isEmpty, !containsAny.contains(where: { exists($0, in: entry, fileSystem: fileSystem) }) {
            return nil
        }
        if let scope, !scope.holds(in: entry.scopes, at: entry.depth) {
            return nil
        }
        if let olderThan, !(entry.attributes.modified < now - TimeInterval(olderThan.components.seconds)) {
            return nil
        }

        var bindings = Bindings()
        if let capture {
            guard let match = try? capture.regex.firstMatch(in: entry.name) else {
                return nil
            }
            for group in match.output {
                if let name = group.name, let substring = group.substring {
                    bindings.captures[name] = String(substring)
                }
            }
        }
        if let check {
            guard let facts = checks.facts(for: check, entry: entry, fileSystem: fileSystem),
                  check.expectations.allSatisfy({ facts[$0.key] == $0.value }) else {
                return nil
            }
            bindings.facts = facts
        }
        if let sibling {
            let pattern = sibling.render(for: entry, bindings: bindings)
            guard let glob = try? Glob(pattern, flavor: .name),
                  entry.siblings.entries.contains(where: { glob.matches($0.name) }) else {
                return nil
            }
        }
        return bindings
    }

    private func exists(_ pattern: ChildPattern, in entry: EntryContext, fileSystem: any FileSystem) -> Bool {
        guard let children = entry.children else {
            return false
        }
        switch pattern {
        case .name(let glob):
            if case .literal(let name) = glob.shape {
                return children.contains(name)
            }
            return children.entries.contains { glob.matches($0.name) }
        case .path(let relativePath):
            return fileSystem.exists(at: entry.path.appending(relativePath))
        }
    }
}

extension CompiledScopeTest {

    func holds(in scopes: ScopeStack, at depth: Int) -> Bool {
        guard let instance = scopes.innermost(scope) else {
            return false
        }
        let distance = depth - instance.depth
        switch self.distance {
        case .any: return true
        case .exactly(let expected): return distance == expected
        case .atMost(let limit): return distance <= limit
        }
    }
}

extension CompiledTemplate {

    func render(for entry: EntryContext, bindings: Bindings) -> String {
        render { segment in
            switch segment {
            case .literal(let text): text
            case .name: entry.name
            case .path: entry.pathString
            case .parent: entry.parentPath
            case .capture(let group): bindings.captures[group] ?? ""
            case .fact(let fact): bindings.facts[fact]?.text ?? ""
            case .scopeRoot(let scope): entry.scopes.innermost(scope)?.root.string ?? ""
            case .scopeVariable(let scope, let variable): entry.scopes.innermost(scope)?.variables[variable] ?? ""
            }
        }
    }
}

extension ScalarValue {

    /// How a fact reads inside a template.
    var text: String {
        switch self {
        case .boolean(let value): String(value)
        case .integer(let value): String(value)
        case .string(let value): value
        }
    }
}
