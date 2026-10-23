import Darwin
import Foundation
import ReaperFS
import System

/// A ``FileSystem`` held in memory, for tests and previews.
///
/// It reproduces the behavior the scanner depends on: symlinks are never followed in the final
/// component but are followed in the middle of a path, hard links share an identity, directories
/// may sit on other volumes or fail to list, and listings can come back in a shuffled order.
public struct InMemoryFileSystem: FileSystem {

    public enum ListingOrder: Sendable {
        case byName
        /// A stable pseudo-random order per directory, derived from `seed` and the directory's path.
        case shuffled(seed: UInt64)
    }

    private struct Node: Sendable {

        enum Kind: Sendable {
            case directory(children: [String], failure: FSError?)
            case file(contents: [UInt8])
            case symlink(target: String)
        }

        var kind: Kind
        var identity: FileIdentity
        var flags: UInt32
        var modified: Date
        /// Files cloned from one another share a group; a file never cloned has none.
        var cloneGroup: UInt64?
    }

    private static let maxSymlinkHops = 32

    private let nodes: [FilePath: Node]
    private let linkCounts: [FileIdentity: UInt32]
    /// The number of distinct files in each clone group.
    private let cloneGroupSizes: [UInt64: Int]
    private let order: ListingOrder

    /// Creates a file system whose `tree` is mounted at `root`. The directories leading to
    /// `root` are created empty, on device 1.
    public init(root: FilePath = "/", order: ListingOrder = .byName, tree: Tree) {
        precondition(root.isAbsolute, "The root of an InMemoryFileSystem must be absolute")
        var nodes: [FilePath: Node] = [:]
        var nextFileID: UInt64 = 1

        func insert(_ path: FilePath, _ kind: Node.Kind, device: Int32, flags: UInt32, modified: Date) {
            precondition(nodes[path] == nil, "Tree declares \(path) twice")
            nodes[path] = Node(
                kind: kind,
                identity: FileIdentity(device: device, fileID: nextFileID),
                flags: flags,
                modified: modified
            )
            nextFileID += 1
            if let name = path.lastComponent?.string {
                Self.appendChild(name, to: path.removingLastComponent(), in: &nodes)
            }
        }

        var ancestor = FilePath("/")
        insert(ancestor, .directory(children: [], failure: nil), device: 1, flags: 0, modified: Tree.defaultModified)
        for component in root.components {
            ancestor.append(component)
            insert(ancestor, .directory(children: [], failure: nil), device: 1, flags: 0, modified: Tree.defaultModified)
        }

        for node in tree.flattened(rootDevice: 1) {
            let path = Self.path(root, node.components)
            switch node.kind {
            case .directory(let failure):
                insert(path, .directory(children: [], failure: failure),
                       device: node.device, flags: node.flags, modified: node.modified)
            case .file(let contents):
                insert(path, .file(contents: contents),
                       device: node.device, flags: node.flags, modified: node.modified)
            case .symlink(let target):
                insert(path, .symlink(target: target),
                       device: node.device, flags: node.flags, modified: node.modified)
            case .hardLink(let target):
                guard let original = nodes[Self.path(root, target)], case .file = original.kind else {
                    preconditionFailure("Hard link \(path) must point to a file declared before it")
                }
                nodes[path] = original
                Self.appendChild(node.components.last!, to: path.removingLastComponent(), in: &nodes)
            case .clone(let original):
                let originalPath = Self.path(root, original)
                guard let source = nodes[originalPath], case .file(let contents) = source.kind else {
                    preconditionFailure("Clone \(path) must copy a file declared before it")
                }
                let group = source.cloneGroup ?? source.identity.fileID
                for (otherPath, other) in nodes where other.identity == source.identity {
                    nodes[otherPath]!.cloneGroup = group
                }
                insert(path, .file(contents: contents), device: node.device, flags: node.flags, modified: node.modified)
                nodes[path]!.cloneGroup = group
            }
        }

        self.nodes = nodes
        self.linkCounts = nodes.values.reduce(into: [:]) { counts, node in
            if case .file = node.kind {
                counts[node.identity, default: 0] += 1
            }
        }
        self.cloneGroupSizes = Dictionary(grouping: Set(nodes.values.compactMap { node in
            node.cloneGroup.map { [$0, node.identity.fileID] }
        }), by: { $0[0] }).mapValues(\.count)
        self.order = order
    }

    public init(root: FilePath = "/", order: ListingOrder = .byName, @TreeBuilder _ nodes: () -> [TreeNode]) {
        self.init(root: root, order: order, tree: Tree(nodes))
    }

    // MARK: FileSystem

    public func listDirectory(at path: FilePath, options: ListingOptions) throws(FSError) -> DirectoryListing {
        let resolved = try resolve(path, followingFinalSymlink: false)
        let node = nodes[resolved]!
        switch node.kind {
        case .symlink, .file:
            // open(2) with O_DIRECTORY | O_NOFOLLOW reports ENOTDIR for a symlink, not ELOOP.
            throw .notADirectory
        case .directory(let children, let failure):
            if let failure {
                throw failure
            }
            if node.flags & UInt32(SF_DATALESS) != 0 {
                throw .dataless
            }
            let entries = ordered(children, in: resolved).map { name in
                attributes(of: nodes[resolved.appending(name)]!, named: name, options: options)
            }
            return DirectoryListing(entries: entries)
        }
    }

    public func exists(at path: FilePath) -> Bool {
        (try? resolve(path, followingFinalSymlink: false)) != nil
    }

    public func readFile(at path: FilePath, maxBytes: Int) throws(FSError) -> [UInt8] {
        let node = nodes[try resolve(path, followingFinalSymlink: false)]!
        switch node.kind {
        case .symlink:
            throw .symlink
        case .directory(_, let failure):
            throw failure == .permissionDenied ? .permissionDenied : .io(errno: EISDIR)
        case .file(let contents):
            if node.flags & UInt32(SF_DATALESS) != 0 {
                throw .dataless
            }
            return Array(contents.prefix(maxBytes))
        }
    }

    public func resolvingSymlinks(_ path: FilePath) throws(FSError) -> FilePath {
        try resolve(path, followingFinalSymlink: true)
    }

    // MARK: Helpers

    /// Walks `path` component by component the way the kernel does: symlinks in the middle are
    /// followed, the final one only if asked, and directories that deny access cannot be entered.
    private func resolve(_ path: FilePath, followingFinalSymlink: Bool) throws(FSError) -> FilePath {
        guard path.isAbsolute else {
            throw .notFound
        }
        var pending = path.components.map(\.string)
        var resolved = FilePath("/")
        var hops = 0

        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." {
                continue
            }
            if component == ".." {
                resolved.removeLastComponent()
                continue
            }

            let candidate = resolved.appending(component)
            guard let node = nodes[candidate] else {
                throw .notFound
            }
            let isFinal = pending.isEmpty
            switch node.kind {
            case .symlink(let target) where followingFinalSymlink || !isFinal:
                hops += 1
                guard hops <= Self.maxSymlinkHops else {
                    throw .symlink
                }
                let targetPath = FilePath(target)
                if targetPath.isAbsolute {
                    resolved = FilePath("/")
                }
                pending = targetPath.components.map(\.string) + pending
            case .directory(_, let failure):
                if !isFinal, failure == .permissionDenied {
                    throw .permissionDenied
                }
                resolved = candidate
            case .file, .symlink:
                guard isFinal else {
                    throw .notADirectory
                }
                resolved = candidate
            }
        }
        return resolved
    }

    private func attributes(of node: Node, named name: String, options: ListingOptions) -> EntryAttributes {
        switch node.kind {
        case .directory:
            return EntryAttributes(name: name, kind: .directory, identity: node.identity, modified: node.modified, flags: node.flags)
        case .symlink:
            return EntryAttributes(name: name, kind: .symlink, identity: node.identity, modified: node.modified, flags: node.flags)
        case .file(let contents):
            let allocatedSize = UInt64((contents.count + 4095) / 4096 * 4096)
            let isShared = node.cloneGroup.map { cloneGroupSizes[$0, default: 1] > 1 } ?? false
            return EntryAttributes(
                name: name,
                kind: .file,
                identity: node.identity,
                modified: node.modified,
                flags: node.flags,
                linkCount: linkCounts[node.identity] ?? 1,
                allocatedSize: allocatedSize,
                sharesBlocks: options.contains(.sharedBlocks) ? isShared : nil
            )
        }
    }

    private func ordered(_ names: [String], in directory: FilePath) -> [String] {
        switch order {
        case .byName:
            return names.sorted()
        case .shuffled(let seed):
            var generator = SplitMix64(seed: seed ^ fnv1a(directory.string))
            return names.sorted().shuffled(using: &generator)
        }
    }

    private static func path(_ root: FilePath, _ components: [String]) -> FilePath {
        components.reduce(into: root) { path, component in path.append(component) }
    }

    private static func appendChild(_ name: String, to parent: FilePath, in nodes: inout [FilePath: Node]) {
        guard case .directory(var children, let failure) = nodes[parent]?.kind else {
            preconditionFailure("\(parent) is not a directory")
        }
        children.append(name)
        nodes[parent]!.kind = .directory(children: children, failure: failure)
    }
}

/// A small, fast, seedable generator (Steele, Lea and Flood's SplitMix64).
struct SplitMix64: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// FNV-1a over UTF-8 bytes. Unlike `Hasher`, it is the same in every process.
private func fnv1a(_ string: String) -> UInt64 {
    string.utf8.reduce(0xCBF2_9CE4_8422_2325) { hash, byte in
        (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
}
