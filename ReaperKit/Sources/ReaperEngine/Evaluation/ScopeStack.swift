import ReaperRules
import System

/// A scope started at one entry, visible to the entry's descendants.
public struct ScopeInstance: Sendable {

    public let scope: ScopeID
    /// The entry that pushed the scope.
    public let root: FilePath
    public let depth: Int
    public let variables: [String: String]
    /// The rules that pushed the scope at this entry, in id order.
    public let rules: [RuleID]
}

/// The scopes an entry inherits from its ancestors.
///
/// The stack is immutable and shares structure: pushing returns a new stack that points at the
/// old one, so all children of a directory share its stack, and handing a stack to another
/// thread copies nothing.
public struct ScopeStack: Sendable {

    private final class Node: Sendable {

        let instance: ScopeInstance
        let parent: Node?

        init(_ instance: ScopeInstance, parent: Node?) {
            self.instance = instance
            self.parent = parent
        }
    }

    private let top: Node?

    public static let empty = ScopeStack(top: nil)

    private init(top: Node?) {
        self.top = top
    }

    public func pushing(_ instances: [ScopeInstance]) -> ScopeStack {
        ScopeStack(top: instances.reduce(top) { Node($1, parent: $0) })
    }

    /// The instance of `scope` pushed by the deepest ancestor, if any.
    public func innermost(_ scope: ScopeID) -> ScopeInstance? {
        var node = top
        while let current = node {
            if current.instance.scope == scope {
                return current.instance
            }
            node = current.parent
        }
        return nil
    }

    /// Every instance, outermost first.
    public var instances: [ScopeInstance] {
        var instances: [ScopeInstance] = []
        var node = top
        while let current = node {
            instances.append(current.instance)
            node = current.parent
        }
        return instances.reversed()
    }
}
