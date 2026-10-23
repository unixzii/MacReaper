import Darwin
import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import Synchronization
import System
import Testing

@Suite("DiskScanner")
struct ScannerTests {

    /// Every field that must not depend on scheduling, in a comparable form.
    private static func canonical(_ result: ScanResult, _ harness: Harness) -> [String] {
        result.candidates.map { candidate in
            [
                harness.relative(candidate.path),
                harness.names(candidate.categories).joined(separator: "+"),
                harness.names(candidate.rules).joined(separator: "+"),
                candidate.safety.rawValue,
                candidate.group ?? "-",
                candidate.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                candidate.provenance.map { "\(harness.rules[$0.scope])@\(harness.relative($0.root))" }.joined(separator: ">"),
                candidate.size.map { "\($0.allocated)/\($0.reclaimable ?? 0) in \($0.files)f \($0.directories)d \($0.isComplete)" } ?? "unsized",
            ].joined(separator: " | ")
        }
    }

    @Test("Results do not depend on worker count or listing order", arguments: [1, 2, 8])
    func determinism(workers: Int) async throws {
        let reference = try Harness(shippedProfile: "home", tree: Fixture.tree)
        let referenceResult = try await reference.scan()
        let expected = Self.canonical(referenceResult, reference)

        for seed in UInt64(0)..<10 {
            let shuffled = try Harness(shippedProfile: "home", order: .shuffled(seed: seed), tree: Fixture.tree)
            let result = try await shuffled.scan(workers: workers)
            #expect(Self.canonical(result, shuffled) == expected, "seed \(seed)")
            #expect(result.totalSize == referenceResult.totalSize, "seed \(seed)")
            #expect(result.stats.directories == referenceResult.stats.directories)
        }
    }

    @Test("Many workers on a wide, deep tree find everything")
    func wideTree() async throws {
        let harness = try Harness(rules: """
              - id: t.project
                when: { contains: package.json }
                action: { pushScope: { name: project, set: { project: "{name}" } } }
              - id: t.modules
                when: { name: node_modules, scope: { name: project, distance: 1 } }
                action: { claim: a }
            """) {
            for group in 0..<40 {
                for project in 0..<25 {
                    File("Developer/group-\(group)/project-\(project)/package.json")
                    Directory("Developer/group-\(group)/project-\(project)/node_modules/dep")
                    Directory("Developer/group-\(group)/project-\(project)/src/components/deep/er")
                }
            }
        }

        let result = try await harness.scan(workers: 8)

        #expect(result.candidates.count == 1_000)
        #expect(Set(result.candidates.map(\.group)).count == 25)
        #expect(result.errors.isEmpty)
    }

    @Test("Directories on another volume are not entered")
    func otherVolumes() async throws {
        let harness = try Harness(rules: Self.nodeModulesRule) {
            File("Developer/app/package.json")
            Directory("Developer/app/node_modules")
            Directory("Volumes/External", device: 7) {
                Directory("node_modules")
            }
        }

        let result = try await harness.scan()

        #expect(result.candidates.map { harness.relative($0.path) } == ["Developer/app/node_modules"])
        #expect(result.stats.otherVolumes == 1)
    }

    @Test("Unreadable and dataless directories are reported, and the scan carries on")
    func unreadableDirectories() async throws {
        let harness = try Harness(rules: Self.nodeModulesRule) {
            Directory("locked", failure: .permissionDenied) {
                Directory("node_modules")
            }
            Directory("icloud", flags: UInt32(SF_DATALESS)) {
                Directory("node_modules")
            }
            Directory("readable/node_modules")
        }

        let result = try await harness.scan()

        #expect(result.candidates.map { harness.relative($0.path) } == ["readable/node_modules"])
        #expect(result.errors.map { harness.relative($0.path) } == ["icloud", "locked"])
        #expect(result.errors.map(\.error) == [.dataless, .permissionDenied])
    }

    @Test("maxDepth limits how deep the walk goes")
    func maxDepth() async throws {
        let harness = try Harness(rules: Self.nodeModulesRule, maxDepth: 2) {
            Directory("a/node_modules")
            Directory("a/b/node_modules")
        }

        let result = try await harness.scan()

        #expect(result.candidates.map { harness.relative($0.path) } == ["a/node_modules"])
    }

    @Test("Excluded paths are not visited")
    func exclude() async throws {
        let harness = try Harness(rules: Self.nodeModulesRule, exclude: ["~/Developer/archive/**"]) {
            Directory("Developer/archive/old/node_modules")
            Directory("Developer/current/node_modules")
        }

        let result = try await harness.scan()

        #expect(result.candidates.map { harness.relative($0.path) } == ["Developer/current/node_modules"])
        #expect(result.stats.excluded == 1)
    }

    @Test("Missing roots are ignored, and nested roots are walked once")
    func roots() async throws {
        let harness = try Harness(rules: Self.nodeModulesRule, roots: ["~", "~/Developer", "~/missing"]) {
            Directory("Developer/app/node_modules")
        }

        let result = try await harness.scan(workers: 4)

        #expect(result.candidates.map { harness.relative($0.path) } == ["Developer/app/node_modules"])
        #expect(result.errors.isEmpty)
    }

    @Test("A cancelled scan throws and stops listing")
    func cancellation() async throws {
        let base = InMemoryFileSystem(root: Harness.home) {
            for index in 0..<2_000 {
                Directory("Developer/project-\(index)/src")
            }
        }
        let fileSystem = SlowFileSystem(base: base, delay: .milliseconds(2))
        let harness = try Harness(rules: Self.nodeModulesRule) {}
        let scanner = DiskScanner(rules: harness.rules, fileSystem: fileSystem, now: Harness.now, workerCount: 4)

        let task = Task { try await scanner.scan() }
        while fileSystem.listings < 20 {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let listingsAtCancel = fileSystem.listings
        try await Task.sleep(for: .milliseconds(50))
        #expect(fileSystem.listings < 200)
        #expect(fileSystem.listings - listingsAtCancel <= 4, "workers stop after their current directory")
    }

    static let nodeModulesRule = """
          - id: t.modules
            when: { name: node_modules }
            action: { claim: a }
        """
}
