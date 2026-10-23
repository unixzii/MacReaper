import Synchronization
import System

/// What a scan reports while it runs, from ``DiskScanner/events(every:)``.
public enum ScanEvent: Sendable {
    /// What happened since the previous update.
    case update(ScanUpdate)
    /// The complete result. Always the last event.
    case finished(ScanResult)
}

/// Changes since the previous update, coalesced so that a user interface applies them at most
/// once per interval.
public struct ScanUpdate: Sendable {

    /// Candidates found since the previous update, in the order found. Their sizes arrive later,
    /// in ``sized``.
    public var found: [Claim]
    /// Candidates whose size was measured since the previous update. Each candidate is sized
    /// once, and its size is final.
    public var sized: [SizedCandidate]
    public var progress: ScanProgress
}

/// A candidate's final size.
public struct SizedCandidate: Hashable, Sendable {

    public var path: FilePath
    public var size: CandidateSize
}

public enum ScanPhase: Hashable, Sendable {
    /// Directories are still being visited and candidates found. Sizing runs alongside.
    case detecting
    /// Every directory has been visited; candidates are still being sized.
    case sizing
    case finished
}

/// Running totals for a progress display.
public struct ScanProgress: Hashable, Sendable {

    public var phase: ScanPhase
    public var directories: Int
    public var files: Int
    public var candidates: Int
    public var sizedCandidates: Int
    /// The sum over sized candidates. A file hard-linked into two candidates counts in both here,
    /// but once in the result's total.
    public var allocated: UInt64
    /// A directory visited recently, to show what the scan is looking at.
    public var currentDirectory: FilePath?
    public var elapsed: Duration
}

/// Collects what workers report and hands it out in batches. Workers record after every piece
/// of work; the scan's ticker drains once per interval.
final class ScanReporter: Sendable {

    private struct State {

        var found: [Claim] = []
        var sized: [SizedCandidate] = []
        var progress: ScanProgress
        var hasChanges = false
    }

    private let state: Mutex<State>
    private let start = ContinuousClock.now

    init() {
        state = Mutex(State(progress: ScanProgress(
            phase: .detecting,
            directories: 0,
            files: 0,
            candidates: 0,
            sizedCandidates: 0,
            allocated: 0,
            currentDirectory: nil,
            elapsed: .zero
        )))
    }

    func record(
        found: ArraySlice<Claim>,
        sized: [SizedCandidate],
        directories: Int,
        files: Int,
        currentDirectory: FilePath?
    ) {
        guard !found.isEmpty || !sized.isEmpty || directories > 0 || files > 0 else {
            return
        }
        state.withLock { state in
            state.found += found
            state.sized += sized
            state.progress.directories += directories
            state.progress.files += files
            state.progress.candidates += found.count
            state.progress.sizedCandidates += sized.count
            state.progress.allocated += sized.reduce(0) { $0 + $1.size.allocated }
            if let currentDirectory {
                state.progress.currentDirectory = currentDirectory
            }
            state.hasChanges = true
        }
    }

    func detectionFinished() {
        state.withLock { state in
            state.progress.phase = .sizing
            state.hasChanges = true
        }
    }

    /// Everything recorded since the previous drain, or `nil` if nothing was.
    ///
    /// - Parameter isFinal: Marks the progress finished and reports it even without changes.
    func drain(isFinal: Bool = false) -> ScanUpdate? {
        let elapsed = ContinuousClock.now - start
        return state.withLock { state in
            if isFinal {
                state.progress.phase = .finished
                state.progress.currentDirectory = nil
            } else if !state.hasChanges {
                return nil
            }
            state.progress.elapsed = elapsed
            let update = ScanUpdate(found: state.found, sized: state.sized, progress: state.progress)
            state.found = []
            state.sized = []
            state.hasChanges = false
            return update
        }
    }
}
