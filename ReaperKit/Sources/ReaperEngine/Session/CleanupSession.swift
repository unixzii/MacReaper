import Observation

/// One cleanup, as state a SwiftUI view can show: progress while it runs, then what it did.
@MainActor
@Observable
public final class CleanupSession {

    public enum State {
        case running
        case finished(CleanupResult)
    }

    public let cleanup: Cleanup
    /// What the cleanup deletes, in order.
    public let candidates: [Claim]
    public let updateInterval: Duration

    public private(set) var state: State = .running
    /// `nil` until the first update arrives.
    public private(set) var progress: CleanupProgress?
    /// Whether ``stop()`` was called; candidates already started are still being finished.
    public private(set) var isStopping = false

    @ObservationIgnored
    private var task: Task<Void, Never>?

    /// Starts deleting `candidates` right away.
    public init(candidates: [Claim], cleanup: Cleanup = Cleanup(), updateInterval: Duration = .milliseconds(100)) {
        self.cleanup = cleanup
        self.candidates = candidates
        self.updateInterval = updateInterval
        task = Task { [weak self, cleanup, candidates, updateInterval] in
            let result = await cleanup.run(candidates, reportingEvery: updateInterval) { progress in
                Task { @MainActor in
                    if self?.isRunning == true {
                        self?.progress = progress
                    }
                }
            }
            self?.state = .finished(result)
        }
    }

    public var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// Starts no more candidates, and finishes those already started.
    public func stop() {
        guard isRunning else {
            return
        }
        isStopping = true
        task?.cancel()
    }

    /// Waits until the cleanup has finished.
    public func waitUntilDone() async {
        await task?.value
    }
}
