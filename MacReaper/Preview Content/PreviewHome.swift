#if DEBUG
import Foundation
import ReaperFSTesting
import ReaperRules
import System

extension ScanModel {

    /// A model that scans a small in-memory home folder with the built-in rules, for previews.
    static func preview() -> ScanModel {
        let home: FilePath = "/Users/preview"
        let fileSystem = InMemoryFileSystem(root: home, tree: PreviewHome.tree)
        return ScanModel(
            library: .builtin(),
            fileSystem: fileSystem,
            home: home,
            locations: [ScanLocation(folder: home, home: home)]
        )
    }
}

private enum PreviewHome {
    static let tag = "Signature: 8a477f597d28d172789f06886806bc55\n"

    static func blob(kilobytes: Int) -> String {
        String(repeating: "x", count: kilobytes * 1024)
    }

    static let tree = Tree {
        File("Developer/dua-cli/Cargo.toml")
        File("Developer/dua-cli/target/CACHEDIR.TAG", contents: tag)
        File("Developer/dua-cli/target/debug/dua", contents: blob(kilobytes: 900))
        // Packages cloned from a store outside the candidates, and a file hard-linked between projects.
        File("Library/pnpm/store/react.js", contents: blob(kilobytes: 420))
        File("Developer/webapp/package.json")
        Clone("Developer/webapp/node_modules/react/index.js", of: "Library/pnpm/store/react.js")
        File("Developer/webapp/node_modules/shared/lib.js", contents: blob(kilobytes: 96))
        File("Developer/admin/package.json")
        HardLink("Developer/admin/node_modules/shared/lib.js", to: "Developer/webapp/node_modules/shared/lib.js")
        File("Developer/webapp/.next/cache/webpack.pack", contents: blob(kilobytes: 160))
        File("Developer/swiftpkg/Package.swift")
        File("Developer/swiftpkg/.build/debug/swiftpkg", contents: blob(kilobytes: 610))
        File("Developer/pyproj/pyproject.toml")
        File("Developer/pyproj/.venv/pyvenv.cfg", contents: "home = /usr/bin\n")
        File("Developer/pyproj/.venv/lib/site.py", contents: blob(kilobytes: 240))
        File("Developer/pyproj/src/pkg/__pycache__/a.pyc", contents: blob(kilobytes: 12))
        File("Developer/thesis/paper.tex")
        File("Developer/thesis/paper.aux", contents: blob(kilobytes: 4))
        File("Developer/tool-out/fancy-cache/CACHEDIR.TAG", contents: tag)
        File("Library/Caches/Homebrew/downloads/a.tar.gz", contents: blob(kilobytes: 300))
        Directory("Library/Developer/Xcode/Archives/2026-01-01/App 1-1-26.xcarchive")
        File("Downloads/old.dmg", contents: blob(kilobytes: 700), modified: .now.addingTimeInterval(-90 * 86_400))
    }
}
#endif
