import Foundation
import ReaperFS
import ReaperFSTesting
import Synchronization
import System

/// Wraps a file system, counting listings and making each one slow.
struct SlowFileSystem: FileSystem {

    private final class Counter: Sendable {

        let value = Atomic(0)
    }

    let base: InMemoryFileSystem
    let delay: Duration
    /// Called as each listing starts, with the number of listings so far and the directory.
    var onListing: @Sendable (Int, FilePath) -> Void = { _, _ in }
    private let counter = Counter()

    var listings: Int {
        counter.value.load(ordering: .relaxed)
    }

    func listDirectory(at path: FilePath, options: ListingOptions) throws(FSError) -> DirectoryListing {
        onListing(counter.value.add(1, ordering: .relaxed).newValue, path)
        Thread.sleep(forTimeInterval: Double(delay.components.attoseconds) / 1e18)
        return try base.listDirectory(at: path, options: options)
    }

    func exists(at path: FilePath) -> Bool {
        base.exists(at: path)
    }

    func identity(at path: FilePath) throws(FSError) -> (identity: FileIdentity, kind: EntryKind) {
        try base.identity(at: path)
    }

    func readFile(at path: FilePath, maxBytes: Int) throws(FSError) -> [UInt8] {
        try base.readFile(at: path, maxBytes: maxBytes)
    }

    func resolvingSymlinks(_ path: FilePath) throws(FSError) -> FilePath {
        try base.resolvingSymlinks(path)
    }
}
