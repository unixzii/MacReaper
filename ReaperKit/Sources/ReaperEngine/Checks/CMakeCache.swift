import ReaperFS
import ReaperRules
import System

/// `cmake.cache`: reads the directory's `CMakeCache.txt` to tell a real build tree from a copy,
/// an in-source build from an out-of-source one, and a live project from an orphaned one.
///
/// Facts:
/// - `valid`: `CMAKE_CACHEFILE_DIR` is this directory, so the cache was not copied or moved.
/// - `inSource`: `CMAKE_HOME_DIRECTORY` (the source) is this directory.
/// - `sourceDir`: `CMAKE_HOME_DIRECTORY` as written.
/// - `sourceExists`: the source still has a `CMakeLists.txt`.
/// - `project`: `CMAKE_PROJECT_NAME`, or the source directory's name.
struct CMakeCache: Check {

    private static let maxBytes = 256 * 1024

    let spec = CheckSpec(
        name: "cmake.cache",
        facts: [
            "valid": .boolean,
            "inSource": .boolean,
            "sourceDir": .string,
            "sourceExists": .boolean,
            "project": .string,
        ]
    )

    func evaluate(_ entry: EntryContext, arguments: [String: ScalarValue], fileSystem: any FileSystem) -> Facts? {
        guard let text = fileSystem.readText(at: entry.path.appending("CMakeCache.txt"), maxBytes: Self.maxBytes) else {
            return nil
        }
        let values = Self.entries(in: text)
        guard let cacheDirectory = values["CMAKE_CACHEFILE_DIR"], let sourceDirectory = values["CMAKE_HOME_DIRECTORY"] else {
            return nil
        }

        // By identity: the cache spells paths as CMake saw them, which may differ from how the
        // walk reached the directory, through a symlink or the data volume's mount point.
        func isHere(_ path: String) -> Bool {
            let resolved = try? fileSystem.resolvingSymlinks(FilePath(path))
            return resolved.flatMap { try? fileSystem.identity(at: $0).identity } == entry.attributes.identity
        }
        let source = FilePath(sourceDirectory)
        return [
            "valid": .boolean(isHere(cacheDirectory)),
            "inSource": .boolean(isHere(sourceDirectory)),
            "sourceDir": .string(sourceDirectory),
            "sourceExists": .boolean(fileSystem.exists(at: source.appending("CMakeLists.txt"))),
            "project": .string(values["CMAKE_PROJECT_NAME"] ?? source.lastComponent?.string ?? sourceDirectory),
        ]
    }

    /// Parses `KEY:TYPE=VALUE` lines, skipping comments and anything else.
    private static func entries(in text: String) -> [String: String] {
        var entries: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"), let equals = line[colon...].firstIndex(of: "="),
                  !line.hasPrefix("#"), !line.hasPrefix("//") else {
                continue
            }
            entries[String(line[..<colon])] = String(line[line.index(after: equals)...])
        }
        return entries
    }
}
