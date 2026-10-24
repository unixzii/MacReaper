import Foundation
import ReaperFS
import Synchronization
import System

/// Deletes candidates, permanently, once the user has confirmed them.
///
/// A candidate is deleted only if the item at its path is still the one the scan found, by
/// identity: one deleted or replaced since the scan is left alone. Everything inside a candidate
/// is deleted, but nothing a symlink in it points to, and nothing on another volume.
///
/// Like scanning, deleting runs on dedicated threads, since it blocks on the file system.
public struct Cleanup: Sendable {

    public let threadCount: Int

    /// - Parameter threadCount: Threads that delete in parallel, on one candidate or several.
    public init(threadCount: Int = Cleanup.defaultThreadCount) {
        self.threadCount = max(1, threadCount)
    }

    /// Deleting is the kernel's work, which a few threads share well and more contend for.
    /// Measured on APFS on a Mac with 5 performance and 6 efficiency cores, deleting 96,000
    /// small files took 5.2 s on one thread and 1.8 s on four. Eight threads were slower than
    /// four, and `rm -rf`, removefile(3) and FileManager took about as long as one thread.
    public static let defaultThreadCount = 4

    /// Deletes `candidates`, reporting progress at most once per `interval`.
    ///
    /// Cancelling the task stops cleanup from starting more candidates, but finishes those it
    /// has started, so that it never leaves one half deleted on purpose. The result lists what
    /// was not started.
    public func run(
        _ candidates: [Claim],
        reportingEvery interval: Duration = .milliseconds(100),
        progress: @escaping @Sendable (CleanupProgress) -> Void = { _ in }
    ) async -> CleanupResult {
        let start = ContinuousClock.now
        let run = CleanupRun(candidates: candidates)
        let queue = RemovalQueue(candidateCount: candidates.count)

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                progress(run.progress(elapsed: ContinuousClock.now - start))
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let group = DispatchGroup()
                for index in 0..<threadCount {
                    group.enter()
                    let thread = Thread {
                        DarwinFileSystem.disableDatalessMaterializationOnCurrentThread()
                        while let work = queue.next() {
                            run.perform(work, queue: queue)
                            queue.finish()
                        }
                        group.leave()
                    }
                    thread.name = "MacReaper cleanup worker \(index)"
                    thread.qualityOfService = .userInitiated
                    thread.start()
                }
                group.notify(queue: .global()) {
                    continuation.resume()
                }
            }
        } onCancel: {
            queue.stop()
        }
        ticker.cancel()
        let duration = ContinuousClock.now - start
        progress(run.progress(elapsed: duration))
        return run.result(duration: duration)
    }
}

/// How far cleanup has got.
public struct CleanupProgress: Hashable, Sendable {

    public var candidates: Int
    /// Candidates deleted, left alone or given up on.
    public var finishedCandidates: Int
    /// Files and folders deleted so far.
    public var removedEntries: Int
    /// The files and folders in all candidates, by their sizes; `nil` when one is unmeasured.
    public var totalEntries: Int?
    public var elapsed: Duration

    /// From 0 to 1, by entries when they are known.
    public var fraction: Double {
        if let totalEntries, totalEntries > 0 {
            return min(1, Double(removedEntries) / Double(totalEntries))
        }
        return Double(finishedCandidates) / Double(max(candidates, 1))
    }
}

/// What cleanup did with each candidate.
public struct CleanupResult: Sendable {

    /// Deleted completely, in the order given.
    public var removed: [Claim]
    /// Not deleted, or not completely, in the order given.
    public var failures: [CleanupFailure]
    /// Not started, because cleanup was stopped, in the order given.
    public var notStarted: [Claim]
    public var duration: Duration

    /// The space the deleted candidates took up. A file hard-linked into two of them counts in
    /// both, and files that share space with others may leave some of it behind.
    public var removedSize: CandidateSize {
        var size = CandidateSize()
        for candidate in removed {
            if let candidateSize = candidate.size {
                size.add(candidateSize)
            }
        }
        return size
    }
}

public struct CleanupFailure: Sendable {

    public enum Reason: Hashable, Sendable {
        /// The item at the path is gone, or is not the one the scan found. Nothing was deleted.
        case changed
        /// These entries could not be deleted, nor the folders holding them. Everything else
        /// was.
        case incomplete([RemovalFailure])
    }

    public var candidate: Claim
    public var reason: Reason
}

/// One cleanup's state, shared by its threads.
private final class CleanupRun: Sendable {

    private enum Outcome {
        case removed
        case changed
        case incomplete
    }

    private struct State {

        var outcomes: [Int: Outcome] = [:]
        var failures: [Int: [RemovalFailure]] = [:]
        var removedEntries = 0
    }

    let candidates: [Claim]
    private let fileSystem = DarwinFileSystem()
    private let state = Mutex(State())

    init(candidates: [Claim]) {
        self.candidates = candidates
    }

    func perform(_ work: RemovalQueue.Work, queue: RemovalQueue) {
        switch work {
        case .candidate(let index):
            start(index, queue: queue)
        case .directory(let directory):
            empty(directory, queue: queue)
        }
    }

    private func start(_ index: Int, queue: RemovalQueue) {
        let candidate = candidates[index]
        guard let found = try? fileSystem.identity(at: candidate.path), found.identity == candidate.identity else {
            finish(index, .changed)
            return
        }
        if found.kind == .directory {
            empty(PendingDirectory(path: candidate.path, parent: nil, candidate: index), queue: queue)
            return
        }
        do {
            try fileSystem.removeFile(at: candidate.path)
            record(removed: 1)
            finish(index, .removed)
        } catch {
            record(RemovalFailure(path: candidate.path, error: error), for: index)
            finish(index, .incomplete)
        }
    }

    /// Deletes the directory's entries and queues its subdirectories; removes it, and then any
    /// parent waiting only for it, when nothing in it is left.
    private func empty(_ directory: PendingDirectory, queue: RemovalQueue) {
        var isIncomplete: Bool
        do {
            let emptied = try fileSystem.emptyDirectory(at: directory.path)
            record(removed: emptied.removed)
            for failure in emptied.failures {
                record(failure, for: directory.candidate)
            }
            isIncomplete = !emptied.failures.isEmpty
            queue.push(
                emptied.subdirectories.map { PendingDirectory(path: $0, parent: directory, candidate: directory.candidate) },
                of: directory
            )
        } catch {
            record(RemovalFailure(path: directory.path, error: error), for: directory.candidate)
            isIncomplete = true
        }

        var current = directory
        while true {
            let released = queue.release(current, isIncomplete: isIncomplete)
            guard released.isDone else {
                return
            }
            isIncomplete = released.isIncomplete
            if !isIncomplete {
                do {
                    try fileSystem.removeDirectory(at: current.path)
                    record(removed: 1)
                } catch {
                    record(RemovalFailure(path: current.path, error: error), for: current.candidate)
                    isIncomplete = true
                }
            }
            guard let parent = current.parent else {
                finish(current.candidate, isIncomplete ? .incomplete : .removed)
                return
            }
            current = parent
        }
    }

    private func record(removed count: Int) {
        guard count > 0 else {
            return
        }
        state.withLock { $0.removedEntries += count }
    }

    private func record(_ failure: RemovalFailure, for index: Int) {
        state.withLock { $0.failures[index, default: []].append(failure) }
    }

    private func finish(_ index: Int, _ outcome: Outcome) {
        state.withLock { $0.outcomes[index] = outcome }
    }

    func progress(elapsed: Duration) -> CleanupProgress {
        let total = candidates.reduce(Optional(0)) { total, candidate in
            candidate.size.flatMap { size in total.map { $0 + size.files + size.directories } }
        }
        return state.withLock { state in
            CleanupProgress(
                candidates: candidates.count,
                finishedCandidates: state.outcomes.count,
                removedEntries: state.removedEntries,
                totalEntries: total,
                elapsed: elapsed
            )
        }
    }

    func result(duration: Duration) -> CleanupResult {
        state.withLock { state in
            var result = CleanupResult(removed: [], failures: [], notStarted: [], duration: duration)
            for (index, candidate) in candidates.enumerated() {
                switch state.outcomes[index] {
                case .removed?:
                    result.removed.append(candidate)
                case .changed?:
                    result.failures.append(CleanupFailure(candidate: candidate, reason: .changed))
                case .incomplete?:
                    let failures = state.failures[index, default: []].sorted { $0.path.string < $1.path.string }
                    result.failures.append(CleanupFailure(candidate: candidate, reason: .incomplete(failures)))
                case nil:
                    result.notStarted.append(candidate)
                }
            }
            return result
        }
    }
}
