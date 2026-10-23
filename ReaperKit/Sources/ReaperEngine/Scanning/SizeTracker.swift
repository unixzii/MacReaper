import ReaperFS
import Synchronization
import System

/// Collects sizes as workers measure them, and finishes a candidate's size as soon as the last
/// directory inside it is measured, so sizes can be reported while the scan goes on.
///
/// A candidate starts with one directory outstanding. Each directory measured adds what it
/// holds and the number of subdirectories it queued in turn; when none are outstanding, the size
/// is final. Hard-linked files are set aside until then: a candidate counts each one once, and
/// knows only then whether all its links are inside.
final class SizeTracker: Sendable {

    /// What one directory, or one claimed file, holds.
    struct Measurement {

        var size = CandidateSize()
        var hardLinks: [HardLink] = []

        mutating func addFile(_ file: EntryAttributes) {
            size.files += 1
            if file.linkCount > 1 {
                hardLinks.append(HardLink(
                    identity: file.identity,
                    linkCount: file.linkCount,
                    allocated: file.allocatedSize,
                    sharesBlocks: file.sharesBlocks ?? false
                ))
            } else {
                size.addFile(allocated: file.allocatedSize, sharesBlocks: file.sharesBlocks ?? false)
            }
        }

        mutating func add(_ other: Measurement) {
            size.add(other.size)
            hardLinks += other.hardLinks
        }

        /// The size, with each hard-linked file counted once.
        var resolved: CandidateSize {
            var size = size
            for links in Dictionary(grouping: hardLinks, by: \.identity).values {
                let file = links[0]
                if links.count < Int(file.linkCount) {
                    size.allocated += file.allocated
                    size.hardLinkedBytes += file.allocated
                    size.hardLinkedFiles += 1
                } else {
                    size.addFile(allocated: file.allocated, sharesBlocks: file.sharesBlocks)
                }
            }
            return size
        }
    }

    /// One link to a hard-linked file.
    struct HardLink {

        let identity: FileIdentity
        let linkCount: UInt32
        let allocated: UInt64
        let sharesBlocks: Bool
    }

    private struct State {

        var inProgress: [String: (measurement: Measurement, outstanding: Int)] = [:]
        var finished: [String: (measurement: Measurement, size: CandidateSize)] = [:]
    }

    private let state = Mutex(State())

    func begin(_ candidate: String) {
        state.withLock { $0.inProgress[candidate] = (Measurement(), 1) }
    }

    /// Adds what one directory of `candidate` holds, and the number of subdirectories it queued.
    ///
    /// - Returns: The candidate's final size, when this was its last outstanding directory.
    func record(_ measurement: Measurement, for candidate: String, followUps: Int) -> CandidateSize? {
        let finished = state.withLock { state -> Measurement? in
            // Taken out rather than copied, so adding to its hard links does not copy them all.
            guard var progress = state.inProgress.removeValue(forKey: candidate) else {
                return nil
            }
            progress.measurement.add(measurement)
            progress.outstanding += followUps - 1
            guard progress.outstanding == 0 else {
                state.inProgress[candidate] = progress
                return nil
            }
            return progress.measurement
        }
        guard let finished else {
            return nil
        }
        let size = finished.resolved
        state.withLock { $0.finished[candidate] = (finished, size) }
        return size
    }

    /// The final size of every finished candidate, by path.
    func sizes() -> [String: CandidateSize] {
        state.withLock { $0.finished }.mapValues(\.size)
    }

    /// All finished candidates together. A file hard-linked into several of them counts once,
    /// and as held only if a link lies outside all of them.
    func total() -> CandidateSize {
        var total = Measurement()
        for (measurement, _) in state.withLock({ $0.finished }).values {
            total.add(measurement)
        }
        return total.resolved
    }
}
