import ReaperFS
import ReaperRules
import System

/// A directory waiting to be listed.
struct WorkItem: Sendable {

    enum Purpose: Sendable {
        /// Evaluate the directory and its files, with what its parent's listing told about it.
        case evaluate(attributes: EntryAttributes, depth: Int, scopes: ScopeStack, siblings: DirectoryListing)
        /// Add the directory up as part of the candidate at `candidate`, without evaluating it.
        case measure(candidate: String)
    }

    let path: FilePath
    /// The device of the root this directory was reached from; directories on other devices
    /// are not entered.
    let rootDevice: Int32
    let purpose: Purpose

    var isMeasuring: Bool {
        if case .measure = purpose { true } else { false }
    }
}

/// Visits one directory at a time and returns the subdirectories still to visit.
///
/// Outside candidates, a visit evaluates the directory and its files. A claimed directory is not
/// evaluated further: it and everything below it are added up as the candidate's size, from the
/// same listings. Holds no mutable state, so any number of workers can share it.
struct DirectoryVisitor: Sendable {

    let evaluator: EntryEvaluator
    /// Sizes the candidates found, unless the scan does not size candidates.
    let sizeTracker: SizeTracker?

    var fileSystem: any FileSystem {
        evaluator.fileSystem
    }

    var rules: CompiledRules {
        evaluator.rules
    }

    /// Sizing needs to know which files share blocks with clones.
    private var listingOptions: ListingOptions {
        sizeTracker == nil ? [] : .sharedBlocks
    }

    /// The scan roots as work items: resolved, with roots inside other roots dropped. A missing
    /// root is ignored; any other problem with one is recorded.
    func roots(into accumulator: inout ScanAccumulator) -> [WorkItem] {
        var resolved: [FilePath] = []
        for root in rules.roots {
            do {
                resolved.append(try fileSystem.resolvingSymlinks(FilePath(root)))
            } catch .notFound {
                continue
            } catch {
                accumulator.errors.append(ScanError(path: FilePath(root), error: error))
            }
        }
        let distinct = Set(resolved.map(\.string))
        let outermost = distinct.filter { root in !distinct.contains { root.hasPrefix($0 + "/") } }.sorted()

        return outermost.compactMap { root -> WorkItem? in
            let path = FilePath(root)
            guard let name = path.lastComponent?.string, !isExcluded(root) else {
                return nil
            }
            let siblings: DirectoryListing
            do throws(FSError) {
                siblings = try fileSystem.listDirectory(at: path.removingLastComponent())
            } catch {
                accumulator.errors.append(ScanError(path: path, error: error))
                return nil
            }
            guard let attributes = siblings.entries.first(where: { $0.name == name }), attributes.kind == .directory else {
                return nil
            }
            return WorkItem(
                path: path,
                rootDevice: attributes.identity.device,
                purpose: .evaluate(attributes: attributes, depth: 0, scopes: .empty, siblings: siblings)
            )
        }
    }

    /// Visits `item`.
    ///
    /// - Returns: The subdirectories to visit next, and the candidates whose sizes this visit
    ///   finished.
    func visit(_ item: WorkItem, into accumulator: inout ScanAccumulator) -> (next: [WorkItem], sized: [SizedCandidate]) {
        switch item.purpose {
        case .evaluate(let attributes, let depth, let scopes, let siblings):
            return evaluate(item, attributes: attributes, depth: depth, scopes: scopes, siblings: siblings, into: &accumulator)
        case .measure(let candidate):
            var listing: DirectoryListing?
            do {
                let read = try fileSystem.listDirectory(at: item.path, options: listingOptions)
                accumulator.errors += read.failures.map { ScanError(path: item.path.appending($0.name), error: $0.error) }
                listing = read
            } catch {
                accumulator.errors.append(ScanError(path: item.path, error: error))
            }
            return measure(listing, of: item.path, in: candidate, rootDevice: item.rootDevice)
        }
    }

    private func evaluate(
        _ item: WorkItem,
        attributes: EntryAttributes,
        depth: Int,
        scopes inherited: ScopeStack,
        siblings: DirectoryListing,
        into accumulator: inout ScanAccumulator
    ) -> (next: [WorkItem], sized: [SizedCandidate]) {
        if attributes.isDataless {
            accumulator.errors.append(ScanError(path: item.path, error: .dataless))
            return ([], [])
        }
        let children: DirectoryListing
        do {
            children = try fileSystem.listDirectory(at: item.path, options: listingOptions)
        } catch {
            accumulator.errors.append(ScanError(path: item.path, error: error))
            return ([], [])
        }
        accumulator.errors += children.failures.map { ScanError(path: item.path.appending($0.name), error: $0.error) }
        accumulator.stats.directories += 1

        let entry = EntryContext(
            path: item.path,
            attributes: attributes,
            depth: depth,
            children: children,
            siblings: siblings,
            scopes: inherited
        )
        let scopes: ScopeStack
        switch evaluator.evaluate(entry) {
        case .skip:
            accumulator.stats.skipped += 1
            return ([], [])
        case .claim(let claim):
            accumulator.candidates.append(claim)
            guard let sizeTracker else {
                return ([], [])
            }
            // The listing just made is the first part of the candidate's size.
            sizeTracker.begin(item.path.string)
            return measure(children, of: item.path, in: item.path.string, rootDevice: item.rootDevice)
        case .descend(let inner):
            scopes = inner
        }
        guard depth < rules.maxDepth else {
            return ([], [])
        }

        var next: [WorkItem] = []
        var sized: [SizedCandidate] = []
        let directory = item.path.string
        for child in children.entries {
            // Built as a string: a `FilePath` is needed only for the directories still to visit.
            let path = directory == "/" ? "/" + child.name : directory + "/" + child.name
            switch child.kind {
            case .symlink:
                accumulator.stats.symlinks += 1
            case .other:
                continue
            case .file:
                if isExcluded(path) {
                    accumulator.stats.excluded += 1
                    continue
                }
                accumulator.stats.files += 1
                let file = EntryContext(
                    pathString: path,
                    attributes: child,
                    depth: depth + 1,
                    children: nil,
                    siblings: children,
                    scopes: scopes
                )
                switch evaluator.evaluate(file) {
                case .claim(let claim):
                    accumulator.candidates.append(claim)
                    if let sizeTracker {
                        // The listing has everything a claimed file's size needs.
                        var measurement = SizeTracker.Measurement()
                        measurement.addFile(child)
                        sizeTracker.begin(path)
                        if let size = sizeTracker.record(measurement, for: path, followUps: 0) {
                            sized.append(SizedCandidate(path: claim.path, size: size))
                        }
                    }
                case .skip:
                    accumulator.stats.skipped += 1
                case .descend:
                    break
                }
            case .directory:
                if child.identity.device != item.rootDevice {
                    accumulator.stats.otherVolumes += 1
                } else if isExcluded(path) {
                    accumulator.stats.excluded += 1
                } else {
                    next.append(WorkItem(
                        path: FilePath(path),
                        rootDevice: item.rootDevice,
                        purpose: .evaluate(attributes: child, depth: depth + 1, scopes: scopes, siblings: children)
                    ))
                }
            }
        }
        return (next, sized)
    }

    /// Adds what `listing` holds to the candidate at `candidate`: its files, and its
    /// subdirectories as more directories to measure. Symlinks are not followed, and
    /// directories on another volume are left out, because cleanup does not cross into them
    /// either. A missing listing, or entries it could not read, make the size incomplete.
    private func measure(
        _ listing: DirectoryListing?,
        of path: FilePath,
        in candidate: String,
        rootDevice: Int32
    ) -> (next: [WorkItem], sized: [SizedCandidate]) {
        var measurement = SizeTracker.Measurement()
        var next: [WorkItem] = []
        if let listing {
            measurement.size.directories = 1
            measurement.size.isComplete = listing.failures.isEmpty
            for entry in listing.entries {
                switch entry.kind {
                case .file:
                    measurement.addFile(entry)
                case .directory where entry.identity.device == rootDevice:
                    next.append(WorkItem(path: path.appending(entry.name), rootDevice: rootDevice, purpose: .measure(candidate: candidate)))
                case .directory, .symlink, .other:
                    continue
                }
            }
        } else {
            measurement.size.isComplete = false
        }
        let size = sizeTracker!.record(measurement, for: candidate, followUps: next.count)
        return (next, size.map { [SizedCandidate(path: FilePath(candidate), size: $0)] } ?? [])
    }

    private func isExcluded(_ path: String) -> Bool {
        !rules.exclude.isEmpty && rules.exclude.contains { $0.matches(path) }
    }
}
