import Foundation
import ReaperEngine
import ReaperRules
import System

/// One candidate as the table shows it, with the values its columns sort by.
nonisolated struct CandidateRow: Identifiable {

    let claim: Claim
    let isMarked: Bool
    let categoryTitle: String
    /// The folder the candidate is in, with the home folder shortened to `~`.
    let location: String

    var id: FilePath {
        claim.path
    }

    var name: String {
        claim.path.lastComponent?.string ?? claim.path.string
    }

    /// Allocated bytes, or `0` until the candidate is measured.
    var bytes: UInt64 {
        claim.size?.allocated ?? 0
    }

    var modified: Date {
        claim.modified
    }
}

/// The column the table is sorted by, and which way.
nonisolated struct CandidateSort: Equatable {

    enum Column: String {
        case name
        case size
        case category
        case modified
    }

    var column: Column
    var ascending: Bool

    /// Rows that tie on the column keep the order of their paths, so the order is stable.
    func areInIncreasingOrder(_ lhs: CandidateRow, _ rhs: CandidateRow) -> Bool {
        let order: ComparisonResult = switch column {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .size: Self.compare(lhs.bytes, rhs.bytes)
        case .category: lhs.categoryTitle.localizedStandardCompare(rhs.categoryTitle)
        case .modified: Self.compare(lhs.modified, rhs.modified)
        }
        if order == .orderedSame {
            return lhs.claim.path.string < rhs.claim.path.string
        }
        return (order == .orderedAscending) == ascending
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

extension CandidateSize {

    /// The allocated size, after "<" when deleting may free less because other files share
    /// part of it, or after "≥" when part of it could not be read.
    var formatted: String {
        (mayFreeLess ? "< " : isComplete ? "" : "≥ ") + allocated.formattedBytes
    }
}
