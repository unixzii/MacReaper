import Darwin
import Foundation
import ReaperFS
import System

/// A uniquely named directory under the user's temporary directory, removed when released.
public final class TemporaryDirectory {

    public let path: FilePath

    public init() throws {
        let template = NSTemporaryDirectory() + "ReaperKitTests.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard mkdtemp(&bytes) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Resolve /var → /private/var so paths compare equal to what realpath(3) returns.
        let created = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        path = try DarwinFileSystem().resolvingSymlinks(FilePath(created))
    }

    deinit {
        Self.unlock(path)
        try? FileManager.default.removeItem(atPath: path.string)
    }

    /// Gives back permissions that ``Tree/materialize(at:)`` removed, so the tree can be deleted.
    private static func unlock(_ path: FilePath) {
        var info = stat()
        guard lstat(path.string, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return
        }
        chmod(path.string, 0o755)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path.string)) ?? [] {
            unlock(path.appending(name))
        }
    }
}
