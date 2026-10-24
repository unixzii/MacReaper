import Darwin
import System

/// An entry that could not be deleted.
public struct RemovalFailure: Hashable, Sendable {

    public var path: FilePath
    public var error: FSError

    public init(path: FilePath, error: FSError) {
        self.path = path
        self.error = error
    }
}

/// What ``DarwinFileSystem/emptyDirectory(at:)`` did, and what it left to the caller.
public struct EmptiedDirectory: Sendable {

    /// The subdirectories, still there, for the caller to empty and remove before the directory.
    public var subdirectories: [FilePath] = []
    /// Entries deleted.
    public var removed = 0
    /// Entries that could not be deleted, and subdirectories on another volume, which are left
    /// alone.
    public var failures: [RemovalFailure] = []
}

/// Deleting, for cleanup. Every call works on one directory or entry, so that callers can spread
/// a large tree over several threads, and none follows a symlink in the final path component:
/// a symlink is deleted, never what it points to.
///
/// Deleting a read-only entry inside a directory the user owns needs write permission on the
/// directory, which these calls grant themselves, as `go clean -modcache` does.
extension DarwinFileSystem {

    /// Deletes the file or symlink at `path`.
    public func removeFile(at path: FilePath) throws(FSError) {
        try Self.check(path.withPlatformString { Darwin.unlink($0) })
    }

    /// Deletes everything in the directory at `path` except its subdirectories, which the result
    /// lists for the caller to empty and remove first.
    ///
    /// - Throws: An error if the directory cannot be opened; nothing is deleted then.
    public func emptyDirectory(at path: FilePath) throws(FSError) -> EmptiedDirectory {
        let descriptor = try openDirectory(path)
        defer { close(descriptor) }
        var info = stat()
        try Self.check(fstat(descriptor, &info))

        var result = EmptiedDirectory()
        // Read every name before deleting any, since deleting while reading may skip entries.
        for (name, type) in try Self.names(in: descriptor) {
            let child = path.appending(name)
            var isDirectory = type == DT_DIR
            if type == DT_UNKNOWN || isDirectory {
                var childInfo = stat()
                guard fstatat(descriptor, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                    result.failures.append(RemovalFailure(path: child, error: FSError(errno: errno)))
                    continue
                }
                isDirectory = childInfo.st_mode & S_IFMT == S_IFDIR
                if isDirectory, childInfo.st_dev != info.st_dev {
                    result.failures.append(RemovalFailure(path: child, error: .io(errno: EXDEV)))
                    continue
                }
            }
            if isDirectory {
                result.subdirectories.append(child)
            } else if let error = Self.unlinkEntry(name, in: descriptor, mode: info.st_mode) {
                result.failures.append(RemovalFailure(path: child, error: error))
            } else {
                result.removed += 1
            }
        }
        return result
    }

    /// Deletes the empty directory at `path`.
    public func removeDirectory(at path: FilePath) throws(FSError) {
        let code = path.withPlatformString { cPath -> Int32 in
            if rmdir(cPath) == 0 {
                return 0
            }
            // Removing a directory needs write permission on its parent.
            guard errno == EACCES, Self.grantPermission(path.removingLastComponent()) else {
                return errno
            }
            return rmdir(cPath) == 0 ? 0 : errno
        }
        if code != 0 {
            throw FSError(errno: code)
        }
    }

    // MARK: Helpers

    /// Opens a directory for emptying, giving the user read and search permission on it if needed.
    private func openDirectory(_ path: FilePath) throws(FSError) -> Int32 {
        let (descriptor, code) = path.withPlatformString { cPath in
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var descriptor = Darwin.open(cPath, flags)
            if descriptor < 0, errno == EACCES, Self.grantPermission(path) {
                descriptor = Darwin.open(cPath, flags)
            }
            return (descriptor, errno)
        }
        guard descriptor >= 0 else {
            throw FSError(errno: code)
        }
        return descriptor
    }

    /// Gives the user read, write and search permission on the directory at `path`.
    private static func grantPermission(_ path: FilePath) -> Bool {
        path.withPlatformString { cPath in
            var info = stat()
            return lstat(cPath, &info) == 0 && chmod(cPath, info.st_mode & 0o7777 | S_IRWXU) == 0
        }
    }

    /// Deletes `name` from the open directory, granting the user write permission on the
    /// directory if that is what it takes.
    private static func unlinkEntry(_ name: String, in directory: Int32, mode: mode_t) -> FSError? {
        if unlinkat(directory, name, 0) == 0 {
            return nil
        }
        guard errno == EACCES, fchmod(directory, mode & 0o7777 | S_IRWXU) == 0 else {
            return FSError(errno: errno)
        }
        return unlinkat(directory, name, 0) == 0 ? nil : FSError(errno: errno)
    }

    private static func names(in directory: Int32) throws(FSError) -> [(name: String, type: Int32)] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            throw FSError(errno: errno)
        }
        defer { closedir(stream) }
        var names: [(String, Int32)] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." {
                names.append((name, Int32(entry.pointee.d_type)))
            }
        }
        return names
    }

    private static func check(_ result: Int32) throws(FSError) {
        if result != 0 {
            throw FSError(errno: errno)
        }
    }
}
