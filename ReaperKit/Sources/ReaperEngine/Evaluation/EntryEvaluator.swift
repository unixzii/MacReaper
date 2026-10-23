import Foundation
import ReaperFS
import ReaperRules
import System

/// What evaluating one entry decided.
public enum EntryOutcome: Sendable {
    /// A rule skips the entry: it is neither claimed nor descended into.
    case skip(by: RuleID)
    /// The entry is a cleanup candidate, and nothing inside it is visited.
    case claim(Claim)
    /// Neither: a directory's children are visited with these scopes, which include any the
    /// entry pushed. For files the scopes are irrelevant.
    case descend(ScopeStack)
}

/// An entry claimed as a cleanup candidate, by one rule.
public struct Claim: Sendable {

    public let path: FilePath
    /// The entry's identity and modification date at scan time, so cleanup can make sure it
    /// still deletes the same thing.
    public let identity: FileIdentity
    public let modified: Date
    /// The rule that claimed the entry.
    public let rule: RuleID
    public let category: CategoryID
    /// The category's safety, after profile overrides.
    public let safety: Safety
    public let isPreselected: Bool
    /// The rule's `set` variables.
    public let variables: [String: String]
    /// Every scope the entry inherited, outermost first.
    public let provenance: [ScopeInstance]
    /// Filled in by the scan's sizing phase; `nil` when the scan does not size candidates.
    public internal(set) var size: CandidateSize?
}

/// Evaluates the rules of a compiled profile against one entry at a time.
///
/// Evaluation reads the file system (for checks and nested `contains` paths) but never changes
/// it, and depends only on the entry it is given, so entries may be evaluated in any order and
/// on any thread.
public struct EntryEvaluator: Sendable {

    public let rules: CompiledRules
    public let fileSystem: any FileSystem
    /// The time `olderThan` conditions measure from.
    public let now: Date

    public init(rules: CompiledRules, fileSystem: any FileSystem, now: Date) {
        self.rules = rules
        self.fileSystem = fileSystem
        self.now = now
    }

    /// Tries the rules that could hold in ``CompiledRules/inEvaluationOrder(_:)``: the first
    /// skip or claim that holds decides, and no later rule is tried. Otherwise every scope push
    /// that holds applies.
    public func evaluate(_ entry: EntryContext) -> EntryOutcome {
        // Looked up in place: copying an index retains every table in it.
        let candidates: RuleSelection
        switch entry.attributes.kind {
        case .directory:
            candidates = rules.directoryIndex.candidates(
                name: entry.name,
                path: entry.pathString,
                children: (entry.children?.entries ?? []).lazy.map(\.name)
            )
        case .file:
            candidates = rules.fileIndex.candidates(name: entry.name, path: entry.pathString, children: EmptyCollection())
        case .symlink, .other:
            return .descend(entry.scopes)
        }
        var checks = CheckCache()
        var pushes: [(rule: CompiledRule, bindings: Bindings)] = []
        for id in rules.inEvaluationOrder(candidates) {
            let rule = rules[id]
            guard let bindings = rule.condition.evaluate(entry, fileSystem: fileSystem, now: now, checks: &checks) else {
                continue
            }
            switch rule.action {
            case .skip:
                return .skip(by: id)
            case .claim(let category, let assignments, _):
                return .claim(claim(entry, by: rule, category: category, assignments: assignments, bindings: bindings))
            case .pushScope:
                pushes.append((rule, bindings))
            }
        }
        return .descend(entry.scopes.pushing(scopes(entry, from: pushes)))
    }

    // MARK: Claims

    private func claim(
        _ entry: EntryContext,
        by rule: CompiledRule,
        category: CategoryID,
        assignments: [CompiledAssignment],
        bindings: Bindings
    ) -> Claim {
        var variables: [String: String] = [:]
        for assignment in assignments {
            variables[assignment.variable] = assignment.template.render(for: entry, bindings: bindings)
        }
        let safety = rules[category].safety
        return Claim(
            path: entry.path,
            identity: entry.attributes.identity,
            modified: entry.attributes.modified,
            rule: rule.id,
            category: category,
            safety: safety,
            isPreselected: rules.preselect.contains(safety),
            variables: variables,
            provenance: entry.scopes.instances
        )
    }

    // MARK: Scopes

    /// One instance per scope pushed at the entry. When several rules push the same scope,
    /// their variables merge, and where they conflict the rule with the lowest id wins.
    private func scopes(_ entry: EntryContext, from held: [(rule: CompiledRule, bindings: Bindings)]) -> [ScopeInstance] {
        var pushes: [ScopeID: (variables: [String: String], rules: [RuleID])] = [:]
        for held in held {
            guard case .pushScope(let scope, let assignments) = held.rule.action else {
                continue
            }
            var push = pushes[scope] ?? ([:], [])
            push.rules.append(held.rule.id)
            for assignment in assignments where push.variables[assignment.variable] == nil {
                push.variables[assignment.variable] = assignment.template.render(for: entry, bindings: held.bindings)
            }
            pushes[scope] = push
        }
        return pushes.keys.sorted().map { scope in
            ScopeInstance(
                scope: scope,
                root: entry.path,
                depth: entry.depth,
                variables: pushes[scope]!.variables,
                rules: pushes[scope]!.rules
            )
        }
    }
}
