import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import Synchronization
import System
import Testing

@Suite("Sizing")
struct SizingTests {

    static let block: UInt64 = 4_096

    /// In memory, as on APFS, a file of `bytes` bytes allocates whole 4 KiB blocks.
    static func blocks(_ bytes: Int) -> UInt64 {
        UInt64((bytes + 4095) / 4096) * block
    }

    static func contents(blocks: Int) -> String {
        String(repeating: "x", count: blocks * Int(block) - 7)
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
        let size = try await Self.size(of: "app/node_modules") {
            File("app/node_modules/a.js", contents: String(repeating: "a", count: 10_000))
            File("app/node_modules/dep/b.js", contents: String(repeating: "b", count: 100))
            File("app/node_modules/dep/empty.js")
            Directory("app/node_modules/dep/nested/deeper")
        }

        #expect(size == CandidateSize(allocated: Self.blocks(10_000) + Self.blocks(100), files: 3, directories: 4))
        #expect(!size.mayFreeLess)
    }

    @Test("A hard-linked file counts once, and is held while a link outside remains")
    func hardLinks() async throws {
        let size = try await Self.size(of: "app/node_modules") {
            File("store/shared.js", contents: Self.contents(blocks: 3))
            HardLink("app/node_modules/shared.js", to: "store/shared.js")
            File("app/node_modules/own.js", contents: Self.contents(blocks: 1))
            HardLink("app/node_modules/own-again.js", to: "app/node_modules/own.js")
        }

        // own.js has both links inside; shared.js keeps a link in store/.
        #expect(size == CandidateSize(allocated: 4 * Self.block, hardLinkedBytes: 3 * Self.block, hardLinkedFiles: 1, files: 3, directories: 1))
        #expect(size.mayFreeLess)
    }

    @Test("A file hard-linked into two candidates is held by each, but not by both together")
    func hardLinksAcrossCandidates() async throws {
        let result = try await Self.scan {
            File("one/node_modules/lib.js", contents: Self.contents(blocks: 2))
            HardLink("two/node_modules/lib.js", to: "one/node_modules/lib.js")
        }

        #expect(result.candidates.compactMap(\.size?.hardLinkedBytes) == [2 * Self.block, 2 * Self.block])
        #expect(result.totalSize == CandidateSize(allocated: 2 * Self.block, files: 2, directories: 2))
    }

    @Test("Clones count in full, and as shared, wherever their twins are")
    func clones() async throws {
        let split = try await Self.size(of: "app/node_modules") {
            File("cache/package.tgz", contents: Self.contents(blocks: 5))
            Clone("app/node_modules/package.tgz", of: "cache/package.tgz")
            File("app/node_modules/own.js", contents: Self.contents(blocks: 2))
        }
        let inside = try await Self.size(of: "app/node_modules") {
            File("app/node_modules/a.bin", contents: Self.contents(blocks: 5))
            Clone("app/node_modules/b.bin", of: "app/node_modules/a.bin")
        }

        #expect(split == CandidateSize(allocated: 7 * Self.block, clonedBytes: 5 * Self.block, clonedFiles: 1, files: 2, directories: 1))
        #expect(inside == CandidateSize(allocated: 10 * Self.block, clonedBytes: 10 * Self.block, clonedFiles: 2, files: 2, directories: 1))
    }

    @Test("Claimed files are sized from their listing")
    func fileCandidates() async throws {
        let plain = try await Self.size(of: "Downloads/installer.dmg") {
            File("Downloads/installer.dmg", contents: String(repeating: "d", count: 30_000))
            File("Downloads/notes.txt")
        }
        let linked = try await Self.size(of: "Downloads/installer.dmg") {
            File("Downloads/installer.dmg", contents: String(repeating: "d", count: 30_000))
            HardLink("Archive/installer.dmg", to: "Downloads/installer.dmg")
        }

        #expect(plain == CandidateSize(allocated: Self.blocks(30_000), files: 1))
        #expect(linked == CandidateSize(allocated: Self.blocks(30_000), hardLinkedBytes: Self.blocks(30_000), hardLinkedFiles: 1, files: 1))
    }

    @Test("Sizing can be turned off")
    func sizingOff() async throws {
        let harness = try Harness(rules: Self.rules) {
            File("app/node_modules/a.js", contents: "a")
        }

        let result = try await DiskScanner(rules: harness.rules, fileSystem: harness.fileSystem, now: Harness.now, sizesCandidates: false, workerCount: 2).scan()

        #expect(result.candidates.count == 1)
        #expect(result.candidates.allSatisfy { $0.size == nil })
        #expect(result.totalSize == nil)
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

    /// Sizing goes on from the listing that found a candidate, so nothing is listed twice.
    @Test("Every directory is listed once")
    func singlePass() async throws {
        let listed = Mutex<[FilePath]>([])
        var fileSystem = SlowFileSystem(base: InMemoryFileSystem(root: Harness.home, tree: Fixture.tree), delay: .zero)
        fileSystem.onListing = { _, path in
            listed.withLock { $0.append(path) }
        }
        let loaded = try RuleLoader.loadProfile("home", from: RuleSources.builtin())
        let rules = CompiledRules(loaded, home: Harness.home.string)

        let result = try await DiskScanner(rules: rules, fileSystem: fileSystem, now: Harness.now, workerCount: 4).scan()

        let paths = listed.withLock { $0 }
        #expect(paths.count == Set(paths).count, "listed twice: \(Dictionary(grouping: paths, by: \.self).filter { $0.value.count > 1 }.keys)")
        #expect(result.candidates.allSatisfy { $0.size != nil })
    }

    @Test("Sizes on disk match sizes in memory")
    func diskParity() async throws {
        let tree = Tree {
            File("app/node_modules/a.js", contents: String(repeating: "a", count: 10_000))
            File("app/node_modules/dep/b.js", contents: String(repeating: "b", count: 70_000))
            File("store/shared.js", contents: String(repeating: "s", count: 9_000))
            HardLink("app/node_modules/shared.js", to: "store/shared.js")
            File("cache/package.tgz", contents: String(repeating: "p", count: 40_000))
            Clone("app/node_modules/package.tgz", of: "cache/package.tgz")
            File("Downloads/old.dmg", contents: String(repeating: "d", count: 12_345))
        }

        let (onDisk, inMemory) = try await Self.scanOnDiskAndInMemory(tree)

        #expect(onDisk.candidates.count == 2)
        #expect(onDisk.candidates.map(\.size) == inMemory.candidates.map(\.size))
        #expect(onDisk.totalSize == inMemory.totalSize)
    }

    /// Random trees of files, hard links and clone chains, spread over three candidates and a
    /// store outside them. Each candidate's size, and the total, must match what the tree
    /// implies.
    @Test("Sizes match what random trees imply", arguments: 0..<150)
    func randomTrees(seed: UInt64) async throws {
        let random = RandomTree(seed: seed)
        let result = try await Self.scan(random.tree)

        for candidate in result.candidates {
            let relative = String(candidate.path.string.dropFirst(Harness.home.string.count + 1))
            #expect(candidate.size == random.expectedSize(of: [relative]), "seed \(seed), \(relative)")
        }
        let all = result.candidates.map { String($0.path.string.dropFirst(Harness.home.string.count + 1)) }
        #expect(result.totalSize == random.expectedSize(of: all), "seed \(seed)")
    }

    @Test("Random trees size the same on disk", arguments: 0..<6)
    func randomTreesOnDisk(seed: UInt64) async throws {
        let (onDisk, inMemory) = try await Self.scanOnDiskAndInMemory(RandomTree(seed: seed).tree)

        #expect(onDisk.candidates.map(\.size) == inMemory.candidates.map(\.size))
        #expect(onDisk.totalSize == inMemory.totalSize)
    }

    private static func scan(_ tree: Tree) async throws -> ScanResult {
        let rules = CompiledRules(try loadInlineProfile(rules: Self.rules), home: Harness.home.string)
        let fileSystem = InMemoryFileSystem(root: Harness.home, order: .shuffled(seed: 7), tree: tree)
        return try await DiskScanner(rules: rules, fileSystem: fileSystem, now: Harness.now, workerCount: 3).scan()
    }

    private static func scan(@TreeBuilder _ nodes: () -> [TreeNode]) async throws -> ScanResult {
        try await scan(Tree(nodes))
    }

    private static func size(of path: String, @TreeBuilder _ nodes: () -> [TreeNode]) async throws -> CandidateSize {
        let result = try await scan(nodes)
        let candidate = try #require(result.candidates.first { $0.path == Harness.home.appending(path) }, "\(path) was not claimed")
        return try #require(candidate.size)
    }

    private static func scanOnDiskAndInMemory(_ tree: Tree) async throws -> (onDisk: ScanResult, inMemory: ScanResult) {
        let temporary = try TemporaryDirectory()
        try tree.materialize(at: temporary.path)
        let rules = CompiledRules(try loadInlineProfile(rules: Self.rules), home: temporary.path.string)
        let onDisk = try await DiskScanner(rules: rules, fileSystem: DarwinFileSystem(), workerCount: 3).scan()
        let inMemory = try await DiskScanner(
            rules: rules,
            fileSystem: InMemoryFileSystem(root: temporary.path, tree: tree),
            workerCount: 3
        ).scan()
        #expect(onDisk.candidates.map(\.path) == inMemory.candidates.map(\.path))
        return (onDisk, inMemory)
    }
}

/// A random tree, and the sizes of its candidates, worked out from how it was built.
private struct RandomTree {

    static let locations = ["p0/node_modules", "p1/node_modules", "p2/node_modules", "store"]

    var tree = Tree {}
    /// The file each path names; hard links name the same file.
    private var fileOfPath: [String: Int] = [:]
    private var blocksOfFile: [Int] = []
    /// Files cloned from one another, by the first file of the group.
    private var groupOfFile: [Int: Int] = [:]

    init(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let operations = Int.random(in: 6...14, using: &generator)
        for index in 0..<operations {
            let path = "\(Self.locations.randomElement(using: &generator)!)/f\(index)"
            let existing = fileOfPath.keys.sorted()
            let choice = existing.isEmpty ? 0 : Int.random(in: 0..<10, using: &generator)
            if choice < 4 {
                let blocks = Int.random(in: 1...4, using: &generator)
                tree.nodes.append(File(path, contents: SizingTests.contents(blocks: blocks)).node)
                fileOfPath[path] = blocksOfFile.count
                blocksOfFile.append(blocks)
            } else if choice < 7 {
                let target = existing.randomElement(using: &generator)!
                tree.nodes.append(HardLink(path, to: target).node)
                fileOfPath[path] = fileOfPath[target]
            } else {
                let source = existing.randomElement(using: &generator)!
                let original = fileOfPath[source]!
                tree.nodes.append(Clone(path, of: source).node)
                let file = blocksOfFile.count
                fileOfPath[path] = file
                blocksOfFile.append(blocksOfFile[original])
                let group = groupOfFile[original] ?? original
                groupOfFile[original] = group
                groupOfFile[file] = group
            }
        }
    }

    /// The size of the candidate directories `candidates` together.
    func expectedSize(of candidates: [String]) -> CandidateSize {
        func isInside(_ path: String) -> Bool {
            candidates.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let inside = fileOfPath.filter { isInside($0.key) }
        var size = CandidateSize(files: inside.count)
        size.directories = Set(inside.keys.map { $0.split(separator: "/").dropLast().joined(separator: "/") }).count
        for file in Set(inside.values) {
            let bytes = UInt64(blocksOfFile[file]) * SizingTests.block
            size.allocated += bytes
            if fileOfPath.contains(where: { $0.value == file && !isInside($0.key) }) {
                size.hardLinkedBytes += bytes
                size.hardLinkedFiles += 1
            } else if groupOfFile[file] != nil {
                size.clonedBytes += bytes
                size.clonedFiles += 1
            }
        }
        return size
    }
}

/// SplitMix64, so random trees are the same on every run.
private struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
