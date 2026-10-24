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

    /// Whole seconds, or "< 1 sec".
    var formattedSeconds: String {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.minutes, .seconds], width: .abbreviated)
        return self < .seconds(1) ? "< " + Duration.seconds(1).formatted(style) : formatted(style)
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
