import Foundation
import ReaperFS
import ReaperRules
import Synchronization
import System

/// Walks a profile's roots and collects every entry its rules claim.
///
/// The walk runs on dedicated threads rather than in Swift concurrency's cooperative pool:
/// listing directories blocks on disk I/O, and blocking the pool's few threads would stall
/// every other task in the app.
public struct DiskScanner: Sendable {

    public let evaluator: EntryEvaluator
    public let sizing: Sizing
    public let workerCount: Int

    /// - Parameters:
    ///   - now: The time `olderThan` conditions measure from.
    ///   - sizing: How much to measure about each candidate.
    ///   - workerCount: Threads that list, evaluate and size directories in parallel.
    public init(
        rules: CompiledRules,
        fileSystem: any FileSystem,
        now: Date = .now,
        sizing: Sizing = .allocatedAndReclaimable,
        workerCount: Int = DiskScanner.defaultWorkerCount
    ) {
        self.evaluator = EntryEvaluator(rules: rules, fileSystem: fileSystem, now: now)
        self.sizing = sizing
        self.workerCount = max(1, workerCount)
    }

    /// Three workers for every four cores.
    ///
    /// Listing is mostly kernel work, and past a point more threads only contend in the kernel.
    /// Measured on a Mac with 5 performance and 6 efficiency cores, 8 workers rather than 11
    /// found candidates as fast with 30% less CPU time, and measured reclaimable sizes about 4%
    /// faster with 40% less. Allocated sizes alone came out about 6% slower.
    public static var defaultWorkerCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount * 3 / 4)
    }

    /// Scans every root of the profile.
    ///
    /// The result does not depend on the number of workers or on the order in which the file
    /// system lists directories.
    ///
    /// - Throws: `CancellationError` if the task is cancelled; the partial result is discarded.
    public func scan() async throws -> ScanResult {
        try await run(reporter: nil)
    }

    /// Scans every root of the profile, reporting candidates, sizes and progress as they come.
    ///
    /// Updates are coalesced and sent at most once per `interval`, and only when something
    /// changed, so a user interface can apply each one as it arrives. The last event is always
    /// ``ScanEvent/finished(_:)``, with the same result ``scan()`` returns. Ending the iteration
    /// early, or cancelling the task iterating, cancels the scan.
    public func events(every interval: Duration = .milliseconds(100)) -> AsyncThrowingStream<ScanEvent, any Error> {
        AsyncThrowingStream { continuation in
            let reporter = ScanReporter(measuresReclaimable: sizing == .allocatedAndReclaimable)
            let scan = Task {
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: interval)
                        if let update = reporter.drain() {
                            continuation.yield(.update(update))
                        }
                    }
                }
                do {
                    let result = try await run(reporter: reporter)
                    ticker.cancel()
                    await ticker.value
                    if let update = reporter.drain(isFinal: true) {
                        continuation.yield(.update(update))
                    }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    ticker.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                scan.cancel()
            }
        }
    }

    private func run(reporter: ScanReporter?) async throws -> ScanResult {
        let clock = ContinuousClock()
        let start = clock.now
        let sizeTracker = sizing == .none ? nil : SizeTracker(measuresReclaimable: sizing == .allocatedAndReclaimable)
        let visitor = DirectoryVisitor(evaluator: evaluator, sizeTracker: sizeTracker)
        let sizer = sizeTracker.map { CandidateSizer(fileSystem: evaluator.fileSystem, sizing: sizing, tracker: $0) }
        let queue = WorkQueue()
        let collected = Collected()

        var rootAccumulator = ScanAccumulator()
        queue.push(visitor.roots(into: &rootAccumulator).map(Work.visit))
        collected.add(rootAccumulator)

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let group = DispatchGroup()
                for index in 0..<workerCount {
                    group.enter()
                    let thread = Thread {
                        DarwinFileSystem.disableDatalessMaterializationOnCurrentThread()
                        var accumulator = ScanAccumulator()
                        while let work = queue.next() {
                            let foundBefore = accumulator.candidates.count
                            let statsBefore = accumulator.stats
                            var sized: [SizedCandidate] = []
                            var visited: FilePath?
                            switch work {
                            case .visit(let item):
                                queue.push(visitor.visit(item, into: &accumulator))
                                visited = item.path
                            // Sizing work exists only when the scan sizes candidates, so `sizer` is set.
                            case .sizeDirectory(let path, let candidate, let device):
                                let (next, finished) = sizer!.sizeDirectory(path, candidate: candidate, device: device, into: &accumulator)
                                queue.push(next)
                                sized += finished.map { [$0] } ?? []
                            case .sizeFiles(let directory, let names):
                                sized += sizer!.sizeFiles(in: directory, names: names, into: &accumulator)
                            }
                            reporter?.record(
                                found: accumulator.candidates[foundBefore...],
                                sized: sized,
                                directories: accumulator.stats.directories - statsBefore.directories,
                                files: accumulator.stats.files - statsBefore.files,
                                currentDirectory: visited
                            )
                            if queue.finish(work) {
                                reporter?.detectionFinished()
                            }
                        }
                        collected.add(accumulator)
                        group.leave()
                    }
                    thread.name = "MacReaper scan worker \(index)"
                    thread.qualityOfService = .userInitiated
                    thread.start()
                }
                group.notify(queue: .global()) {
                    continuation.resume()
                }
            }
        } onCancel: {
            queue.cancel()
        }
        try Task.checkCancellation()
        return collected.result(duration: clock.now - start, sizes: sizeTracker)
    }
}

/// The workers' accumulators, gathered as each worker finishes.
private final class Collected: Sendable {

    private let accumulator = Mutex(ScanAccumulator())

    func add(_ other: ScanAccumulator) {
        accumulator.withLock { $0.add(other) }
    }

    func result(duration: Duration, sizes: SizeTracker?) -> ScanResult {
        accumulator.withLock { $0.result(duration: duration, sizes: sizes) }
    }
}
