import ReaperFS
import ReaperRules
import SwiftUI

extension UInt64 {

    var formattedBytes: String {
        Int64(clamping: self).formatted(.byteCount(style: .file))
    }
}

extension Duration {

    var formattedSeconds: String {
        formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
    }
}

extension Safety {

    var title: LocalizedStringKey {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .dangerous: "Dangerous"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .dangerous: .red
        }
    }

    /// What the safety level means for the user, and whether the scan marked the candidate.
    func explanation(isMarkedAutomatically: Bool) -> String {
        let meaning = switch self {
        case .safe: String(localized: "Can be recreated without effort, for example by building again.")
        case .review: String(localized: "Probably fine to delete, but you should decide.")
        case .dangerous: String(localized: "May hold the only copy of something. Check it before deleting.")
        }
        let marking = isMarkedAutomatically
            ? String(localized: "Marked for cleanup automatically.")
            : String(localized: "Not marked automatically.")
        return meaning + " " + marking
    }
}

/// A safety level as a colored capsule.
struct SafetyBadge: View {

    let safety: Safety

    var body: some View {
        Text(safety.title)
            .font(.caption.bold())
            .foregroundStyle(safety.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(safety.color.opacity(0.15), in: Capsule())
    }
}

extension FSError {

    var explanation: String {
        switch self {
        case .notFound: String(localized: "Disappeared during the scan")
        case .permissionDenied: String(localized: "Permission denied")
        case .notADirectory: String(localized: "Not a folder")
        case .symlink: String(localized: "Symbolic link")
        case .dataless: String(localized: "Not downloaded from iCloud")
        case .io(let errno): String(localized: "Read error \(String(cString: strerror(errno)))")
        }
    }
}
