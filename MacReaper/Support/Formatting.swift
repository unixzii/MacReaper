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
