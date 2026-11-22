import Foundation
import Observation
import ReaperEngine
import ReaperFS
import ReaperRules
import System

/// What the sidebar narrows the candidate table to.
enum CandidateFilter: Hashable {
    case all
    case marked
    case category(CategoryID)
    
    var isCategorized: Bool {
        switch self {
        case .all, .marked:
            return false
        default:
            return true
        }
    }
}

/// One category in the sidebar, with what was found in it so far.
struct CategorySummary: Identifiable {

    let category: CompiledCategory
    var count = 0
    var bytes: UInt64 = 0

    var id: CategoryID {
        category.id
    }
}

/// The scan window's state: where to scan, the current scan, and the candidates the user
/// marked for cleanup.
@Observable
final class ScanModel {

    let library: RuleLibrary
    /// The places to scan from: the standard ones, then folders the user chose.
    private(set) var locations: [ScanLocation]
    @ObservationIgnored
    private let fileSystem: any FileSystem
    /// The user's home folder, for folders they choose to scan.
    @ObservationIgnored
    private let userHome: FilePath

    /// Choosing another location discards the previous location's results.
    var location: ScanLocation {
        didSet {
            guard location != oldValue else {
                return
            }
            UserDefaults.standard.set(location.root.string, forKey: Self.locationKey)
            if !isScanning, !isCleaning {
                session = nil
                cleanup = nil
            }
        }
    }

    /// `nil` until the first scan.
    private(set) var session: ScanSession?
    /// The latest cleanup of the current scan's candidates, until the next scan.
    private(set) var cleanup: CleanupSession?
    var filter = CandidateFilter.all
    var searchText = ""
    var selection: Set<FilePath> = []
    var sort = CandidateSort(column: .size, ascending: false)
    /// Marks the user changed. Every other candidate is marked if its category is preselected.
    private var markOverrides: [FilePath: Bool] = [:]

    private static let locationKey = "location"
    /// How often a scan or cleanup reports progress. Once a second keeps the window calm, and
    /// keeps a large table from being re-sorted many times a second.
    private static let updateInterval = Duration.seconds(1)

    /// - Parameters:
    ///   - home: The user's home folder.
    ///   - locations: The places to offer; the first is the default.
    init(library: RuleLibrary, fileSystem: any FileSystem, home: FilePath, locations: [ScanLocation]) {
        self.library = library
        self.fileSystem = fileSystem
        userHome = home
        self.locations = locations
        location = locations[0]
        if let saved = UserDefaults.standard.string(forKey: Self.locationKey).map { FilePath($0) } {
            if let known = locations.first(where: { $0.root == saved }) {
                location = known
            } else if fileSystem.exists(at: saved) {
                chooseFolder(saved)
            }
        }
    }

    /// Adds `folder` to the locations, unless it is one, and scans from it from now on.
    func chooseFolder(_ folder: FilePath) {
        if let known = locations.first(where: { $0.root == folder }) {
            location = known
            return
        }
        let chosen = ScanLocation(folder: folder, home: userHome)
        locations.append(chosen)
        location = chosen
    }

    /// The home folder as the current location's paths spell it.
    var home: FilePath {
        location.home
    }

    var isScanning: Bool {
        session?.isScanning ?? false
    }

    var isCleaning: Bool {
        cleanup?.isRunning ?? false
    }

    var canScan: Bool {
        guard !isScanning, !isCleaning, case .success = library.rules else {
            return false
        }
        return true
    }

    /// Scans from the chosen location, discarding the previous results and marks.
    func scan() {
        guard canScan, case .success(let loaded) = library.rules else {
            return
        }
        markOverrides = [:]
        selection = []
        filter = .all
        cleanup = nil
        // A new scanner per scan, so `olderThan` conditions measure from now.
        let rules = CompiledRules(loaded, home: location.home.string)
        let session = ScanSession(
            scanner: DiskScanner(rules: rules, root: location.root, fileSystem: fileSystem),
            updateInterval: Self.updateInterval
        )
        self.session = session
        session.start()
    }

    /// Stops the scan, or the cleanup once the candidates it has started are deleted.
    func stop() {
        if isCleaning {
            cleanup?.stop()
        } else {
            session?.cancel()
        }
    }

    // MARK: - Cleanup

    /// The candidates the window asks to confirm deleting, until the user answers. Set by the
    /// bottom bar's button, the menu command, and the table's context menu.
    private(set) var pendingDeletion: [Claim]?

    /// Asks to confirm deleting `candidates`, if they can be deleted now.
    func requestDeletion(_ candidates: [Claim]) {
        if canDelete(candidates) {
            pendingDeletion = candidates
        }
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    /// The marked candidates the table shows: what the bottom bar and the menu command delete.
    var markedShown: [Claim] {
        candidates.filter { isMarked($0) && isShown($0) }
    }

    /// Whether the marked candidates shown could be deleted now, without working out the rows.
    var canDeleteMarkedShown: Bool {
        canStartCleanup && candidates.contains { isMarked($0) && isShown($0) }
    }

    /// Whether `candidates` can be deleted now. Only candidates found on the real disk can, not
    /// those of an in-memory file system.
    func canDelete(_ candidates: [Claim]) -> Bool {
        canStartCleanup && !candidates.isEmpty
    }

    private var canStartCleanup: Bool {
        fileSystem is DarwinFileSystem && !isScanning && !isCleaning
    }

    /// Deletes `candidates`, permanently. Those deleted leave the results.
    func delete(_ candidates: [Claim]) {
        pendingDeletion = nil
        guard canDelete(candidates) else {
            return
        }
        let cleanup = CleanupSession(candidates: candidates, updateInterval: Self.updateInterval)
        self.cleanup = cleanup
        let session = session
        Task {
            await cleanup.waitUntilDone()
            guard case .finished(let result) = cleanup.state else {
                return
            }
            let removed = Set(result.removed.map(\.path))
            session?.discard(removed)
            selection.subtract(removed)
            for path in removed {
                markOverrides[path] = nil
            }
        }
    }

    // MARK: - Candidates

    /// The rules the current results were found with.
    var rules: CompiledRules? {
        session?.scanner.evaluator.rules
    }

    var candidates: [Claim] {
        session?.candidates ?? []
    }

    /// The candidates the sidebar and search let through, sorted for the table.
    var rows: [CandidateRow] {
        guard let rules else {
            return []
        }
        return candidates
            .filter(isShown)
            .map { candidate in
                CandidateRow(
                    claim: candidate,
                    isMarked: isMarked(candidate),
                    categoryTitle: rules[candidate.category].title,
                    location: displayPath(candidate.path.removingLastComponent())
                )
            }
            .sorted(by: sort.areInIncreasingOrder)
    }

    /// Whether the sidebar and search let `candidate` through.
    private func isShown(_ candidate: Claim) -> Bool {
        let matchesFilter = switch filter {
        case .all: true
        case .marked: isMarked(candidate)
        case .category(let id): candidate.category == id
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return matchesFilter && (query.isEmpty || candidate.path.string.localizedStandardContains(query))
    }

    /// Every category with candidates, largest first.
    var categories: [CategorySummary] {
        guard let rules else {
            return []
        }
        var summaries: [CategoryID: CategorySummary] = [:]
        for candidate in candidates {
            let id = candidate.category
            summaries[id, default: CategorySummary(category: rules[id])].count += 1
            summaries[id]!.bytes += candidate.size?.allocated ?? 0
        }
        return summaries.values.sorted { lhs, rhs in
            lhs.bytes != rhs.bytes
                ? lhs.bytes > rhs.bytes
                : lhs.category.title.localizedStandardCompare(rhs.category.title) == .orderedAscending
        }
    }

    var selectedCandidates: [Claim] {
        candidates.filter { selection.contains($0.path) }
    }

    /// The size of `candidates` together; `nil` while any is unmeasured. A file hard-linked
    /// into several of them counts in each.
    func totalSize(of candidates: [Claim]) -> CandidateSize? {
        var total = CandidateSize()
        for candidate in candidates {
            guard let size = candidate.size else {
                return nil
            }
            total.add(size)
        }
        return total
    }

    // MARK: - Marks

    func isMarked(_ candidate: Claim) -> Bool {
        markOverrides[candidate.path] ?? candidate.isPreselected
    }

    var markedCandidates: [Claim] {
        candidates.filter(isMarked)
    }

    func setMarked(_ isMarked: Bool, _ paths: some Sequence<FilePath>) {
        for path in paths {
            markOverrides[path] = isMarked
        }
    }

    /// Marks `paths` as suggested, undoing the user's changes to them: only safe candidates are.
    func restoreSuggestedMarks(_ paths: some Sequence<FilePath>) {
        for path in paths {
            markOverrides[path] = nil
        }
    }

    /// Marks all of `paths` unless they all are marked already, in which case unmarks them.
    func toggleMarks(_ paths: Set<FilePath>) {
        let affected = candidates.filter { paths.contains($0.path) }
        setMarked(!affected.allSatisfy(isMarked), paths)
    }

    // MARK: - Display

    /// `path` with the home folder shortened to `~`.
    func displayPath(_ path: FilePath) -> String {
        if path == home {
            return "~"
        }
        if path.starts(with: home) {
            return "~/" + path.string.dropFirst(home.string.count + 1)
        }
        return path.string
    }
}
