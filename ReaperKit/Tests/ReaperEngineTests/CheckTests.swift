@testable import ReaperEngine
import ReaperFSTesting
import ReaperRules
import Testing

@Suite("Built-in checks")
struct CheckTests {

    static let signature = "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag.\n"

    @Test("Every declared check has an implementation")
    func everyCheckIsImplemented() {
        #expect(Set(BuiltinChecks.all.keys) == Set(CheckSpec.builtins.keys))
    }

    @Test("cachedir.signature")
    func cacheDirSignature() throws {
        let harness = try Self.harness {
            File("valid/CACHEDIR.TAG", contents: Self.signature)
            File("forged/CACHEDIR.TAG", contents: "not a tag")
            Directory("untagged")
        }

        #expect(try run(CacheDirSignature(), "valid", harness) == [:])
        #expect(try run(CacheDirSignature(), "forged", harness) == nil)
        #expect(try run(CacheDirSignature(), "untagged", harness) == nil)
    }

    @Test("cmake.cache")
    func cmakeCache() throws {
        let harness = try Self.harness {
            File("proj/CMakeLists.txt")
            File("proj/build/CMakeCache.txt", contents: Self.cache(cacheDir: "/Users/test/proj/build", source: "/Users/test/proj", project: "demo"))
            File("proj/linked-build/CMakeCache.txt", contents: Self.cache(cacheDir: "/Users/test/alias/linked-build", source: "/Users/test/proj"))
            Symlink("alias", to: "proj")
            File("copy/CMakeCache.txt", contents: Self.cache(cacheDir: "/Users/test/proj/build", source: "/Users/test/proj"))
            File("orphan/CMakeCache.txt", contents: Self.cache(cacheDir: "/Users/test/orphan", source: "/Users/test/gone"))
            File("insrc/CMakeLists.txt")
            File("insrc/CMakeCache.txt", contents: Self.cache(cacheDir: "/Users/test/insrc", source: "/Users/test/insrc"))
            File("broken/CMakeCache.txt", contents: "# no paths here\n")
        }

        #expect(try run(CMakeCache(), "proj/build", harness) == [
            "valid": .boolean(true), "inSource": .boolean(false), "sourceDir": .string("/Users/test/proj"),
            "sourceExists": .boolean(true), "project": .string("demo"),
        ])
        #expect(try run(CMakeCache(), "proj/linked-build", harness)?["valid"] == .boolean(true))
        #expect(try run(CMakeCache(), "copy", harness)?["valid"] == .boolean(false))
        #expect(try run(CMakeCache(), "orphan", harness)?["sourceExists"] == .boolean(false))
        #expect(try run(CMakeCache(), "orphan", harness)?["project"] == .string("gone"))
        #expect(try run(CMakeCache(), "insrc", harness)?["inSource"] == .boolean(true))
        #expect(try run(CMakeCache(), "broken", harness) == nil)
    }

    @Test("xcode.derived-data")
    func xcodeDerivedData() throws {
        let harness = try Self.harness {
            File("Projects/App/App.xcodeproj/project.pbxproj")
            File("DerivedData/App-abc/info.plist", contents: Self.plist(workspace: "/Users/test/Projects/App/App.xcodeproj"))
            File("DerivedData/Gone-def/info.plist", contents: Self.plist(workspace: "/Users/test/Projects/Gone/Gone.xcodeproj"))
            Directory("DerivedData/ModuleCache.noindex")
        }

        #expect(try run(XcodeDerivedData(), "DerivedData/App-abc", harness) == [
            "workspacePath": .string("/Users/test/Projects/App/App.xcodeproj"), "workspaceExists": .boolean(true),
        ])
        #expect(try run(XcodeDerivedData(), "DerivedData/Gone-def", harness)?["workspaceExists"] == .boolean(false))
        #expect(try run(XcodeDerivedData(), "DerivedData/ModuleCache.noindex", harness) == nil)
    }

    @Test("version.superseded")
    func versionSuperseded() throws {
        let harness = try Self.harness {
            Directory("DeviceSupport/iPhone15,2 17.4 (21E219)")
            Directory("DeviceSupport/iPhone15,2 18.1 (22B83)")
            Directory("DeviceSupport/iPhone15,2 17.10 (21H1)")
            Directory("DeviceSupport/iPhone16,1 18.0 (22A3354)")
            Directory("DeviceSupport/Unrelated")
        }
        let arguments: [String: ScalarValue] = ["pattern": .string(#"^(?<group>.+?) (?<version>\d+(\.\d+)*) \("#)]
        func supersededBy(_ name: String) throws -> ScalarValue? {
            let context = try harness.context("DeviceSupport/\(name)")
            return VersionSuperseded().evaluate(context, arguments: arguments, fileSystem: harness.fileSystem)?["supersededBy"]
        }

        #expect(try supersededBy("iPhone15,2 17.4 (21E219)") == .string("iPhone15,2 18.1 (22B83)"))
        // Components compare as numbers: 17.10 is newer than 17.4 but older than 18.1.
        #expect(try supersededBy("iPhone15,2 17.10 (21H1)") == .string("iPhone15,2 18.1 (22B83)"))
        #expect(try supersededBy("iPhone15,2 18.1 (22B83)") == nil)
        #expect(try supersededBy("iPhone16,1 18.0 (22A3354)") == nil)
        #expect(try supersededBy("Unrelated") == nil)
    }

    private func run(_ check: some Check, _ path: String, _ harness: Harness) throws -> Facts? {
        check.evaluate(try harness.context(path), arguments: [:], fileSystem: harness.fileSystem)
    }

    private static func harness(@TreeBuilder _ tree: () -> [TreeNode]) throws -> Harness {
        try Harness(rules: """
              - id: t.placeholder
                when: { name: placeholder }
                action: { claim: a }
            """, tree: tree)
    }

    private static func cache(cacheDir: String, source: String, project: String? = nil) -> String {
        """
        # This is the CMakeCache file.
        //Value Computed by CMake
        \(project.map { "CMAKE_PROJECT_NAME:STATIC=\($0)" } ?? "")
        CMAKE_CACHEFILE_DIR:INTERNAL=\(cacheDir)
        CMAKE_HOME_DIRECTORY:INTERNAL=\(source)
        """
    }

    private static func plist(workspace: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>LastAccessedDate</key>
            <date>2026-04-13T06:33:13Z</date>
            <key>WorkspacePath</key>
            <string>\(workspace)</string>
        </dict>
        </plist>
        """
    }
}
