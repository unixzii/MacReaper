import Darwin

/// An error from a ``FileSystem`` operation.
public enum FSError: Error, Hashable, Sendable {
    case notFound
    /// The caller lacks permission, usually because the app has no Full Disk Access.
    case permissionDenied
    case notADirectory
    /// A file read ended on a symlink, which is not followed, or a chain of symlinks is too
    /// long. Listing a symlink reports ``notADirectory`` instead, as the kernel does.
    case symlink
    /// The item is a dataless iCloud or File Provider placeholder, and downloading it is disabled.
    case dataless
    case io(errno: Int32)

    public init(errno code: Int32) {
        switch code {
        case ENOENT: self = .notFound
        case EACCES, EPERM: self = .permissionDenied
        case ENOTDIR: self = .notADirectory
        case ELOOP: self = .symlink
        case EDEADLK: self = .dataless
        default: self = .io(errno: code)
        }
    }
}
