import Foundation
import System

/// A folder to scan from. The scan stays on the folder's volume.
struct ScanLocation: Hashable, Identifiable {

    let root: FilePath
    /// The home folder as paths under `root` spell it, which `~` in rules stands for. Walking
    /// the data volume from its mount point reaches the home folder through
    /// `/System/Volumes/Data` rather than through the `/Users` firmlink.
    let home: FilePath
    let title: String
    let systemImage: String

    var id: FilePath {
        root
    }

    /// The mount point of the volume that holds users' files.
    static let dataVolume: FilePath = "/System/Volumes/Data"

    /// A folder the user chose, scanned with `home` as the home folder.
    init(folder: FilePath, home: FilePath) {
        self.init(
            root: folder,
            home: Self.home(home, seenFrom: folder),
            title: folder == home ? String(localized: "Home") : folder.lastComponent?.string ?? folder.string,
            systemImage: folder == home ? "house" : "folder"
        )
    }

    private init(root: FilePath, home: FilePath, title: String, systemImage: String) {
        self.root = root
        self.home = home
        self.title = title
        self.systemImage = systemImage
    }

    /// The data volume, then the home folder.
    static func standard(home: FilePath) -> [ScanLocation] {
        let name = try? URL(filePath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        let volume = ScanLocation(
            root: dataVolume,
            home: Self.home(home, seenFrom: dataVolume),
            title: name ?? String(localized: "Data Volume"),
            systemImage: "internaldrive"
        )
        return [volume, ScanLocation(folder: home, home: home)]
    }

    /// `home` as spelled by paths under `root`.
    private static func home(_ home: FilePath, seenFrom root: FilePath) -> FilePath {
        root.starts(with: dataVolume) && !home.starts(with: dataVolume)
            ? FilePath(dataVolume.string + home.string)
            : home
    }
}
