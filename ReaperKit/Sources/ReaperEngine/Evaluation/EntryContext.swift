import ReaperFS
import System

/// One file-system entry, as the evaluator sees it: its attributes from its parent's listing,
/// its own listing if it is a directory, and the scopes it inherits.
public struct EntryContext: Sendable {

    /// The absolute path. Kept as a string, which globs and templates use, because most entries
    /// never need a `FilePath`.
    public let pathString: String
    public let attributes: EntryAttributes
    /// Distance from the scan root, which has depth 0.
    public let depth: Int
    /// The entry's own listing; `nil` for files.
    public let children: DirectoryListing?
    /// The listing of the entry's parent, which includes the entry itself.
    public let siblings: DirectoryListing
    public let scopes: ScopeStack

    public init(
        path: FilePath,
        attributes: EntryAttributes,
        depth: Int,
        children: DirectoryListing?,
        siblings: DirectoryListing,
        scopes: ScopeStack
    ) {
        self.init(
            pathString: path.string,
            attributes: attributes,
            depth: depth,
            children: children,
            siblings: siblings,
            scopes: scopes
        )
    }

    init(
        pathString: String,
        attributes: EntryAttributes,
        depth: Int,
        children: DirectoryListing?,
        siblings: DirectoryListing,
        scopes: ScopeStack
    ) {
        self.pathString = pathString
        self.attributes = attributes
        self.depth = depth
        self.children = children
        self.siblings = siblings
        self.scopes = scopes
    }

    public var path: FilePath {
        FilePath(pathString)
    }

    public var name: String {
        attributes.name
    }

    public var parentPath: String {
        path.removingLastComponent().string
    }
}
