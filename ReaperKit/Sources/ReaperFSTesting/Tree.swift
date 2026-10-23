import Foundation
import ReaperFS

/// A file tree described in code, used to build an ``InMemoryFileSystem`` or to write the same
/// tree to disk with ``Tree/materialize(at:)``.
///
/// ```swift
/// let tree = Tree {
///     Directory("Developer/dua-cli") {
///         File("Cargo.toml")
///         File("target/CACHEDIR.TAG", contents: "Signature: 8a477f597d28d172789f06886806bc55")
///     }
///     Symlink("latest", to: "Developer/dua-cli")
/// }
/// ```
///
/// Paths are relative to the tree's root and may contain `/`; missing parent directories are
/// created, and a directory declared twice is merged.
public struct Tree: Sendable {

    /// The modification date of nodes that do not set one.
    public static let defaultModified = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    public var nodes: [TreeNode]

    public init(@TreeBuilder _ nodes: () -> [TreeNode]) {
        self.nodes = nodes()
    }
}

/// One node of a ``Tree``. Write trees with ``Directory``, ``File``, ``HardLink`` and ``Symlink``.
public struct TreeNode: Sendable {

    public enum Content: Sendable {
        case directory(children: [TreeNode], device: Int32?, failure: FSError?)
        case file(contents: [UInt8])
        /// Another name for a file declared earlier, given by its path from the tree's root.
        case hardLink(target: String)
        /// A copy-on-write clone of a file declared earlier: a separate file sharing its blocks.
        case clone(original: String)
        case symlink(target: String)
    }

    public var path: String
    public var content: Content
    public var flags: UInt32
    public var modified: Date?
}

/// Anything that can appear in a ``TreeBuilder`` block.
public protocol TreeContent: Sendable {

    var node: TreeNode { get }
}

public struct Directory: TreeContent {

    public let node: TreeNode

    /// - Parameters:
    ///   - device: Puts the directory and everything below it on another volume. In-memory only.
    ///   - failure: The error listing the directory throws. On disk, only
    ///     ``FSError/permissionDenied`` can be materialized.
    public init(
        _ path: String,
        device: Int32? = nil,
        failure: FSError? = nil,
        flags: UInt32 = 0,
        modified: Date? = nil,
        @TreeBuilder _ children: () -> [TreeNode] = { [] }
    ) {
        node = TreeNode(
            path: path,
            content: .directory(children: children(), device: device, failure: failure),
            flags: flags,
            modified: modified
        )
    }
}

public struct File: TreeContent {

    public let node: TreeNode

    public init(_ path: String, contents: String = "", flags: UInt32 = 0, modified: Date? = nil) {
        node = TreeNode(path: path, content: .file(contents: Array(contents.utf8)), flags: flags, modified: modified)
    }
}

public struct HardLink: TreeContent {

    public let node: TreeNode

    /// - Parameter target: The path of an earlier file, from the tree's root.
    public init(_ path: String, to target: String) {
        node = TreeNode(path: path, content: .hardLink(target: target), flags: 0, modified: nil)
    }
}

public struct Clone: TreeContent {

    public let node: TreeNode

    /// - Parameter original: The path of an earlier file, from the tree's root.
    public init(_ path: String, of original: String, modified: Date? = nil) {
        node = TreeNode(path: path, content: .clone(original: original), flags: 0, modified: modified)
    }
}

public struct Symlink: TreeContent {

    public let node: TreeNode

    public init(_ path: String, to target: String, modified: Date? = nil) {
        node = TreeNode(path: path, content: .symlink(target: target), flags: 0, modified: modified)
    }
}

@resultBuilder
public enum TreeBuilder {
    public static func buildExpression(_ content: some TreeContent) -> [TreeNode] {
        [content.node]
    }

    public static func buildBlock(_ parts: [TreeNode]...) -> [TreeNode] {
        parts.flatMap { $0 }
    }

    public static func buildOptional(_ part: [TreeNode]?) -> [TreeNode] {
        part ?? []
    }

    public static func buildEither(first part: [TreeNode]) -> [TreeNode] {
        part
    }

    public static func buildEither(second part: [TreeNode]) -> [TreeNode] {
        part
    }

    public static func buildArray(_ parts: [[TreeNode]]) -> [TreeNode] {
        parts.flatMap { $0 }
    }
}

// MARK: - Flattening

/// One node of a ``Tree`` with its full relative path and inherited properties resolved.
struct FlatNode {

    enum Kind {
        case directory(failure: FSError?)
        case file(contents: [UInt8])
        case hardLink(target: [String])
        case clone(original: [String])
        case symlink(target: String)
    }

    var components: [String]
    var kind: Kind
    var device: Int32
    var flags: UInt32
    var modified: Date
}

extension Tree {

    /// The tree's nodes in creation order: every directory before its contents, every hard link
    /// and clone after its original.
    func flattened(rootDevice: Int32) -> [FlatNode] {
        var flat: [FlatNode] = []
        var directoryIndex: [[String]: Int] = [:]

        func add(_ nodes: [TreeNode], under parent: [String], device: Int32) {
            for node in nodes {
                let components = parent + node.path.split(separator: "/").map(String.init)
                precondition(!components.isEmpty, "Tree node with an empty path")

                // Create missing intermediate directories.
                for depth in parent.count + 1..<components.count {
                    let prefix = Array(components[..<depth])
                    if directoryIndex[prefix] == nil {
                        directoryIndex[prefix] = flat.count
                        flat.append(FlatNode(
                            components: prefix,
                            kind: .directory(failure: nil),
                            device: device,
                            flags: 0,
                            modified: Tree.defaultModified
                        ))
                    }
                }

                switch node.content {
                case .directory(let children, let nodeDevice, let failure):
                    let childDevice = nodeDevice ?? device
                    if let index = directoryIndex[components] {
                        // Merge a re-declared directory; explicit properties win.
                        flat[index].device = childDevice
                        if failure != nil { flat[index].kind = .directory(failure: failure) }
                        if node.flags != 0 { flat[index].flags = node.flags }
                        if let modified = node.modified { flat[index].modified = modified }
                    } else {
                        directoryIndex[components] = flat.count
                        flat.append(FlatNode(
                            components: components,
                            kind: .directory(failure: failure),
                            device: childDevice,
                            flags: node.flags,
                            modified: node.modified ?? Tree.defaultModified
                        ))
                    }
                    add(children, under: components, device: childDevice)
                case .file(let contents):
                    flat.append(FlatNode(
                        components: components,
                        kind: .file(contents: contents),
                        device: device,
                        flags: node.flags,
                        modified: node.modified ?? Tree.defaultModified
                    ))
                case .hardLink(let target):
                    flat.append(FlatNode(
                        components: components,
                        kind: .hardLink(target: target.split(separator: "/").map(String.init)),
                        device: device,
                        flags: 0,
                        modified: Tree.defaultModified
                    ))
                case .clone(let original):
                    flat.append(FlatNode(
                        components: components,
                        kind: .clone(original: original.split(separator: "/").map(String.init)),
                        device: device,
                        flags: 0,
                        modified: node.modified ?? Tree.defaultModified
                    ))
                case .symlink(let target):
                    flat.append(FlatNode(
                        components: components,
                        kind: .symlink(target: target),
                        device: device,
                        flags: 0,
                        modified: node.modified ?? Tree.defaultModified
                    ))
                }
            }
        }

        add(nodes, under: [], device: rootDevice)
        return flat
    }
}
