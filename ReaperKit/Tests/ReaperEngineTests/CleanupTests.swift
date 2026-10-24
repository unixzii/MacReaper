import Darwin
import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import Synchronization
import System
import Testing

@Suite("Cleanup")
struct CleanupTests {

    static let rules = """
          - id: t.modules
            when: { name: node_modules }
            action: { claim: a }
          - id: t.dmg
            when: { kind: file, name: "*.dmg" }
            action: { claim: a }
        """

    @Test("Candidates are deleted with everything in them, and nothing else is", arguments: [1, 4])
    func deletesCandidates(threads: Int) async throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            for project in 0..<5 {
                File("p\(project)/package.json")
                for package in 0..<20 {
                    File("p\(project)/node_modules/pkg\(package)/index.js", contents: "x")
                    File("p\(project)/node_modules/pkg\(package)/lib/deep/nested/file.js", contents: "y")
                }
                Symlink("p\(project)/node_modules/.bin/escape", to: "../../package.json")
            }
            File("Downloads/installer.dmg", contents: "dmg")
            File("Downloads/notes.txt")
        }.materialize(at: temporary.path)
        let scan = try await Self.scan(temporary.path)
        #expect(scan.candidates.count == 6)

        let progress = Mutex<[CleanupProgress]>([])
        let result = await Cleanup(threadCount: threads).run(scan.candidates, reportingEvery: .milliseconds(1)) { update in
            progress.withLock { $0.append(update) }
        }

        #expect(result.removed.map(\.path) == scan.candidates.map(\.path))
        #expect(result.failures.isEmpty)
        #expect(result.notStarted.isEmpty)
        for candidate in scan.candidates {
            #expect(!DarwinFileSystem().exists(at: candidate.path))
        }
        for project in 0..<5 {
            #expect(DarwinFileSystem().exists(at: temporary.path.appending("p\(project)/package.json")))
        }
        #expect(DarwinFileSystem().exists(at: temporary.path.appending("Downloads/notes.txt")))

        let last = try #require(progress.withLock { $0.last })
        #expect(last.finishedCandidates == 6)
        // Every file and folder the scan counted, plus the symlinks it does not count.
        let counted = scan.candidates.reduce(0) { $0 + $1.size!.files + $1.size!.directories }
        #expect(last.totalEntries == counted)
        #expect(last.removedEntries == counted + 5)
        #expect(result.removedSize == scan.totalSize)
    }

    @Test("A candidate deleted or replaced since the scan is left alone")
    func changedCandidates() async throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("gone/node_modules/a.js")
            File("replaced/node_modules/a.js")
            File("kept/node_modules/a.js")
        }.materialize(at: temporary.path)
        let scan = try await Self.scan(temporary.path)
        try FileManager.default.removeItem(atPath: temporary.path.appending("gone/node_modules").string)
        let replaced = temporary.path.appending("replaced/node_modules")
        try FileManager.default.removeItem(atPath: replaced.string)
        try FileManager.default.createDirectory(atPath: replaced.appending("new").string, withIntermediateDirectories: true)

        let result = await Cleanup().run(scan.candidates)

        #expect(result.removed.map(\.path) == [temporary.path.appending("kept/node_modules")])
        #expect(result.failures.map(\.candidate.path) == [
            temporary.path.appending("gone/node_modules"),
            replaced,
        ])
        #expect(result.failures.allSatisfy { $0.reason == .changed })
        #expect(DarwinFileSystem().exists(at: replaced.appending("new")))
    }

    @Test("What cannot be deleted is reported, with the folders holding it kept, and the rest is deleted")
    func incompleteCandidate() async throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("app/node_modules/a/locked.js")
            File("app/node_modules/a/other.js")
            File("app/node_modules/b/c.js")
            File("lib/node_modules/d.js")
        }.materialize(at: temporary.path)
        let modules = temporary.path.appending("app/node_modules")
        let locked = modules.appending("a/locked.js")
        #expect(chflags(locked.string, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.string, 0) }
        let scan = try await Self.scan(temporary.path)

        let result = await Cleanup().run(scan.candidates)

        #expect(result.removed.map(\.path) == [temporary.path.appending("lib/node_modules")])
        let failure = try #require(result.failures.first)
        #expect(failure.candidate.path == modules)
        #expect(failure.reason == .incomplete([RemovalFailure(path: locked, error: .permissionDenied)]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: modules.string) == ["a"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: modules.appending("a").string) == ["locked.js"])
    }

    @Test("Cleanup cancelled before it starts deletes nothing")
    func cancelledBeforeStarting() async throws {
        let temporary = try TemporaryDirectory()
        try Tree {
            File("app/node_modules/a.js")
            File("installer.dmg")
        }.materialize(at: temporary.path)
        let scan = try await Self.scan(temporary.path)

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Cleanup().run(scan.candidates)
        }.value

        #expect(result.removed.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(result.notStarted.map(\.path) == scan.candidates.map(\.path))
        for candidate in scan.candidates {
            #expect(DarwinFileSystem().exists(at: candidate.path))
        }
    }

    private static func scan(_ home: FilePath) async throws -> ScanResult {
        let rules = CompiledRules(try loadInlineRules(rules: Self.rules), home: home.string)
        return try await DiskScanner(rules: rules, root: home, fileSystem: DarwinFileSystem(), workerCount: 3).scan()
    }
}
