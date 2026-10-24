import System

/// Read-only access to a file system, as needed by the scanner.
///
/// The walker learns everything about an entry from its parent's ``listDirectory(at:)``; the other
/// requirements exist for rule checks. No requirement follows a symlink in the final path
/// component, except ``resolvingSymlinks(_:)``, whose job it is.
public protocol FileSystem: Sendable {

    /// Lists the entries of the directory at `path`.
    ///
    /// Entries that could not be read are reported in ``DirectoryListing/failures`` instead of
    /// failing the whole listing.
    func listDirectory(at path: FilePath, options: ListingOptions) throws(FSError) -> DirectoryListing

    /// Whether anything, including a dangling symlink, exists at `path`.
    func exists(at path: FilePath) -> Bool

    /// The identity and kind of what is at `path`. Unlike its path, an item's identity is the
    /// same however a path spells it, through symlinks or firmlinks.
    func identity(at path: FilePath) throws(FSError) -> (identity: FileIdentity, kind: EntryKind)

    /// Reads at most `maxBytes` bytes from the start of the file at `path`.
    func readFile(at path: FilePath, maxBytes: Int) throws(FSError) -> [UInt8]

    /// The absolute path of `path` with every symlink resolved, like realpath(3).
    func resolvingSymlinks(_ path: FilePath) throws(FSError) -> FilePath
}

extension FileSystem {

    /// Lists the entries of the directory at `path` with the attributes every listing has.
    public func listDirectory(at path: FilePath) throws(FSError) -> DirectoryListing {
        try listDirectory(at: path, options: [])
    }
}

/// Attributes a listing reports only when asked, because they cost time.
public struct ListingOptions: OptionSet, Hashable, Sendable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Each file's ``EntryAttributes/sharesBlocks``.
    public static let sharedBlocks = ListingOptions(rawValue: 1 << 0)
}
