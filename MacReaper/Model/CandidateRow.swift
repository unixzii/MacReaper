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

extension CandidateSize {

    /// The allocated size, after "<" when deleting may free less because other files share
    /// part of it, or after "≥" when part of it could not be read.
    var formatted: String {
        (mayFreeLess ? "< " : isComplete ? "" : "≥ ") + allocated.formattedBytes
    }
}
