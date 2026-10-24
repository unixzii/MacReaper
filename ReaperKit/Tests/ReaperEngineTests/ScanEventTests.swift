import Foundation
import ReaperEngine
import ReaperFS
import ReaperFSTesting
import ReaperRules
import System
import Testing

@Suite("Scan events")
struct ScanEventTests {

    /// Collects every event of a scan.
    static func events(_ scanner: DiskScanner, every interval: Duration = .milliseconds(5)) async throws -> (updates: [ScanUpdate], result: ScanResult) {
        var updates: [ScanUpdate] = []
        var result: ScanResult?
        for try await event in scanner.events(every: interval) {
            #expect(result == nil, "nothing may follow the finished event")
            switch event {
            case .update(let update): updates.append(update)
            case .finished(let finished): result = finished
            }
        }
        return (updates, try #require(result))
    }

    @Test("Updates add up to the result: every candidate found once and sized once")
    func updatesMatchResult() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)
        let scanner = DiskScanner(rules: harness.rules, root: Harness.home, fileSystem: harness.fileSystem, now: Harness.now, workerCount: 4)

        let (updates, result) = try await Self.events(scanner)

        let found = updates.flatMap(\.found).map(\.path)
        let sized = updates.flatMap(\.sized)
        #expect(found.count == Set(found).count)
        #expect(Set(found) == Set(result.candidates.map(\.path)))
        #expect(sized.count == result.candidates.count)
        let finalSizes = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.path, $0.size) })
        for candidate in sized {
            #expect(finalSizes[candidate.path] == candidate.size, "\(candidate.path)")
        }
        #expect(updates.flatMap(\.found).allSatisfy { $0.size == nil })

        let last = try #require(updates.last?.progress)
        #expect(last.phase == .finished)
        #expect(last.candidates == result.candidates.count)
        #expect(last.sizedCandidates == result.candidates.count)
        #expect(last.directories == result.stats.directories)
        #expect(last.files == result.stats.files)
        #expect(last.allocated == result.candidates.reduce(0) { $0 + ($1.size?.allocated ?? 0) })
        #expect(last.currentDirectory == nil)
    }

    @Test("Progress only moves forward")
    func progressIsMonotonic() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)
        let scanner = DiskScanner(rules: harness.rules, root: Harness.home, fileSystem: harness.fileSystem, now: Harness.now, workerCount: 4)

        let (updates, _) = try await Self.events(scanner)

        let order: [ScanPhase: Int] = [.detecting: 0, .sizing: 1, .finished: 2]
        for (previous, next) in zip(updates, updates.dropFirst()) {
            #expect(order[previous.progress.phase]! <= order[next.progress.phase]!)
            #expect(previous.progress.directories <= next.progress.directories)
            #expect(previous.progress.candidates <= next.progress.candidates)
            #expect(previous.progress.sizedCandidates <= next.progress.sizedCandidates)
            #expect(previous.progress.elapsed <= next.progress.elapsed)
        }
    }

    @Test("Without sizing, nothing is sized")
    func noSizing() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)
        let scanner = DiskScanner(rules: harness.rules, root: Harness.home, fileSystem: harness.fileSystem, now: Harness.now, sizesCandidates: false, workerCount: 2)

        let (updates, result) = try await Self.events(scanner)

        #expect(updates.allSatisfy { $0.sized.isEmpty })
        #expect(updates.last?.progress.allocated == 0)
        #expect(updates.last?.progress.candidates == result.candidates.count)
    }

    @Test("Updates are coalesced to the interval")
    func throttling() async throws {
        let fileSystem = SlowFileSystem(base: InMemoryFileSystem(root: Harness.home) {
            for index in 0..<200 {
                Directory("Developer/project-\(index)/node_modules")
            }
        }, delay: .milliseconds(2))
        let rules = try Harness(rules: ScannerTests.nodeModulesRule) {}.rules
        let scanner = DiskScanner(rules: rules, root: Harness.home, fileSystem: fileSystem, now: Harness.now, workerCount: 2)
        let clock = ContinuousClock()
        let start = clock.now

        let (updates, result) = try await Self.events(scanner, every: .milliseconds(50))

        let ticks = (clock.now - start) / .milliseconds(50)
        #expect(updates.count >= 2)
        #expect(Double(updates.count) <= ticks + 2)
        #expect(updates.map(\.found.count).reduce(0, +) == result.candidates.count)
    }

    @Test("Ending the iteration early cancels the scan")
    func earlyExit() async throws {
        let fileSystem = SlowFileSystem(base: InMemoryFileSystem(root: Harness.home) {
            for index in 0..<2_000 {
                Directory("Developer/project-\(index)/src")
            }
        }, delay: .milliseconds(2))
        let rules = try Harness(rules: ScannerTests.nodeModulesRule) {}.rules
        let scanner = DiskScanner(rules: rules, root: Harness.home, fileSystem: fileSystem, now: Harness.now, workerCount: 4)

        for try await event in scanner.events(every: .milliseconds(10)) {
            if case .update = event {
                break
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        let listings = fileSystem.listings
        try await Task.sleep(for: .milliseconds(100))
        #expect(fileSystem.listings == listings, "workers keep listing after the consumer left")
        #expect(listings < 500)
    }
}

@Suite("ScanSession")
@MainActor
struct ScanSessionTests {

    @Test("A session shows candidates and sizes, and ends with the result")
    func completes() async throws {
        let harness = try Harness.shipped(tree: Fixture.tree)
        let session = ScanSession(
            scanner: DiskScanner(rules: harness.rules, root: Harness.home, fileSystem: harness.fileSystem, now: Harness.now, workerCount: 4),
            updateInterval: .milliseconds(5)
        )

        session.start()
        #expect(session.isScanning)
        await session.waitUntilDone()

        guard case .finished(let result) = session.state else {
            Issue.record("expected the session to finish, got \(session.state)")
            return
        }
        #expect(session.candidates.map(\.path) == result.candidates.map(\.path))
        #expect(session.candidates.allSatisfy { $0.size != nil })
        #expect(session.progress?.phase == .finished)
        #expect(session.candidates.count == Fixture.expected.count)
    }

    @Test("A session can be cancelled, and started again")
    func cancels() async throws {
        let fileSystem = SlowFileSystem(base: InMemoryFileSystem(root: Harness.home) {
            for index in 0..<2_000 {
                Directory("Developer/project-\(index)/node_modules")
            }
        }, delay: .milliseconds(2))
        let rules = try Harness(rules: ScannerTests.nodeModulesRule) {}.rules
        let session = ScanSession(
            scanner: DiskScanner(rules: rules, root: Harness.home, fileSystem: fileSystem, now: Harness.now, workerCount: 4),
            updateInterval: .milliseconds(10)
        )

        session.start()
        while session.progress == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        session.cancel()
        await session.waitUntilDone()

        guard case .cancelled = session.state else {
            Issue.record("expected the session to be cancelled, got \(session.state)")
            return
        }
        #expect(session.candidates.count < 2_000)

        session.start()
        #expect(session.isScanning)
        #expect(session.candidates.isEmpty)
        session.cancel()
        await session.waitUntilDone()
    }
}
