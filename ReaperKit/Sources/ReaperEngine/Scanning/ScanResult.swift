import ReaperFS
import System

/// Everything a scan found.
public struct ScanResult: Sendable {

    /// Sorted by path. No candidate lies inside another.
    public var candidates: [Claim]
    /// All candidates together, with each hard-linked file counted once; `nil` when the scan
    /// does not size candidates.
    public var totalSize: CandidateSize?
    /// Sorted by path.
    public var errors: [ScanError]
    public var stats: ScanStats
}

/// A directory or entry the scan could not read. The scan carries on without it.
public struct ScanError: Hashable, Sendable {

    public var path: FilePath
    public var error: FSError
}

public struct ScanStats: Hashable, Sendable {

    /// Directories listed and evaluated.
    public var directories = 0
    /// Files evaluated.
    public var files = 0
    /// Entries a rule skipped.
    public var skipped = 0
    /// Symlinks seen and not followed.
    public var symlinks = 0
    /// Directories on another volume than the root, not entered.
    public var otherVolumes = 0
    public var duration: Duration = .zero

    mutating func add(_ other: ScanStats) {
        directories += other.directories
        files += other.files
        skipped += other.skipped
        symlinks += other.symlinks
        otherVolumes += other.otherVolumes
    }
}

/// What one worker collected. Workers never share one, so collecting takes no locks.
struct ScanAccumulator {

    var candidates: [Claim] = []
    var errors: [ScanError] = []
    var stats = ScanStats()

    mutating func add(_ other: ScanAccumulator) {
        candidates += other.candidates
        errors += other.errors
        stats.add(other.stats)
    }

    /// The result, sorted so that it does not depend on which worker found what.
    func result(duration: Duration, sizes: SizeTracker?) -> ScanResult {
        var stats = stats
        stats.duration = duration
        var candidates = candidates.sorted { $0.path.string < $1.path.string }
        var totalSize: CandidateSize?
        if let sizes {
            let byPath = sizes.sizes()
            for index in candidates.indices {
                candidates[index].size = byPath[candidates[index].path.string]
            }
            totalSize = sizes.total()
        }
        return ScanResult(
            candidates: candidates,
            totalSize: totalSize,
            errors: errors.sorted { ($0.path.string, "\($0.error)") < ($1.path.string, "\($1.error)") },
            stats: stats
        )
    }
}
