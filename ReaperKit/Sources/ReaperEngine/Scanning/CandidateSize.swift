import ReaperFS
import Synchronization

/// How big a candidate is, and how much deleting it would free.
public struct CandidateSize: Hashable, Sendable {

    /// Bytes allocated by the files inside, each hard-linked file counted once.
    public var allocated: UInt64 = 0
    /// Bytes deleting the candidate would free right away. Less than `allocated` where files
    /// share blocks with clones or snapshots, or have hard links outside the candidate. `nil`
    /// when the scan did not measure it.
    public var reclaimable: UInt64?
    public var files = 0
    /// Directories inside, the candidate itself included.
    public var directories = 0
    /// `false` when part of the candidate could not be read; the sizes are then lower bounds.
    public var isComplete = true

    public init(
        allocated: UInt64 = 0,
        reclaimable: UInt64? = nil,
        files: Int = 0,
        directories: Int = 0,
        isComplete: Bool = true
    ) {
        self.allocated = allocated
        self.reclaimable = reclaimable
        self.files = files
        self.directories = directories
        self.isComplete = isComplete
    }

    mutating func add(_ other: CandidateSize) {
        allocated += other.allocated
        if let otherReclaimable = other.reclaimable {
            reclaimable = (reclaimable ?? 0) + otherReclaimable
        }
        files += other.files
        directories += other.directories
        isComplete = isComplete && other.isComplete
    }
}

/// How much sizing a scan does.
public enum Sizing: Sendable {
    /// Candidates carry no size.
    case none
    /// Allocated sizes only.
    case allocated
    /// Allocated and reclaimable sizes. Listing candidates takes about 60% longer, because
    /// reclaimable sizes need each file's private size.
    case allocatedAndReclaimable
}

/// Collects sizes as workers measure them, and finishes a candidate's size as soon as the last
/// piece of work inside it is done, so sizes can be reported while the scan goes on.
///
/// A candidate starts with one piece of outstanding work. Each piece that finishes adds what it
/// measured and the number of pieces it queued in turn; when none are outstanding, the size is
/// final. Hard-linked files are set aside until then: a candidate counts each one once, and as
/// reclaimable only if every link to it lies inside the candidate.
final class SizeTracker: Sendable {

    struct HardLinkSighting {

        let identity: FileIdentity
        let linkCount: UInt32
        let allocated: UInt64
        let reclaimable: UInt64
    }

    /// What one piece of sizing work measured for one candidate.
    struct Measurement {

        /// Everything except hard-linked files. Always measures reclaimable bytes;
        /// ``SizeTracker`` drops them when the scan did not ask for them.
        var size = CandidateSize(reclaimable: 0)
        var hardLinks: [HardLinkSighting] = []

        mutating func addFile(_ file: EntryAttributes) {
            size.files += 1
            let reclaimable = file.privateSize ?? file.allocatedSize
            if file.linkCount > 1 {
                hardLinks.append(HardLinkSighting(
                    identity: file.identity,
                    linkCount: file.linkCount,
                    allocated: file.allocatedSize,
                    reclaimable: reclaimable
                ))
            } else {
                size.allocated += file.allocatedSize
                size.reclaimable! += reclaimable
            }
        }

        mutating func add(_ other: Measurement) {
            size.add(other.size)
            hardLinks += other.hardLinks
        }
    }

    private struct State {

        var inProgress: [String: (measurement: Measurement, outstanding: Int)] = [:]
        var finished: [String: Measurement] = [:]
    }

    private let state = Mutex(State())
    private let measuresReclaimable: Bool

    init(measuresReclaimable: Bool) {
        self.measuresReclaimable = measuresReclaimable
    }

    func begin(_ candidate: String) {
        state.withLock { $0.inProgress[candidate] = (Measurement(), 1) }
    }

    /// Adds what one piece of work measured for `candidate`, and the pieces it queued in turn.
    ///
    /// - Returns: The candidate's final size, when this was its last outstanding piece.
    func record(_ measurement: Measurement, for candidate: String, followUps: Int) -> CandidateSize? {
        let finished = state.withLock { state -> Measurement? in
            guard var progress = state.inProgress[candidate] else {
                return nil
            }
            progress.measurement.add(measurement)
            progress.outstanding += followUps - 1
            guard progress.outstanding == 0 else {
                state.inProgress[candidate] = progress
                return nil
            }
            state.inProgress[candidate] = nil
            state.finished[candidate] = progress.measurement
            return progress.measurement
        }
        return finished.map(resolve)
    }

    /// The final size of every finished candidate, by path.
    func sizes() -> [String: CandidateSize] {
        state.withLock { $0.finished }.mapValues(resolve)
    }

    /// All finished candidates together. Each hard-linked file counts once, and as reclaimable
    /// if every link to it lies inside some candidate.
    func total() -> CandidateSize {
        let finished = state.withLock { $0.finished }
        var total = Measurement()
        for measurement in finished.values {
            total.add(measurement)
        }
        return resolve(total)
    }

    private func resolve(_ measurement: Measurement) -> CandidateSize {
        var size = measurement.size
        for sightings in Dictionary(grouping: measurement.hardLinks, by: \.identity).values {
            let file = sightings[0]
            size.allocated += file.allocated
            if sightings.count >= Int(file.linkCount) {
                size.reclaimable! += file.reclaimable
            }
        }
        if !measuresReclaimable {
            size.reclaimable = nil
        }
        return size
    }
}
