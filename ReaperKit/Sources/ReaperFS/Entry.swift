import Darwin
import Foundation

public enum EntryKind: Hashable, Sendable {
    case directory
    case file
    case symlink
    /// FIFOs, sockets and device nodes.
    case other
}

/// Identifies a file-system object independently of its path.
public struct FileIdentity: Hashable, Sendable {

    public var device: Int32
    public var fileID: UInt64

    public init(device: Int32, fileID: UInt64) {
        self.device = device
        self.fileID = fileID
    }
}

/// What a directory listing reports about one entry.
public struct EntryAttributes: Hashable, Sendable {

    public var name: String
    public var kind: EntryKind
    public var identity: FileIdentity
    public var modified: Date
    /// BSD flags, as in `st_flags`.
    public var flags: UInt32
    /// Number of hard links. Only meaningful for files; 1 for everything else.
    public var linkCount: UInt32
    /// Bytes allocated on disk. Only meaningful for files; 0 for everything else.
    public var allocatedSize: UInt64
    /// Bytes that deleting the file would free right away: the part not shared with clones or
    /// snapshots. Only for files, only when requested with ``ListingOptions/privateSize``, and
    /// only on file systems that report it.
    public var privateSize: UInt64?

    public init(
        name: String,
        kind: EntryKind,
        identity: FileIdentity,
        modified: Date,
        flags: UInt32 = 0,
        linkCount: UInt32 = 1,
        allocatedSize: UInt64 = 0,
        privateSize: UInt64? = nil
    ) {
        self.name = name
        self.kind = kind
        self.identity = identity
        self.modified = modified
        self.flags = flags
        self.linkCount = linkCount
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
    }

    /// Whether this is an iCloud or File Provider placeholder whose contents are not on disk.
    public var isDataless: Bool {
        flags & UInt32(SF_DATALESS) != 0
    }
}

/// An entry that appeared in a listing but whose attributes could not be read.
public struct EntryFailure: Hashable, Sendable {

    public var name: String
    public var error: FSError

    public init(name: String, error: FSError) {
        self.name = name
        self.error = error
    }
}

/// The entries of one directory, in the order the file system returned them.
public struct DirectoryListing: Sendable {

    public let entries: [EntryAttributes]
    public let failures: [EntryFailure]
    private let names: Set<String>

    public init(entries: [EntryAttributes], failures: [EntryFailure] = []) {
        self.entries = entries
        self.failures = failures
        self.names = Set(entries.lazy.map(\.name))
    }

    public func contains(_ name: String) -> Bool {
        names.contains(name)
    }
}
