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

/// The scan window's state: the profile to scan with, the current scan, and the candidates the
/// user marked for cleanup.
@Observable
final class ScanModel {

    let library: RuleLibrary
    let home: FilePath
    @ObservationIgnored
    private let fileSystem: any FileSystem

    /// Choosing another profile discards the previous profile's results.
    var profileID: String {
        didSet {
            guard profileID != oldValue else {
                return
            }
            UserDefaults.standard.set(profileID, forKey: Self.profileKey)
            if !isScanning {
                session = nil
            }
        }
    }

    /// `nil` until the first scan.
    private(set) var session: ScanSession?
    var filter = CandidateFilter.all
    var searchText = ""
    var selection: Set<FilePath> = []
    var sortOrder = [KeyPathComparator(\CandidateRow.bytes, order: .reverse)]
    /// Marks the user changed. Every other candidate is marked if its profile preselects it.
    private var markOverrides: [FilePath: Bool] = [:]

    private static let profileKey = "profile"

    init(library: RuleLibrary, fileSystem: any FileSystem, home: FilePath) {
        self.library = library
        self.fileSystem = fileSystem
        self.home = home
        let saved = UserDefaults.standard.string(forKey: Self.profileKey)
        profileID = library[saved ?? ""]?.id ?? library["developer"]?.id ?? library.profiles.first?.id ?? ""
    }

    var profile: RuleLibrary.Profile? {
        library[profileID]
    }

    var isScanning: Bool {
        session?.isScanning ?? false
    }

    var canScan: Bool {
        guard !isScanning, case .success? = profile?.rules else {
            return false
        }
        return true
    }

    /// Scans with the chosen profile, discarding the previous results and marks.
    func scan() {
        guard canScan, case .success(let rules)? = profile?.rules else {
            return
        }
        markOverrides = [:]
        selection = []
        filter = .all
        // A new scanner per scan, so `olderThan` conditions measure from now.
        let session = ScanSession(scanner: DiskScanner(rules: rules, fileSystem: fileSystem))
        self.session = session
        session.start()
    }

    func stop() {
        session?.cancel()
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
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return candidates
            .filter { candidate in
                switch filter {
                case .all: true
                case .marked: isMarked(candidate)
                case .category(let id): candidate.category == id
                }
            }
            .filter { query.isEmpty || $0.path.string.localizedStandardContains(query) }
            .map { candidate in
                CandidateRow(
                    claim: candidate,
                    isMarked: isMarked(candidate),
                    categoryTitle: rules[candidate.category].title,
                    location: displayPath(candidate.path.removingLastComponent())
                )
            }
            .sorted(using: sortOrder)
    }

    /// Every category with candidates, by title.
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
        return summaries.values.sorted { $0.category.title.localizedStandardCompare($1.category.title) == .orderedAscending }
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

    /// Marks `paths` as their profile suggests, undoing the user's changes to them.
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
