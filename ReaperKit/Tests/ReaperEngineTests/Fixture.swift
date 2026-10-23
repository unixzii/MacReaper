import Foundation
import ReaperFSTesting

/// A home folder with something for every shipped rule set, plus traps that must not be
/// claimed.
enum Fixture {

    static let tag = "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag.\n"

    static let tree = Tree {
        // Rust: a crate, a workspace, a distance trap, an untagged target, a napi-rs target.
        File("Developer/dua-cli/Cargo.toml")
        File("Developer/dua-cli/src/main.rs")
        File("Developer/dua-cli/target/CACHEDIR.TAG", contents: tag)
        File("Developer/dua-cli/target/debug/dua")
        File("Developer/dua-cli/tests/fixtures/web/target/CACHEDIR.TAG", contents: tag)
        File("Developer/rust-ws/Cargo.toml", contents: "[workspace]\nmembers=['crates/*']\n")
        File("Developer/rust-ws/crates/a/Cargo.toml")
        File("Developer/rust-ws/target/CACHEDIR.TAG", contents: tag)
        File("Developer/rusty/Cargo.toml")
        File("Developer/rusty/target/notes.md")
        File("Developer/napi-mod/Cargo.toml")
        File("Developer/napi-mod/package.json")
        File("Developer/napi-mod/target/.rustc_info.json", contents: "{}")
        File("Developer/napi-mod/target/aarch64-apple-darwin/CACHEDIR.TAG", contents: tag)

        // Node: nested node_modules, a monorepo package, a framework cache, a symlinked node_modules.
        File("Developer/webapp/package.json")
        File("Developer/webapp/node_modules/left-pad/package.json")
        File("Developer/webapp/node_modules/left-pad/node_modules/x/package.json")
        Directory("Developer/webapp/.next/cache")
        File("Developer/webapp/packages/ui/package.json")
        Directory("Developer/webapp/packages/ui/node_modules/react")
        File("Developer/linked/package.json")
        Symlink("Developer/linked/node_modules", to: "/Users/test/Developer/webapp/node_modules")

        // Swift.
        File("Developer/swiftpkg/Package.swift")
        Directory("Developer/swiftpkg/.build/DerivedData")
        Directory("Developer/notswift/.build")

        // CMake: out-of-source, CLion-style, copied, orphaned, in-source.
        File("Developer/cmake-proj/CMakeLists.txt")
        File("Developer/cmake-proj/build/CMakeCache.txt", contents: cmakeCache(
            cacheDir: "/Users/test/Developer/cmake-proj/build", source: "/Users/test/Developer/cmake-proj", project: "cmproj"))
        File("Developer/cmake-proj/cmake-build-debug/CMakeCache.txt", contents: cmakeCache(
            cacheDir: "/Users/test/Developer/cmake-proj/cmake-build-debug", source: "/Users/test/Developer/cmake-proj", project: "cmproj"))
        File("Developer/copied-build/CMakeCache.txt", contents: cmakeCache(
            cacheDir: "/Users/test/Developer/cmake-proj/build", source: "/Users/test/Developer/cmake-proj"))
        File("Developer/orphan-build/CMakeCache.txt", contents: cmakeCache(
            cacheDir: "/Users/test/Developer/orphan-build", source: "/Users/test/Developer/deleted-proj", project: "gone"))
        File("Developer/insrc/CMakeLists.txt")
        File("Developer/insrc/src/a.c")
        File("Developer/insrc/CMakeCache.txt", contents: cmakeCache(
            cacheDir: "/Users/test/Developer/insrc", source: "/Users/test/Developer/insrc", project: "insrc"))
        Directory("Developer/insrc/CMakeFiles/a.dir")

        // Meson: a build directory holding a venv and CMake probes, which its claim hides.
        File("Developer/qemu/meson.build")
        File("Developer/qemu/build/meson-private/coredata.dat")
        File("Developer/qemu/build/meson-info/meson-info.json", contents: "{}")
        File("Developer/qemu/build/pyvenv/pyvenv.cfg")
        File("Developer/qemu/build/meson-private/cm/CMakeLists.txt")
        File("Developer/qemu/build/meson-private/cm/CMakeCache.txt", contents: cmakeCache(
            cacheDir: "/Users/test/Developer/qemu/build/meson-private/cm", source: "/Users/test/Developer/qemu/build/meson-private/cm"))
        Directory("Developer/qemu/build/meson-private/cm/CMakeFiles")

        // JVM.
        File("Developer/android-app/settings.gradle.kts")
        Directory("Developer/android-app/.gradle/8.9")
        Directory("Developer/android-app/build/reports")
        File("Developer/android-app/app/build.gradle.kts")
        Directory("Developer/android-app/app/build/intermediates")
        Directory("Developer/android-app/app/.cxx/Debug")
        File("Developer/docs-site/index.md")
        File("Developer/docs-site/build/index.html")
        File("Developer/java-svc/pom.xml")
        Directory("Developer/java-svc/target/classes")
        File("Developer/java-odd/pom.xml")
        File("Developer/java-odd/target/README")

        // Python.
        File("Developer/pyproj/pyproject.toml")
        File("Developer/pyproj/.venv/pyvenv.cfg", contents: "home = /usr/bin\n")
        Directory("Developer/pyproj/.venv/lib/python3.13/site-packages/pkg/__pycache__")
        Directory("Developer/pyproj/src/pkg/__pycache__")
        File("Developer/pyproj/.pytest_cache/CACHEDIR.TAG", contents: tag)
        File("Developer/pyproj/.mypy_cache/CACHEDIR.TAG", contents: tag)
        File("Developer/pyproj/venv/notes.txt")

        // .NET.
        File("Developer/dotnet-app/App.csproj")
        File("Developer/dotnet-app/obj/project.assets.json")
        Directory("Developer/dotnet-app/bin/Debug")
        File("Developer/dotnet-lib/Lib.csproj")
        Directory("Developer/dotnet-lib/obj")

        // Unity.
        Directory("Developer/game/Assets")
        File("Developer/game/ProjectSettings/ProjectVersion.txt")
        Directory("Developer/game/Library/Artifacts")
        Directory("Developer/game/Temp")
        Directory("Developer/game/Logs")
        Directory("Developer/not-unity/Assets")
        Directory("Developer/not-unity/Library")

        // LaTeX.
        for name in ["paper.tex", "paper.aux", "paper.log", "paper.synctex.gz", "notes.log", "figure.v2.tex", "figure.v2.aux", "orphan.toc"] {
            File("Developer/thesis/\(name)")
        }

        // Generic CACHEDIR.TAG.
        File("Developer/tool-out/fancy-cache/CACHEDIR.TAG", contents: tag)
        File("Developer/tool-out/bad-cache/CACHEDIR.TAG", contents: "not a tag\n")

        // Skips.
        File("Developer/repo/package.json")
        File("Developer/repo/.git/lfs/cache/CACHEDIR.TAG", contents: tag)
        File("Developer/Tool.app/Contents/Info.plist")
        File("Developer/Tool.app/Contents/Resources/app/package.json")
        Directory("Developer/Tool.app/Contents/Resources/app/node_modules/electron")
        File("Library/Mobile Documents/com~apple~CloudDocs/proj/package.json")
        Directory("Library/Mobile Documents/com~apple~CloudDocs/proj/node_modules/x")
        File(".Trash/old/package.json")
        Directory(".Trash/old/node_modules/x")
        File("Library/CloudStorage/Dropbox/proj/package.json")
        Directory("Library/CloudStorage/Dropbox/proj/node_modules/x")
        File("Library/Developer/CoreSimulator/Devices/F4A5/data/Library/Mobile Documents/x/package.json")
        Directory("Library/Developer/CoreSimulator/Devices/F4A5/data/Library/Mobile Documents/x/node_modules/y")
        File("Library/Developer/CoreSimulator/Devices/F4A5/data/Documents/app/package.json")
        Directory("Library/Developer/CoreSimulator/Devices/F4A5/data/Documents/app/node_modules/y")

        // Xcode.
        File("Library/Developer/Xcode/DerivedData/SwiftPkg-abc/info.plist", contents: derivedDataPlist(workspace: "/Users/test/Developer/swiftpkg"))
        File("Library/Developer/Xcode/DerivedData/Gone-def/info.plist", contents: derivedDataPlist(workspace: "/Users/test/Developer/Gone/Gone.xcodeproj"))
        Directory("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/x")
        for version in ["iPhone15,2 17.4 (21E219)", "iPhone15,2 18.1 (22B83)", "iPhone16,1 18.0 (22A3354)"] {
            Directory("Library/Developer/Xcode/iOS DeviceSupport/\(version)/Symbols")
        }
        Directory("Library/Developer/Xcode/Archives/2026-01-01/App 1-1-26.xcarchive")
        Directory("Library/Developer/CoreSimulator/Caches/dyld")

        // Package caches.
        File("Library/Caches/Homebrew/downloads/a.tar.gz")
        Directory("Library/Caches/pip/http")
        Directory(".npm/_cacache/content-v2")
        Directory("Library/pnpm/store/v3")
        File("Library/Caches/com.example.app/proj/package.json")
        Directory("Library/Caches/com.example.app/proj/node_modules/x")

        // macOS.
        File("Library/Logs/DiagnosticReports/old.ips", modified: daysAgo(40))
        File("Library/Logs/DiagnosticReports/new.ips", modified: daysAgo(2))
        File("Downloads/old.dmg", modified: daysAgo(90))
        File("Downloads/new.dmg", modified: daysAgo(3))
        File("Downloads/old.zip", modified: daysAgo(90))
        Directory("Library/Application Support/MobileSync/Backup/00008110-ABC")
        for version in ["IntelliJIdea2024.3", "IntelliJIdea2025.2", "PyCharm2025.1"] {
            Directory("Library/Caches/JetBrains/\(version)")
        }
    }

    /// Every claimed path, relative to the home folder, with its category.
    static let expected: [String: String] = [
        "Developer/dua-cli/target": "rust.target",
        "Developer/rust-ws/target": "rust.target",
        "Developer/napi-mod/target": "rust.target",
        "Developer/qemu/build": "meson.build",
        "Developer/webapp/node_modules": "node.modules",
        "Developer/webapp/.next": "node.framework-cache",
        "Developer/webapp/packages/ui/node_modules": "node.modules",
        "Developer/swiftpkg/.build": "swiftpm.build",
        "Developer/cmake-proj/build": "cmake.build",
        "Developer/cmake-proj/cmake-build-debug": "cmake.build",
        "Developer/orphan-build": "cmake.build-orphaned",
        "Developer/insrc/CMakeFiles": "cmake.in-source-files",
        "Developer/android-app/.gradle": "gradle.project-cache",
        "Developer/android-app/build": "gradle.build",
        "Developer/android-app/app/build": "gradle.build",
        "Developer/android-app/app/.cxx": "gradle.project-cache",
        "Developer/java-svc/target": "maven.target",
        "Developer/pyproj/.venv": "python.venv",
        "Developer/pyproj/src/pkg/__pycache__": "python.bytecode",
        "Developer/pyproj/.pytest_cache": "python.tool-cache",
        "Developer/pyproj/.mypy_cache": "python.tool-cache",
        "Developer/dotnet-app/obj": "dotnet.obj",
        "Developer/dotnet-app/bin": "dotnet.bin",
        "Developer/game/Library": "unity.library",
        "Developer/game/Temp": "unity.temp",
        "Developer/game/Logs": "unity.temp",
        "Developer/thesis/paper.aux": "latex.aux",
        "Developer/thesis/paper.log": "latex.aux",
        "Developer/thesis/paper.synctex.gz": "latex.aux",
        "Developer/thesis/figure.v2.aux": "latex.aux",
        "Developer/tool-out/fancy-cache": "core.cachedir-tagged",
        // Not Rust output (distance 4), but still a tagged cache: offered unchecked by the generic rule.
        "Developer/dua-cli/tests/fixtures/web/target": "core.cachedir-tagged",
        "Library/Developer/Xcode/DerivedData/SwiftPkg-abc": "xcode.derived-data",
        "Library/Developer/Xcode/DerivedData/Gone-def": "xcode.derived-data-orphaned",
        "Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.4 (21E219)": "xcode.device-support-old",
        "Library/Developer/Xcode/Archives/2026-01-01": "xcode.archives",
        "Library/Developer/CoreSimulator/Caches": "xcode.simulator-caches",
        "Library/Caches/Homebrew": "package-caches.download-cache",
        "Library/Caches/com.example.app/proj/node_modules": "node.modules",
        "Library/Caches/pip": "package-caches.download-cache",
        ".npm/_cacache": "package-caches.download-cache",
        "Library/pnpm/store": "package-caches.store",
        "Library/Logs/DiagnosticReports/old.ips": "macos.diagnostic-reports",
        "Downloads/old.dmg": "macos.old-installers",
        "Library/Application Support/MobileSync/Backup/00008110-ABC": "macos.ios-backup",
        "Library/Caches/JetBrains/IntelliJIdea2024.3": "macos.jetbrains-old-caches",
    ]

    /// The innermost scope some candidates inherit, as `scope@root`; `nil` means none.
    static let expectedInnermostScopes: [String: String?] = [
        "Developer/webapp/packages/ui/node_modules": "node.project@Developer/webapp/packages/ui",
        "Developer/android-app/app/build": "gradle.project@Developer/android-app/app",
        "Developer/dua-cli/target": "rust.project@Developer/dua-cli",
        "Downloads/old.dmg": nil,
    ]

    private static func daysAgo(_ days: Double) -> Date {
        .daysBefore(Harness.now, days)
    }

    static func cmakeCache(cacheDir: String, source: String, project: String = "demo") -> String {
        """
        # This is the CMakeCache file.
        CMAKE_PROJECT_NAME:STATIC=\(project)
        CMAKE_CACHEFILE_DIR:INTERNAL=\(cacheDir)
        CMAKE_HOME_DIRECTORY:INTERNAL=\(source)
        """
    }

    static func derivedDataPlist(workspace: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>WorkspacePath</key>
            <string>\(workspace)</string>
        </dict>
        </plist>
        """
    }
}
