import Darwin
import Foundation
import ReaperFS
import System

func lstatInfo(_ path: FilePath) throws -> stat {
    var info = stat()
    guard lstat(path.string, &info) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return info
}

/// Captures the outcome of a ``FileSystem`` call so outcomes from two file systems can be compared.
func outcome<T>(_ body: @autoclosure () throws(FSError) -> T) -> Result<T, FSError> {
    do {
        return .success(try body())
    } catch {
        return .failure(error)
    }
}
