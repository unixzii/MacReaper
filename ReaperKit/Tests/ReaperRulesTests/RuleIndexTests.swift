import ReaperRules
import Testing

@Suite("RuleIndex")
struct RuleIndexTests {

    let compiled: CompiledRules

    init() throws {
        compiled = try CompiledRulesTests.shipped()
    }

    @Test("Lookups find the rules filed under each kind of key", arguments: [
        // A literal name.
        Probe(name: "target", expected: ["rust.target", "maven.target"]),
        // A literal child.
        Probe(name: "dua-cli", children: ["Cargo.toml", "src"], expected: ["rust.project"]),
        // A name suffix.
        Probe(name: "Tool.app", expected: ["core.skip-app-bundles"]),
        // A child suffix.
        Probe(name: "service", children: ["App.csproj"], expected: ["dotnet.project"]),
        // The first component of a child path.
        Probe(name: "game", children: ["Assets", "ProjectSettings"], expected: ["unity.project"]),
        // The parent of a `dir/*` path.
        Probe(
            name: "App-abc",
            path: "/Users/test/Library/Developer/Xcode/DerivedData/App-abc",
            expected: ["xcode.derived-data", "xcode.derived-data-orphaned"]
        ),
        // A path glob no table can answer.
        Probe(
            name: "iPhone15,2 17.4 (21E219)",
            path: "/Users/test/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.4 (21E219)",
            expected: ["xcode.device-support-old"]
        ),
        // Files.
        Probe(name: "paper.aux", isFile: true, expected: ["latex.aux"]),
        Probe(name: "old.dmg", path: "/Users/test/Downloads/old.dmg", isFile: true, expected: ["macos.old-installers"]),
    ])
    func lookups(_ probe: Probe) {
        let found = Set(candidates(for: probe).map { compiled[$0].name })

        #expect(found.isSuperset(of: probe.expected), "found \(found.sorted())")
    }

    @Test("An ordinary source folder pulls up no rules")
    func ordinaryFolder() {
        let probe = Probe(name: "src", path: "/Users/test/Developer/app/src", children: ["main.rs", "lib.rs"])

        #expect(candidates(for: probe).isEmpty)
    }

    @Test("Candidates come back in rule id order")
    func order() {
        let ids = Array(candidates(for: Probe(name: "target", children: ["Cargo.toml", "package.json"])))

        #expect(ids == ids.sorted())
    }

    /// The index must never leave out a rule whose name, path and child conditions all hold.
    @Test("Lookups are a superset of a brute-force search")
    func superset() {
        var generator = SplitMix64(seed: 42)
        let vocabulary = Vocabulary(compiled.rules)
        var returned = 0
        var probes = 0

        for _ in 0..<5_000 {
            let probe = vocabulary.probe(using: &generator)
            let found = Set(candidates(for: probe))
            for rule in compiled.rules where (rule.condition.kind == .file) == probe.isFile && Self.couldHold(rule, probe) {
                #expect(found.contains(rule.id), "\(rule.name) missing for \(probe)")
            }
            returned += found.count
            probes += 1
        }
        // The point of the index: far fewer candidates than rules.
        #expect(Double(returned) / Double(probes) < Double(compiled.rules.count) / 10)
    }

    private func candidates(for probe: Probe) -> RuleSelection {
        let index = probe.isFile ? compiled.fileIndex : compiled.directoryIndex
        return index.candidates(name: probe.name, path: probe.path, children: probe.children)
    }

    /// Whether every name, path and child condition of the rule holds: the conditions the index
    /// can see. A child path counts as present when its first component is a child.
    private static func couldHold(_ rule: CompiledRule, _ probe: Probe) -> Bool {
        let condition = rule.condition
        func exists(_ pattern: ChildPattern) -> Bool {
            switch pattern {
            case .name(let glob): probe.children.contains { glob.matches($0) }
            case .path(let path): probe.children.contains(String(path.prefix { $0 != "/" }))
            }
        }
        return (condition.name.isEmpty || condition.name.contains { $0.matches(probe.name) })
            && (condition.path.isEmpty || condition.path.contains { $0.matches(probe.path) })
            && condition.contains.allSatisfy(exists)
            && (condition.containsAny.isEmpty || condition.containsAny.contains(where: exists))
    }
}

struct Probe: CustomTestStringConvertible, Sendable {

    var name: String
    var path: String
    var children: [String]
    var isFile: Bool
    var expected: Set<String>

    init(name: String, path: String? = nil, children: [String] = [], isFile: Bool = false, expected: Set<String> = []) {
        self.name = name
        self.path = path ?? "/Users/test/Developer/\(name)"
        self.children = children
        self.isFile = isFile
        self.expected = expected
    }

    var testDescription: String {
        "\(isFile ? "file" : "dir") \(path) [\(children.joined(separator: ", "))]"
    }
}

/// Names and paths built from the rules' own literals, so random probes hit rules often.
private struct Vocabulary {

    var names: [String] = ["src", "README.md", "build", "Library", "x"]
    var parents: [String] = ["/Users/test", "/Users/test/Developer/app", "/Users/test/Library"]

    init(_ rules: [CompiledRule]) {
        func add(_ glob: Glob) {
            switch glob.shape {
            case .literal(let text) where glob.flavor == .name:
                names.append(text)
            case .literal(let path):
                parents.append(String(path.prefix(upTo: path.lastIndex(of: "/")!)))
                names.append(String(path.suffix(from: path.index(after: path.lastIndex(of: "/")!))))
            case .suffix(let suffix):
                names.append("stem" + suffix)
            case .child(let parent):
                parents.append(parent)
            case .other(let prefix) where glob.flavor == .name:
                names.append(prefix + "2025.1")
            case .other(let prefix):
                parents.append(String(prefix.dropLast()) + "/iOS DeviceSupport")
            }
        }
        for rule in rules {
            rule.condition.name.forEach(add)
            rule.condition.path.forEach(add)
            for pattern in rule.condition.contains + rule.condition.containsAny {
                switch pattern {
                case .name(let glob): add(glob)
                case .path(let path): names.append(String(path.prefix { $0 != "/" }))
                }
            }
        }
    }

    func probe(using generator: inout SplitMix64) -> Probe {
        let name = names.randomElement(using: &generator)!
        let parent = parents.randomElement(using: &generator)!
        let children = (0..<Int.random(in: 0...4, using: &generator)).map { _ in names.randomElement(using: &generator)! }
        return Probe(name: name, path: parent + "/" + name, children: children, isFile: Bool.random(using: &generator))
    }
}

struct SplitMix64: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
