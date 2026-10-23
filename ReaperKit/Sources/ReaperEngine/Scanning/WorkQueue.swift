import Foundation
import System

/// A unit of work for the scan's workers.
enum Work: Sendable {
    /// List a directory, evaluate it and its files, and find the subdirectories to visit.
    case visit(WorkItem)
    /// Add up a directory that is, or lies inside, the candidate at `candidate`.
    case sizeDirectory(FilePath, candidate: String, device: Int32)
    /// Size the claimed files `names` of a directory; each file is its own candidate.
    case sizeFiles(in: FilePath, names: [String])

    var isSizing: Bool {
        if case .visit = self { false } else { true }
    }
}

/// The work waiting to be done, shared by the scan's worker threads.
///
/// Work comes off the top of a stack, so the walk goes depth first and the queue holds roughly
/// depth × width items rather than whole levels of the tree. Visiting comes before sizing, so
/// candidates are found as early as possible. The scan is done when no work is waiting and none
/// is in progress, because only work in progress can produce more.
final class WorkQueue: @unchecked Sendable {

    // Everything below is guarded by `condition`.
    private let condition = NSCondition()
    private var visits: [Work] = []
    private var sizing: [Work] = []
    /// Work waiting or in progress.
    private var pending = 0
    /// Visits waiting or in progress.
    private var pendingVisits = 0
    private var isCancelled = false

    func push(_ work: [Work]) {
        guard !work.isEmpty else {
            return
        }
        condition.lock()
        for item in work {
            if item.isSizing {
                sizing.append(item)
            } else {
                visits.append(item)
                pendingVisits += 1
            }
        }
        pending += work.count
        condition.broadcast()
        condition.unlock()
    }

    /// The next work to do, waiting while other workers may still produce some. Returns `nil`
    /// when the scan is done or cancelled. Every item returned must be passed to ``finish(_:)``
    /// after the work it produced has been pushed.
    func next() -> Work? {
        condition.lock()
        defer { condition.unlock() }
        while visits.isEmpty, sizing.isEmpty, pending > 0, !isCancelled {
            condition.wait()
        }
        guard !isCancelled else {
            return nil
        }
        return visits.popLast() ?? sizing.popLast()
    }

    /// Marks `work` done.
    ///
    /// - Returns: Whether it was the last visit, so that only sizing remains.
    @discardableResult
    func finish(_ work: Work) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        pending -= 1
        if pending == 0 {
            condition.broadcast()
        }
        guard !work.isSizing else {
            return false
        }
        pendingVisits -= 1
        return pendingVisits == 0
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
