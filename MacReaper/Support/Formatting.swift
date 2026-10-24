import AppKit
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

extension CompiledCategory {

    /// The category's SF Symbol, or a folder when it names none, or one this system lacks.
    var displaySymbol: String {
        if let symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return "folder"
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

    /// Why an entry couldn't be deleted.
    var removalExplanation: String {
        switch self {
        case .notFound: String(localized: "it disappeared")
        case .permissionDenied: String(localized: "permission denied")
        case .notADirectory, .symlink: String(localized: "it changed while being deleted")
        case .dataless: String(localized: "it isn’t downloaded from iCloud")
        case .io(EXDEV): String(localized: "it’s on another volume")
        case .io(let errno): String(cString: strerror(errno)).lowercased()
        }
    }
}
