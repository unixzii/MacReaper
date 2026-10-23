import ReaperFS
import ReaperRules
import System

/// A directory waiting to be visited, with everything learned about it from its parent.
struct WorkItem: Sendable {

    let path: FilePath
    let attributes: EntryAttributes
    let depth: Int
    let scopes: ScopeStack
    let siblings: DirectoryListing
    /// The device of the root this directory was reached from; directories on other devices
    /// are not entered.
    let rootDevice: Int32
}

/// Visits one directory at a time: lists it, evaluates it and its files, and returns the
/// subdirectories still to visit and the candidates to size. Holds no mutable state, so any
/// number of workers can share it.
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
                attributes: attributes,
                depth: 0,
                scopes: .empty,
                siblings: siblings,
                rootDevice: attributes.identity.device
            )
        }
    }

    /// Visits `item` and returns the work it leads to: its subdirectories to visit, and the
    /// candidates it found to size.
    func visit(_ item: WorkItem, into accumulator: inout ScanAccumulator) -> [Work] {
        if item.attributes.isDataless {
            accumulator.errors.append(ScanError(path: item.path, error: .dataless))
            return []
        }
        let children: DirectoryListing
        do {
            children = try fileSystem.listDirectory(at: item.path)
        } catch {
            accumulator.errors.append(ScanError(path: item.path, error: error))
            return []
        }
        accumulator.errors += children.failures.map { ScanError(path: item.path.appending($0.name), error: $0.error) }
        accumulator.stats.directories += 1

        let entry = EntryContext(
            path: item.path,
            attributes: item.attributes,
            depth: item.depth,
            children: children,
            siblings: item.siblings,
            scopes: item.scopes
        )
        let scopes: ScopeStack
        switch evaluator.evaluate(entry) {
        case .skip:
            accumulator.stats.skipped += 1
            return []
        case .claim(let claim):
            accumulator.candidates.append(claim)
            guard let sizeTracker else {
                return []
            }
            sizeTracker.begin(item.path.string)
            return [.sizeDirectory(item.path, candidate: item.path.string, device: item.rootDevice)]
        case .descend(let inner):
            scopes = inner
        }
        guard item.depth < rules.maxDepth else {
            return []
        }

        var next: [Work] = []
        var claimedFiles: [String] = []
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
                    depth: item.depth + 1,
                    children: nil,
                    siblings: children,
                    scopes: scopes
                )
                switch evaluator.evaluate(file) {
                case .claim(let claim):
                    accumulator.candidates.append(claim)
                    claimedFiles.append(child.name)
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
                    next.append(.visit(WorkItem(
                        path: FilePath(path),
                        attributes: child,
                        depth: item.depth + 1,
                        scopes: scopes,
                        siblings: children,
                        rootDevice: item.rootDevice
                    )))
                }
            }
        }
        if let sizeTracker, !claimedFiles.isEmpty {
            for name in claimedFiles {
                sizeTracker.begin(item.path.appending(name).string)
            }
            next.append(.sizeFiles(in: item.path, names: claimedFiles))
        }
        return next
    }

    private func isExcluded(_ path: String) -> Bool {
        !rules.exclude.isEmpty && rules.exclude.contains { $0.matches(path) }
    }
}
