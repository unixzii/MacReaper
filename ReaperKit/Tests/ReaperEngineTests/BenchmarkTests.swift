import Foundation
import ReaperEngine
import ReaperFS
import ReaperRules
import Testing

/// Scans the real `~/Developer` and `~/Library/Developer`, read-only, with the shipped rules.
/// Opt in with `REAPER_BENCH=1 swift test -c release --filter BenchmarkTests`.
@Suite("Benchmark", .enabled(if: ProcessInfo.processInfo.environment["REAPER_BENCH"] != nil), .serialized)
struct BenchmarkTests {

    static let configurations: [(workers: Int, sizing: Sizing)] = [
        (1, .none),
        (ProcessInfo.processInfo.activeProcessorCount, .none),
        (ProcessInfo.processInfo.activeProcessorCount, .allocated),
        (ProcessInfo.processInfo.activeProcessorCount, .allocatedAndReclaimable),
    ]

    @Test("Real folders", arguments: configurations)
    func realFolders(workers: Int, sizing: Sizing) async throws {
        var sources = try RuleSources.builtin()
        let profile = sources.profiles["developer"]!.text
        sources.profiles["developer"]!.text = profile.replacingOccurrences(
            of: "roots: [~/Developer, ~/Projects, ~/src]",
            with: "roots: [~/Developer, ~/Library/Developer]"
        )
        let loaded = try RuleLoader.loadProfile("developer", from: sources)
        let rules = CompiledRules(loaded, home: NSHomeDirectory())

        let result = try await DiskScanner(rules: rules, fileSystem: DarwinFileSystem(), sizing: sizing, workerCount: workers).scan()

        let stats = result.stats
        let seconds = Double(stats.duration.components.seconds) + Double(stats.duration.components.attoseconds) / 1e18
        var line = "workers \(workers), sizing \(sizing): \(result.candidates.count) candidates, "
            + "\(stats.directories) directories + \(stats.files) files in \(String(format: "%.2f", seconds)) s"
        if let total = result.totalSize {
            line += String(format: "; %.2f GB allocated in %d files", Double(total.allocated) / 1e9, total.files)
            if let reclaimable = total.reclaimable {
                line += String(format: ", %.2f GB reclaimable", Double(reclaimable) / 1e9)
            }
        }
        print(line)

        if sizing == .allocatedAndReclaimable {
            var byCategory: [String: (count: Int, allocated: UInt64, reclaimable: UInt64)] = [:]
            for candidate in result.candidates {
                let name = candidate.categories.map { rules[$0].name }.joined(separator: "+")
                let size = candidate.size ?? CandidateSize()
                byCategory[name, default: (0, 0, 0)].count += 1
                byCategory[name, default: (0, 0, 0)].allocated += size.allocated
                byCategory[name, default: (0, 0, 0)].reclaimable += size.reclaimable ?? 0
            }
            for (name, total) in byCategory.sorted(by: { $0.value.allocated > $1.value.allocated }) {
                print(String(format: "  %8.2f GB allocated %8.2f GB reclaimable  %4d × %@",
                             Double(total.allocated) / 1e9, Double(total.reclaimable) / 1e9, total.count, name))
            }
            let incomplete = result.candidates.filter { $0.size?.isComplete == false }.count
            print("  \(incomplete) candidates incomplete, \(result.errors.count) errors")
        }
        #expect(!result.candidates.isEmpty)
    }
}
