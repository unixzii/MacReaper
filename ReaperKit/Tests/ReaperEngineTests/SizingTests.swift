import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import System
import Testing

@Suite("Sizing")
struct SizingTests {

    /// In memory, as on APFS, a file of `bytes` bytes allocates whole 4 KiB blocks.
    static func blocks(_ bytes: Int) -> UInt64 {
        UInt64((bytes + 4095) / 4096 * 4096)
    }

    static let rules = """
          - id: t.modules
            when: { name: node_modules }
            action: { claim: a }
          - id: t.dmg
            when: { kind: file, name: "*.dmg" }
            action: { claim: a }
        """

    @Test("Files and directories inside a candidate add up")
    func plainSizes() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("app/node_modules/a.js", contents: String(repeating: "a", count: 10_000))
            File("app/node_modules/dep/b.js", contents: String(repeating: "b", count: 100))
            File("app/node_modules/dep/empty.js")
            Directory("app/node_modules/dep/nested/deeper")
        }

        let size = try await Self.size(of: "app/node_modules", in: harness)

        #expect(size == CandidateSize(
            allocated: Self.blocks(10_000) + Self.blocks(100),
            reclaimable: Self.blocks(10_000) + Self.blocks(100),
            files: 3,
            directories: 4,
            isComplete: true
        ))
    }

    @Test("A hard-linked file counts once, and is reclaimable only with every link inside")
    func hardLinks() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("store/shared.js", contents: String(repeating: "s", count: 5_000))
            HardLink("app/node_modules/shared.js", to: "store/shared.js")
            File("app/node_modules/own.js", contents: String(repeating: "o", count: 5_000))
            HardLink("app/node_modules/own-again.js", to: "app/node_modules/own.js")
        }

        let size = try await Self.size(of: "app/node_modules", in: harness)

        #expect(size.files == 3)
        #expect(size.allocated == 2 * Self.blocks(5_000))
        // own.js has both links inside; shared.js keeps a link in store/, so deleting frees nothing.
        #expect(size.reclaimable == Self.blocks(5_000))
    }

    @Test("A file hard-linked into two candidates counts once in the total")
    func hardLinksAcrossCandidates() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("one/node_modules/lib.js", contents: String(repeating: "l", count: 8_000))
            HardLink("two/node_modules/lib.js", to: "one/node_modules/lib.js")
        }

        let result = try await harness.scan()

        let sizes = result.candidates.compactMap(\.size)
        #expect(sizes.map(\.allocated) == [Self.blocks(8_000), Self.blocks(8_000)])
        #expect(sizes.map(\.reclaimable) == [0, 0])
        #expect(result.totalSize?.allocated == Self.blocks(8_000))
        // Deleting both candidates removes both links.
        #expect(result.totalSize?.reclaimable == Self.blocks(8_000))
    }

    @Test("Clones are allocated but not reclaimable while their twin survives")
    func clones() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("cache/package.tgz", contents: String(repeating: "p", count: 20_000))
            Clone("app/node_modules/package.tgz", of: "cache/package.tgz")
        }

        let size = try await Self.size(of: "app/node_modules", in: harness)

        #expect(size.allocated == Self.blocks(20_000))
        #expect(size.reclaimable == 0)
    }

    @Test("Claimed files are sized too")
    func fileCandidates() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("Downloads/installer.dmg", contents: String(repeating: "d", count: 30_000))
            File("Downloads/notes.txt")
        }

        let size = try await Self.size(of: "Downloads/installer.dmg", in: harness)

        #expect(size == CandidateSize(allocated: Self.blocks(30_000), reclaimable: Self.blocks(30_000), files: 1, directories: 0))
    }

    @Test("Sizing can be turned down")
    func sizingModes() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("app/node_modules/a.js", contents: "a")
        }
        func scan(_ sizing: Sizing) async throws -> ScanResult {
            try await DiskScanner(rules: harness.rules, fileSystem: harness.fileSystem, now: Harness.now, sizing: sizing, workerCount: 2).scan()
        }

        let none = try await scan(.none)
        let allocated = try await scan(.allocated)

        #expect(none.candidates.allSatisfy { $0.size == nil })
        #expect(none.totalSize == nil)
        #expect(allocated.candidates.first?.size?.allocated == Self.blocks(1))
        #expect(allocated.candidates.first?.size?.reclaimable == nil)
        #expect(allocated.totalSize?.reclaimable == nil)
    }

    @Test("Unreadable parts make a size incomplete; other volumes are left out")
    func incompleteAndOtherVolumes() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("app/node_modules/a.js", contents: "a")
            Directory("app/node_modules/locked", failure: .permissionDenied)
            Directory("app/node_modules/mounted", device: 9) {
                File("big.bin", contents: String(repeating: "x", count: 50_000))
            }
        }

        let result = try await harness.scan()
        let size = try #require(result.candidates.first?.size)

        #expect(!size.isComplete)
        #expect(size.allocated == Self.blocks(1))
        #expect(result.errors.map { harness.relative($0.path) } == ["app/node_modules/locked"])
    }

    @Test("Sizes on disk match sizes in memory")
    func diskParity() async throws {
        let temporary = try TemporaryDirectory()
        let tree = Tree {
            File("app/node_modules/a.js", contents: String(repeating: "a", count: 10_000))
            File("app/node_modules/dep/b.js", contents: String(repeating: "b", count: 70_000))
            File("store/shared.js", contents: String(repeating: "s", count: 9_000))
            HardLink("app/node_modules/shared.js", to: "store/shared.js")
            File("cache/package.tgz", contents: String(repeating: "p", count: 40_000))
            Clone("app/node_modules/package.tgz", of: "cache/package.tgz")
            File("Downloads/old.dmg", contents: String(repeating: "d", count: 12_345))
        }
        try tree.materialize(at: temporary.path)
        let loaded = try loadInlineProfile(rules: Self.rules)
        let rules = CompiledRules(loaded, home: temporary.path.string)

        let onDisk = try await DiskScanner(rules: rules, fileSystem: DarwinFileSystem(), workerCount: 4).scan()
        let inMemory = try await DiskScanner(
            rules: rules,
            fileSystem: InMemoryFileSystem(root: temporary.path, tree: tree),
            workerCount: 4
        ).scan()

        #expect(onDisk.candidates.map(\.path) == inMemory.candidates.map(\.path))
        #expect(onDisk.candidates.map(\.size) == inMemory.candidates.map(\.size))
        #expect(onDisk.totalSize == inMemory.totalSize)
        #expect(onDisk.candidates.count == 2)
    }

    private static func size(of path: String, in harness: Harness) async throws -> CandidateSize {
        let result = try await harness.scan(workers: 4)
        let candidate = try #require(result.candidates.first { harness.relative($0.path) == path }, "\(path) was not claimed")
        return try #require(candidate.size)
    }
}
