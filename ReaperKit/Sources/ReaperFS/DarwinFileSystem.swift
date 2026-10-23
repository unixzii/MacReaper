import Darwin
import System

/// The local file system, read through BSD calls.
///
/// Directories are listed with getattrlistbulk(2), which returns the names and attributes of many
/// entries per system call.
public struct DarwinFileSystem: FileSystem {

    /// Bytes handed to each getattrlistbulk(2) call; it fills them with as many records as fit.
    static let listingBufferSize = 128 * 1024

    public init() {}

    public func listDirectory(at path: FilePath, options: ListingOptions) throws(FSError) -> DirectoryListing {
        let descriptor = try open(path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(descriptor) }

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.listingBufferSize, alignment: 8)
        defer { buffer.deallocate() }

        let (attributes, requestOptions) = BulkAttributes.makeRequest(options)
        var request = attributes
        var entries: [EntryAttributes] = []
        var failures: [EntryFailure] = []
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer.baseAddress, buffer.count, requestOptions)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw FSError(errno: errno)
            }

            var offset = 0
            for _ in 0..<count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let record = UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + length])
                switch BulkAttributes.parse(record) {
                case .entry(let entry): entries.append(entry)
                case .failure(let failure): failures.append(failure)
                }
                offset += length
            }
        }
        return DirectoryListing(entries: entries, failures: failures)
    }

    public func exists(at path: FilePath) -> Bool {
        path.withPlatformString { cPath in
            var info = stat()
            return lstat(cPath, &info) == 0
        }
    }

    public func readFile(at path: FilePath, maxBytes: Int) throws(FSError) -> [UInt8] {
        let descriptor = try open(path, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(descriptor) }

        var bytes = [UInt8](repeating: 0, count: maxBytes)
        var filled = 0
        while filled < maxBytes {
            let result = bytes.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress! + filled, maxBytes - filled)
            }
            if result == 0 {
                break
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw FSError(errno: errno)
            }
            filled += result
        }
        bytes.removeSubrange(filled...)
        return bytes
    }

    public func resolvingSymlinks(_ path: FilePath) throws(FSError) -> FilePath {
        let (resolved, code) = path.withPlatformString { cPath in
            (realpath(cPath, nil), errno)
        }
        guard let resolved else {
            throw FSError(errno: code)
        }
        defer { free(resolved) }
        return FilePath(platformString: resolved)
    }

    /// Makes file-system calls on the current thread fail with ``FSError/dataless`` instead of
    /// downloading iCloud or File Provider placeholders. Scanning threads call this once at start.
    ///
    /// - Returns: Whether the policy was applied.
    @discardableResult
    public static func disableDatalessMaterializationOnCurrentThread() -> Bool {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
    }

    private func open(_ path: FilePath, flags: Int32) throws(FSError) -> Int32 {
        let (descriptor, code) = path.withPlatformString { cPath in
            (Darwin.open(cPath, flags), errno)
        }
        guard descriptor >= 0 else {
            throw FSError(errno: code)
        }
        return descriptor
    }
}
