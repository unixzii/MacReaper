import Foundation
import ReaperFS
import ReaperRules
import System

/// What evaluating one entry decided.
public enum EntryOutcome: Sendable {
    /// A rule skips the entry: it is neither claimed nor descended into.
    case skip(by: [RuleID])
    /// The entry is a cleanup candidate, and nothing inside it is visited.
    case claim(Claim)
    /// Neither: a directory's children are visited with these scopes, which include any the
    /// entry pushed. For files the scopes are irrelevant.
    case descend(ScopeStack)
}

/// An entry claimed as a cleanup candidate.
public struct Claim: Sendable {

    public let path: FilePath
    /// The entry's identity and modification date at scan time, so cleanup can make sure it
    /// still deletes the same thing.
    public let identity: FileIdentity
    public let modified: Date
    /// In id order.
    public let categories: [CategoryID]
    /// The strictest safety of the categories.
    public let safety: Safety
    public let isPreselected: Bool
    /// The rules that claimed the entry, in id order.
    public let rules: [RuleID]
    /// The claims' `set` variables, merged.
    public let variables: [String: String]
    /// The project the candidate belongs to, for grouping: the claim's `project` variable, or
    /// else the nearest scope's.
    public let group: String?
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
        var held: [HeldRule] = []
        for id in candidates {
            let rule = rules[id]
            if let bindings = rule.condition.evaluate(entry, fileSystem: fileSystem, now: now, checks: &checks) {
                held.append(HeldRule(rule: rule, bindings: bindings))
            }
        }

        // Skips win over everything else on the entry.
        let skips = held.filter { if case .skip = $0.rule.action { true } else { false } }
        if !skips.isEmpty {
            return .skip(by: skips.map(\.rule.id))
        }
        if let claim = claim(entry, from: held) {
            return .claim(claim)
        }
        return .descend(entry.scopes.pushing(scopes(entry, from: held)))
    }

    /// A rule whose conditions hold for the entry, with what they bound.
    private struct HeldRule {

        let rule: CompiledRule
        let bindings: Bindings
    }

    private struct HeldClaim {

        let rule: CompiledRule
        let category: CategoryID
        let assignments: [CompiledAssignment]
        let isFallback: Bool
        let bindings: Bindings
    }

    // MARK: Claims

    /// Merges the claims that hold into one candidate. Fallback claims count only when no other
    /// claim holds. `held` is in rule id order, so where variables conflict the first rule wins.
    private func claim(_ entry: EntryContext, from held: [HeldRule]) -> Claim? {
        let claims = held.compactMap { held -> HeldClaim? in
            guard case .claim(let category, let assignments, let isFallback) = held.rule.action else {
                return nil
            }
            return HeldClaim(
                rule: held.rule,
                category: category,
                assignments: assignments,
                isFallback: isFallback,
                bindings: held.bindings
            )
        }
        let deciding = claims.contains { !$0.isFallback } ? claims.filter { !$0.isFallback } : claims
        guard !deciding.isEmpty else {
            return nil
        }

        let categories = Set(deciding.map(\.category)).sorted()
        let safety = categories.map { rules[$0].safety }.max()!
        var variables: [String: String] = [:]
        for claim in deciding {
            for assignment in claim.assignments where variables[assignment.variable] == nil {
                variables[assignment.variable] = assignment.template.render(for: entry, bindings: claim.bindings)
            }
        }
        return Claim(
            path: entry.path,
            identity: entry.attributes.identity,
            modified: entry.attributes.modified,
            categories: categories,
            safety: safety,
            isPreselected: rules.preselect.contains(safety),
            rules: deciding.map(\.rule.id),
            variables: variables,
            group: variables["project"] ?? entry.scopes.nearest(setting: "project")?.variables["project"],
            provenance: entry.scopes.instances
        )
    }

    // MARK: Scopes

    /// One instance per scope pushed at the entry. When several rules push the same scope,
    /// their variables merge, and where they conflict the rule with the lowest id wins.
    private func scopes(_ entry: EntryContext, from held: [HeldRule]) -> [ScopeInstance] {
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
