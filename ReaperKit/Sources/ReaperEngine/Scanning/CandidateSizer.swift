import ReaperFS
import System

/// Adds up candidates: lists what is inside them, without evaluating rules, and hands what it
/// measured to the scan's ``SizeTracker``. Like the visitor, it holds no mutable state.
struct CandidateSizer: Sendable {

    let fileSystem: any FileSystem
    let options: ListingOptions
    let tracker: SizeTracker

    init(fileSystem: any FileSystem, sizing: Sizing, tracker: SizeTracker) {
        self.fileSystem = fileSystem
        self.options = sizing == .allocatedAndReclaimable ? .privateSize : []
        self.tracker = tracker
    }

    /// Adds up the directory at `path`. Symlinks are not followed, and directories on another
    /// volume are left out, because cleanup does not cross into them either.
    ///
    /// - Returns: The subdirectories to size next, and the candidate's size if this directory
    ///   was the last part of it still being measured.
    func sizeDirectory(
        _ path: FilePath,
        candidate: String,
        device: Int32,
        into accumulator: inout ScanAccumulator
    ) -> (next: [Work], finished: SizedCandidate?) {
        var measurement = SizeTracker.Measurement()
        var next: [Work] = []
        do {
            let listing = try fileSystem.listDirectory(at: path, options: options)
            measurement.size.directories = 1
            if !listing.failures.isEmpty {
                accumulator.errors += listing.failures.map { ScanError(path: path.appending($0.name), error: $0.error) }
                measurement.size.isComplete = false
            }
            for entry in listing.entries {
                switch entry.kind {
                case .file:
                    measurement.addFile(entry)
                case .directory where entry.identity.device == device:
                    next.append(.sizeDirectory(path.appending(entry.name), candidate: candidate, device: device))
                case .directory, .symlink, .other:
                    continue
                }
            }
        } catch {
            accumulator.errors.append(ScanError(path: path, error: error))
            measurement.size.isComplete = false
        }
        let size = tracker.record(measurement, for: candidate, followUps: next.count)
        return (next, size.map { SizedCandidate(path: FilePath(candidate), size: $0) })
    }

    /// Sizes claimed files, which the detection listing saw without their private sizes. Each
    /// file is its own candidate.
    ///
    /// - Returns: The files' sizes.
    func sizeFiles(in directory: FilePath, names: [String], into accumulator: inout ScanAccumulator) -> [SizedCandidate] {
        var measurements = Dictionary(uniqueKeysWithValues: names.map { ($0, SizeTracker.Measurement()) })
        do {
            let listing = try fileSystem.listDirectory(at: directory, options: options)
            for entry in listing.entries where measurements[entry.name] != nil {
                measurements[entry.name]!.addFile(entry)
            }
        } catch {
            accumulator.errors.append(ScanError(path: directory, error: error))
            for name in names {
                measurements[name]!.size.isComplete = false
            }
        }
        return names.compactMap { name in
            let path = directory.appending(name)
            return tracker.record(measurements[name]!, for: path.string, followUps: 0)
                .map { SizedCandidate(path: path, size: $0) }
        }
    }
}
