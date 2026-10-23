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

    var project: String {
        claim.group ?? ""
    }

    var safetyRank: Int {
        Safety.allCases.firstIndex(of: claim.safety)!
    }

    /// What deleting the candidate frees, or `0` until it is measured.
    var bytes: UInt64 {
        claim.size?.bytesFreed ?? 0
    }

    var modified: Date {
        claim.modified
    }
}

nonisolated extension CandidateSize {

    /// Reclaimable bytes when the scan measured them, allocated bytes otherwise.
    var bytesFreed: UInt64 {
        reclaimable ?? allocated
    }
}
