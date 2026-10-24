import Foundation
import ReaperFS
import ReaperFSTesting
import System
import Testing

/// Builds one tree on disk and in memory and checks that both file systems agree on every
/// listing and every probe, errors included. This is what keeps ``InMemoryFileSystem`` honest.
@Suite("DarwinFileSystem and InMemoryFileSystem agree")
struct ParityTests {

    static let tree = Tree {
        Directory("src") {
            File("main.rs", contents: "fn main() {}\n")
            File("lib.rs", contents: String(repeating: "a", count: 5_000), modified: Date(timeIntervalSince1970: 1_700_000_000))
        }
        Directory("target/debug/deps", modified: Date(timeIntervalSince1970: 1_750_000_000))
        File("target/CACHEDIR.TAG", contents: "Signature: 8a477f597d28d172789f06886806bc55")
        HardLink("lib-copy.rs", to: "src/lib.rs")
        Clone("main-clone.rs", of: "src/main.rs")
        File("big.bin", contents: String(repeating: "b", count: 20_000))
        Clone("big-clone.bin", of: "big.bin")
        Clone("big-clone-2.bin", of: "big-clone.bin")
        Symlink("link-to-src", to: "src")
        Symlink("dangling", to: "nowhere")
        Symlink("loop-a", to: "loop-b")
        Symlink("loop-b", to: "loop-a")
        Directory("locked", failure: .permissionDenied) {
            File("secret", contents: "x")
        }
        File("Cafe\u{301}.txt")
        Directory("empty")
    }

    static let probes = [
        "", "src", "src/main.rs", "src/lib.rs", "src/main.rs/below-a-file", "link-to-src", "link-to-src/main.rs",
        "link-to-src/../src", "dangling", "loop-a", "locked", "locked/secret", "missing", "target/../src",
    ]

    @Test("Listings agree, recursively", arguments: [ListingOptions(), .sharedBlocks])
    func listingsAgree(options: ListingOptions) throws {
        let temporary = try TemporaryDirectory()
        try Self.tree.materialize(at: temporary.path)
        let disk = DarwinFileSystem()
        let memory = InMemoryFileSystem(root: temporary.path, tree: Self.tree)

        var pending = [temporary.path]
        while let directory = pending.popLast() {
            let onDisk = outcome(try disk.listDirectory(at: directory, options: options))
            let inMemory = outcome(try memory.listDirectory(at: directory, options: options))
            #expect(onDisk.map(Snapshot.init) == inMemory.map(Snapshot.init), "\(directory)")

            if case .success(let listing) = onDisk {
                pending += listing.entries.filter { $0.kind == .directory }.map { directory.appending($0.name) }
            }
        }
    }

    @Test("Probes agree", arguments: probes)
    func probesAgree(relativePath: String) throws {
        let temporary = try TemporaryDirectory()
        try Self.tree.materialize(at: temporary.path)
        let disk = DarwinFileSystem()
        let memory = InMemoryFileSystem(root: temporary.path, tree: Self.tree)
        let path = FilePath(temporary.path.string + "/" + relativePath)

        #expect(disk.exists(at: path) == memory.exists(at: path))
        // Identities differ between the two, so only kinds and errors are compared.
        #expect(outcome(try disk.identity(at: path).kind) == outcome(try memory.identity(at: path).kind))
        #expect(outcome(try disk.readFile(at: path, maxBytes: 64)) == outcome(try memory.readFile(at: path, maxBytes: 64)))
        #expect(outcome(try disk.resolvingSymlinks(path)) == outcome(try memory.resolvingSymlinks(path)))
        #expect(
            outcome(try disk.listDirectory(at: path)).map(Snapshot.init)
                == outcome(try memory.listDirectory(at: path)).map(Snapshot.init)
        )
    }
}

/// The parts of a listing that must agree across file systems. File IDs and devices differ by
/// construction, so they are compared by how entries relate: which ones share an identity.
private struct Snapshot: Equatable {

    struct Entry: Equatable {

        var name: [UInt8]
        var kind: EntryKind
        var modified: Date
        var flags: UInt32
        var linkCount: UInt32
        var allocatedSize: UInt64
        var sharesBlocks: Bool?
    }

    var entries: [Entry]
    var failures: [EntryFailure]
    var sharedIdentities: Set<Set<[UInt8]>>

    init(_ listing: DirectoryListing) {
        let sorted = listing.entries.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        entries = sorted.map { entry in
            Entry(
                name: Array(entry.name.utf8),
                kind: entry.kind,
                modified: entry.modified,
                flags: entry.flags,
                linkCount: entry.linkCount,
                allocatedSize: entry.allocatedSize,
                sharesBlocks: entry.sharesBlocks
            )
        }
        failures = listing.failures
        sharedIdentities = Set(
            Dictionary(grouping: sorted, by: \.identity).values
                .filter { $0.count > 1 }
                .map { Set($0.map { Array($0.name.utf8) }) }
        )
    }
}
