import Foundation
import System

/// A directory being deleted, which can go once everything in it has.
final class PendingDirectory: @unchecked Sendable {

    let path: FilePath
    /// `nil` for the candidate itself.
    let parent: PendingDirectory?
    /// The candidate's index.
    let candidate: Int
    // Guarded by the queue.
    /// The directory's own entries until they are deleted, plus each subdirectory not yet removed.
    fileprivate var waitingFor = 1
    /// Whether something inside could not be deleted, so neither can the directory.
    fileprivate var isIncomplete = false

    init(path: FilePath, parent: PendingDirectory?, candidate: Int) {
        self.path = path
        self.parent = parent
        self.candidate = candidate
    }
}

/// The candidates and directories waiting to be deleted, shared by cleanup's threads.
///
/// Directories of candidates already started come before candidates not yet started, so that
/// every thread helps with a large candidate, and candidates finish roughly in order. Cleanup is
/// done when nothing is waiting and nothing is in progress, because only work in progress can add
/// more.
final class RemovalQueue: @unchecked Sendable {

    enum Work {
        case candidate(Int)
        case directory(PendingDirectory)
    }

    // Everything below is guarded by `condition`.
    private let condition = NSCondition()
    /// Candidates not yet started, last first.
    private var candidates: [Int]
    private var directories: [PendingDirectory] = []
    private var inProgress = 0

    init(candidateCount: Int) {
        candidates = Array((0..<candidateCount).reversed())
    }

    /// The next piece of work, waiting while work in progress may still add some. Returns `nil`
    /// when everything is done. Every piece returned must be passed to ``finish()`` after the
    /// directories it led to have been pushed.
    func next() -> Work? {
        condition.lock()
        defer { condition.unlock() }
        while directories.isEmpty, candidates.isEmpty, inProgress > 0 {
            condition.wait()
        }
        if let directory = directories.popLast() {
            inProgress += 1
            return .directory(directory)
        }
        if let candidate = candidates.popLast() {
            inProgress += 1
            return .candidate(candidate)
        }
        return nil
    }

    func finish() {
        condition.lock()
        inProgress -= 1
        if inProgress == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Queues `subdirectories` of `directory`, which then waits for them too.
    func push(_ subdirectories: [PendingDirectory], of directory: PendingDirectory) {
        guard !subdirectories.isEmpty else {
            return
        }
        condition.lock()
        directory.waitingFor += subdirectories.count
        directories += subdirectories
        condition.broadcast()
        condition.unlock()
    }

    /// Marks one thing `directory` waits for as done, and it as incomplete if that thing was.
    ///
    /// - Returns: Whether the directory waits for nothing more and can be removed, unless it is
    ///   incomplete.
    func release(_ directory: PendingDirectory, isIncomplete: Bool) -> (isDone: Bool, isIncomplete: Bool) {
        condition.lock()
        defer { condition.unlock() }
        directory.waitingFor -= 1
        directory.isIncomplete = directory.isIncomplete || isIncomplete
        return (directory.waitingFor == 0, directory.isIncomplete)
    }

    /// Starts no more candidates. Those already started are finished.
    func stop() {
        condition.lock()
        candidates = []
        condition.broadcast()
        condition.unlock()
    }
}
