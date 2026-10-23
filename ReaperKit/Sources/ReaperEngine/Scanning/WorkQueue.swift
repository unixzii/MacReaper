import Foundation
import System

/// The directories waiting to be listed, shared by the scan's worker threads.
///
/// Items come off the top of a stack, so the walk goes depth first and the queue holds roughly
/// depth × width items rather than whole levels of the tree. Directories to evaluate come before
/// directories to measure, so candidates are found as early as possible. The scan is done when
/// nothing is waiting and nothing is in progress, because only work in progress can add more.
final class WorkQueue: @unchecked Sendable {

    // Everything below is guarded by `condition`.
    private let condition = NSCondition()
    private var evaluations: [WorkItem] = []
    private var measurements: [WorkItem] = []
    /// Items waiting or in progress.
    private var pending = 0
    /// Items to evaluate, waiting or in progress.
    private var pendingEvaluations = 0
    private var isCancelled = false

    func push(_ items: [WorkItem]) {
        guard !items.isEmpty else {
            return
        }
        condition.lock()
        for item in items {
            if item.isMeasuring {
                measurements.append(item)
            } else {
                evaluations.append(item)
                pendingEvaluations += 1
            }
        }
        pending += items.count
        condition.broadcast()
        condition.unlock()
    }

    /// The next directory to list, waiting while other workers may still add some. Returns `nil`
    /// when the scan is done or cancelled. Every item returned must be passed to ``finish(_:)``
    /// after the items it led to have been pushed.
    func next() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while evaluations.isEmpty, measurements.isEmpty, pending > 0, !isCancelled {
            condition.wait()
        }
        guard !isCancelled else {
            return nil
        }
        return evaluations.popLast() ?? measurements.popLast()
    }

    /// Marks `item` done.
    ///
    /// - Returns: Whether it was the last directory to evaluate, so that only measuring remains.
    @discardableResult
    func finish(_ item: WorkItem) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        pending -= 1
        if pending == 0 {
            condition.broadcast()
        }
        guard !item.isMeasuring else {
            return false
        }
        pendingEvaluations -= 1
        return pendingEvaluations == 0
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
