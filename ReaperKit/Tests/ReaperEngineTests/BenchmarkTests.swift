import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import System
import Testing

/// Scans the real `~/Developer`, read-only, with the shipped rules, and
/// deletes a generated tree in a temporary directory.
/// Opt in with `REAPER_BENCH=1 swift test -c release --filter BenchmarkTests`.
@Suite("Benchmark", .enabled(if: ProcessInfo.processInfo.environment["REAPER_BENCH"] != nil), .serialized)
struct BenchmarkTests {

    static let configurations: [(workers: Int, sizes: Bool)] = [
        (1, false),
        (DiskScanner.defaultWorkerCount, false),
        (DiskScanner.defaultWorkerCount, true),
    ]

    @Test("Real folders", arguments: configurations)
    func realFolders(workers: Int, sizes: Bool) async throws {
        let rules = CompiledRules(try RuleLoader.load(RuleSources.builtin()), home: NSHomeDirectory())
        let root = FilePath(NSHomeDirectory()).appending("Developer")

        let result = try await DiskScanner(rules: rules, root: root, fileSystem: DarwinFileSystem(), sizesCandidates: sizes, workerCount: workers).scan()

        let stats = result.stats
        let seconds = Double(stats.duration.components.seconds) + Double(stats.duration.components.attoseconds) / 1e18
        var line = "workers \(workers), sized \(sizes): \(result.candidates.count) candidates, "
            + "\(stats.directories) directories + \(stats.files) files in \(String(format: "%.2f", seconds)) s"
        if let total = result.totalSize {
            line += String(format: "; %.2f GB allocated in %d files, %.2f GB shared", Double(total.allocated) / 1e9, total.files, Double(total.sharedBytes) / 1e9)
        }
        print(line)

        if sizes {
            var byCategory: [String: (count: Int, allocated: UInt64, shared: UInt64)] = [:]
            for candidate in result.candidates {
                let name = rules[candidate.category].name
                let size = candidate.size ?? CandidateSize()
                byCategory[name, default: (0, 0, 0)].count += 1
                byCategory[name, default: (0, 0, 0)].allocated += size.allocated
                byCategory[name, default: (0, 0, 0)].shared += size.sharedBytes
            }
            for (name, total) in byCategory.sorted(by: { $0.value.allocated > $1.value.allocated }) {
                print(String(format: "  %8.2f GB allocated %8.2f GB shared  %4d × %@",
                             Double(total.allocated) / 1e9, Double(total.shared) / 1e9, total.count, name))
            }
            let incomplete = result.candidates.filter { $0.size?.isComplete == false }.count
            print("  \(incomplete) candidates incomplete, \(result.errors.count) errors")
        }
        #expect(!result.candidates.isEmpty)
    }

    /// 96,000 small files in 12,000 folders, like a large `node_modules`.
    @Test("Deleting many small files", arguments: [1, Cleanup.defaultThreadCount])
    func deleting(threads: Int) async throws {
        let temporary = try TemporaryDirectory()
        let modules = temporary.path.appending("app/node_modules")
        var folders = [modules]
        var index = 0
        while folders.count < 12_000 {
            for child in 0..<6 where folders.count < 12_000 {
                folders.append(folders[index].appending("dir\(child)"))
            }
            index += 1
        }
        let contents = Data(repeating: 0x61, count: 2_000)
        for folder in folders {
            try FileManager.default.createDirectory(atPath: folder.string, withIntermediateDirectories: true)
            for file in 0..<8 {
                FileManager.default.createFile(atPath: folder.appending("file\(file).js").string, contents: contents)
            }
        }
        let rules = CompiledRules(
            try loadInlineRules(rules: "  - { id: t.modules, when: { name: node_modules }, action: { claim: a } }"),
            home: temporary.path.string
        )
        let scan = try await DiskScanner(rules: rules, root: temporary.path, fileSystem: DarwinFileSystem()).scan()

        let result = await Cleanup(threadCount: threads).run(scan.candidates)

        let seconds = Double(result.duration.components.seconds) + Double(result.duration.components.attoseconds) / 1e18
        print("threads \(threads): deleted \(scan.candidates.first?.size?.files ?? 0) files in \(String(format: "%.2f", seconds)) s")
        #expect(result.removed.count == 1)
    }
}
