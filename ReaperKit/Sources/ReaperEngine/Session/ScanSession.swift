import Observation
import System

/// One scan, as state a SwiftUI view can show: candidates appear as they are found, their sizes
/// fill in as they are measured, and progress updates while the scan runs.
@MainActor
@Observable
public final class ScanSession {

    public enum State {
        case idle
        case scanning
        case finished(ScanResult)
        case cancelled
        case failed(any Error)
    }

    public let scanner: DiskScanner
    public let updateInterval: Duration

    public private(set) var state: State = .idle
    /// In the order found while scanning; sorted by path once the scan finishes. Candidates
    /// cleanup deleted are dropped.
    public private(set) var candidates: [Claim] = []
    /// `nil` until the first update arrives.
    public private(set) var progress: ScanProgress?

    @ObservationIgnored
    private var indexByPath: [FilePath: Int] = [:]
    @ObservationIgnored
    private var task: Task<Void, Never>?

    public init(scanner: DiskScanner, updateInterval: Duration = .milliseconds(100)) {
        self.scanner = scanner
        self.updateInterval = updateInterval
    }

    public var isScanning: Bool {
        if case .scanning = state { true } else { false }
    }

    /// Starts a scan, discarding the previous one's candidates. Does nothing while scanning.
    public func start() {
        guard !isScanning else {
            return
        }
        state = .scanning
        candidates = []
        progress = nil
        indexByPath = [:]
        let events = scanner.events(every: updateInterval)
        task = Task { [weak self] in
            do {
                for try await event in events {
                    self?.apply(event)
                }
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = .failed(error)
            }
            // A stream whose consumer was cancelled ends without an error.
            if self?.isScanning == true {
                self?.state = .cancelled
            }
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
    }

    /// Drops candidates that are gone, after cleanup deleted them. The finished state's result
    /// still describes the scan as it ran.
    public func discard(_ paths: Set<FilePath>) {
        guard !isScanning, !paths.isEmpty else {
            return
        }
        candidates.removeAll { paths.contains($0.path) }
        indexByPath = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.path, $0) })
    }

    /// Waits until the current scan has finished, failed or been cancelled.
    public func waitUntilDone() async {
        await task?.value
    }

    private func apply(_ event: ScanEvent) {
        switch event {
        case .update(let update):
            for claim in update.found {
                indexByPath[claim.path] = candidates.count
                candidates.append(claim)
            }
            for sized in update.sized {
                if let index = indexByPath[sized.path] {
                    candidates[index].size = sized.size
                }
            }
            progress = update.progress
        case .finished(let result):
            candidates = result.candidates
            indexByPath = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.path, $0) })
            state = .finished(result)
        }
    }
}
