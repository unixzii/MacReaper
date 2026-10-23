import Darwin
import Foundation
import ReaperFS
import System

extension Tree {

    public struct MaterializeError: Error, CustomStringConvertible {

        public var path: FilePath
        public var errno: Int32

        public var description: String {
            "Cannot materialize \(path): \(String(cString: strerror(errno)))"
        }
    }

    /// Writes the tree into `root`, an existing empty directory, so that a ``DarwinFileSystem``
    /// sees what an ``InMemoryFileSystem`` built from the same tree sees.
    ///
    /// Devices and flags cannot be reproduced and are ignored. The only failure that can be
    /// reproduced is ``FSError/permissionDenied``, by removing all permissions from the directory;
    /// restore them before deleting the tree.
    public func materialize(at root: FilePath) throws(MaterializeError) {
        let nodes = flattened(rootDevice: 0)

        func check(_ result: Int32, _ path: FilePath) throws(MaterializeError) {
            if result != 0 {
                throw MaterializeError(path: path, errno: Darwin.errno)
            }
        }

        func path(_ components: [String]) -> FilePath {
            components.reduce(into: root) { path, component in path.append(component) }
        }

        for node in nodes {
            let target = path(node.components)
            switch node.kind {
            case .directory:
                try check(target.withPlatformString { mkdir($0, 0o755) }, target)
            case .file(let contents):
                let descriptor = target.withPlatformString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
                guard descriptor >= 0 else {
                    throw MaterializeError(path: target, errno: Darwin.errno)
                }
                let written = contents.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                close(descriptor)
                try check(written == contents.count ? 0 : -1, target)
            case .hardLink(let original):
                let source = path(original)
                try check(source.withPlatformString { from in target.withPlatformString { link(from, $0) } }, target)
            case .clone(let original):
                let source = path(original)
                try check(source.withPlatformString { from in target.withPlatformString { clonefile(from, $0, 0) } }, target)
            case .symlink(let destination):
                try check(target.withPlatformString { symlink(destination, $0) }, target)
            }
        }

        // Children change their parent's modification date, so set dates deepest first, after
        // everything exists. Then lock directories, also deepest first so parents stay enterable.
        let deepestFirst = nodes.enumerated().sorted { lhs, rhs in
            (lhs.element.components.count, lhs.offset) > (rhs.element.components.count, rhs.offset)
        }.map(\.element)
        for node in deepestFirst {
            if case .hardLink = node.kind {
                continue
            }
            let target = path(node.components)
            let seconds = node.modified.timeIntervalSince1970.rounded(.down)
            let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((node.modified.timeIntervalSince1970 - seconds) * 1e9))
            let times = [time, time]
            try check(target.withPlatformString { utimensat(AT_FDCWD, $0, times, AT_SYMLINK_NOFOLLOW) }, target)
        }
        for node in deepestFirst {
            guard case .directory(let failure) = node.kind, let failure else {
                continue
            }
            precondition(failure == .permissionDenied, "Only permissionDenied can be materialized, not \(failure)")
            let target = path(node.components)
            try check(target.withPlatformString { chmod($0, 0) }, target)
        }
    }
}
