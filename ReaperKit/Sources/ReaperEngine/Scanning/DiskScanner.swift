import Foundation
import ReaperFS
import ReaperRules
import Synchronization
import System

/// Walks a root directory and collects every entry the rules claim. The walk stays on the root's
/// volume: directories on other volumes are not entered.
///
/// The walk runs on dedicated threads rather than in Swift concurrency's cooperative pool:
/// listing directories blocks on disk I/O, and blocking the pool's few threads would stall
/// every other task in the app.
public struct DiskScanner: Sendable {

    public let evaluator: EntryEvaluator
    public let root: FilePath
    /// Whether candidates are sized: everything inside them listed, and added up.
    public let sizesCandidates: Bool
    public let workerCount: Int

    /// - Parameters:
    ///   - root: The directory to scan. It must have a parent, so it cannot be `/`.
    ///   - now: The time `olderThan` conditions measure from.
    ///   - sizesCandidates: Whether to size candidates, which lists everything inside them.
    ///   - workerCount: Threads that list, evaluate and size directories in parallel.
    public init(
        rules: CompiledRules,
        root: FilePath,
        fileSystem: any FileSystem,
        now: Date = .now,
        sizesCandidates: Bool = true,
        workerCount: Int = DiskScanner.defaultWorkerCount
    ) {
        self.evaluator = EntryEvaluator(rules: rules, fileSystem: fileSystem, now: now)
        self.root = root
        self.sizesCandidates = sizesCandidates
        self.workerCount = max(1, workerCount)
    }

    /// Three workers for every four cores.
    ///
    /// Listing is mostly kernel work, and past a point more threads only contend in the kernel.
    /// Measured on a Mac with 5 performance and 6 efficiency cores, 8 workers rather than 11
    /// scanned about as fast with 30–40% less CPU time.
    public static var defaultWorkerCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount * 3 / 4)
    }

    /// Scans the root.
    ///
    /// The result does not depend on the number of workers or on the order in which the file
    /// system lists directories.
    ///
    /// - Throws: `CancellationError` if the task is cancelled; the partial result is discarded.
    public func scan() async throws -> ScanResult {
        try await run(reporter: nil)
    }

    /// Scans the root, reporting candidates, sizes and progress as they come.
    ///
    /// Updates are coalesced and sent at most once per `interval`, and only when something
    /// changed, so a user interface can apply each one as it arrives. The last event is always
    /// ``ScanEvent/finished(_:)``, with the same result ``scan()`` returns. Ending the iteration
    /// early, or cancelling the task iterating, cancels the scan.
    public func events(every interval: Duration = .milliseconds(100)) -> AsyncThrowingStream<ScanEvent, any Error> {
        AsyncThrowingStream { continuation in
            let reporter = ScanReporter()
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
        let sizeTracker = sizesCandidates ? SizeTracker() : nil
        let visitor = DirectoryVisitor(evaluator: evaluator, root: root, sizeTracker: sizeTracker)
        let queue = WorkQueue()
        let collected = Collected()

        var rootAccumulator = ScanAccumulator()
        queue.push(visitor.rootItem(into: &rootAccumulator).map { [$0] } ?? [])
        collected.add(rootAccumulator)

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let group = DispatchGroup()
                for index in 0..<workerCount {
                    group.enter()
                    let thread = Thread {
                        DarwinFileSystem.disableDatalessMaterializationOnCurrentThread()
                        var accumulator = ScanAccumulator()
                        while let item = queue.next() {
                            let foundBefore = accumulator.candidates.count
                            let statsBefore = accumulator.stats
                            let (next, sized) = visitor.visit(item, into: &accumulator)
                            queue.push(next)
                            reporter?.record(
                                found: accumulator.candidates[foundBefore...],
                                sized: sized,
                                directories: accumulator.stats.directories - statsBefore.directories,
                                files: accumulator.stats.files - statsBefore.files,
                                currentDirectory: item.isMeasuring ? nil : item.path
                            )
                            if queue.finish(item) {
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
