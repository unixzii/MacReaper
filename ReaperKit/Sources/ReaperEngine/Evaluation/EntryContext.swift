import ReaperFS
import System

/// One file-system entry, as the evaluator sees it: its attributes from its parent's listing,
/// its own listing if it is a directory, and the scopes it inherits.
public struct EntryContext: Sendable {

    public let path: FilePath
    public let attributes: EntryAttributes
    /// Distance from the scan root, which has depth 0.
    public let depth: Int
    /// The entry's own listing; `nil` for files.
    public let children: DirectoryListing?
    /// The listing of the entry's parent, which includes the entry itself.
    public let siblings: DirectoryListing
    public let scopes: ScopeStack
    /// `path` as a string, computed once because globs and templates use it repeatedly.
    public let pathString: String

    public init(
        path: FilePath,
        attributes: EntryAttributes,
        depth: Int,
        children: DirectoryListing?,
        siblings: DirectoryListing,
        scopes: ScopeStack
    ) {
        self.path = path
        self.attributes = attributes
        self.depth = depth
        self.children = children
        self.siblings = siblings
        self.scopes = scopes
        self.pathString = path.string
    }

    public var name: String {
        attributes.name
    }

    public var parentPath: String {
        path.removingLastComponent().string
    }
}
