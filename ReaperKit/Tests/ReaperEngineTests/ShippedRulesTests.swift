import ReaperEngine
import ReaperFSTesting
import ReaperRules
import Testing

/// The shipped `home` profile, evaluated entry by entry on a small in-memory home folder.
@Suite("Shipped rules")
struct ShippedRulesTests {

    static let tag = "Signature: 8a477f597d28d172789f06886806bc55\n"

    let harness: Harness

    init() throws {
        harness = try Harness(shippedProfile: "home") {
            File("Developer/dua-cli/Cargo.toml")
            File("Developer/dua-cli/target/CACHEDIR.TAG", contents: Self.tag)
            File("Developer/napi-mod/Cargo.toml")
            File("Developer/napi-mod/target/.rustc_info.json", contents: "{}")
            File("Developer/webapp/package.json")
            Directory("Developer/webapp/node_modules/left-pad")
            File("Developer/tool-out/fancy-cache/CACHEDIR.TAG", contents: Self.tag)
            File("Developer/repo/.git/HEAD")
            File("Developer/Tool.app/Contents/Info.plist")
            Directory("Library/Caches/com.example.app")
            File("Library/Mobile Documents/proj/package.json")
        }
    }

    @Test("A Cargo target is claimed as Rust output, not as a generic tagged cache")
    func rustTarget() throws {
        let claim = try #require(try harness.claim("Developer/dua-cli/target"))

        #expect(harness.name(claim.category) == "rust.target")
        #expect(harness.name(claim.rule) == "rust.target")
        #expect(claim.provenance.last.map { harness.relative($0.root) } == "Developer/dua-cli")
        #expect(claim.isPreselected)
    }

    @Test("A target with only .rustc_info.json is still Rust output")
    func rustTargetWithoutTag() throws {
        #expect(try harness.claim("Developer/napi-mod/target").map { harness.name($0.category) } == "rust.target")
    }

    @Test("node_modules is claimed inside its package's scope")
    func nodeModules() throws {
        let claim = try #require(try harness.claim("Developer/webapp/node_modules"))

        #expect(harness.name(claim.category) == "node.modules")
        #expect(claim.provenance.last.map { harness.relative($0.root) } == "Developer/webapp")
    }

    @Test("A tagged cache with no specific rule falls back to the generic category")
    func genericCache() throws {
        let claim = try #require(try harness.claim("Developer/tool-out/fancy-cache"))

        #expect(harness.name(claim.category) == "core.cachedir-tagged")
        #expect(claim.safety == .review)
        #expect(!claim.isPreselected)
    }

    @Test("Skips", arguments: [
        ("Developer/repo/.git", "core.skip-vcs"),
        ("Developer/Tool.app", "core.skip-app-bundles"),
        ("Library/Mobile Documents", "core.skip-cloud"),
    ])
    func skips(path: String, rule: String) throws {
        guard case .skip(let skippedBy) = try harness.outcome(path) else {
            Issue.record("\(path) should be skipped")
            return
        }
        #expect(harness.name(skippedBy) == rule)
    }

    @Test("A folder named like a bundle is not a bundle")
    func bundleLookalike() throws {
        #expect(try harness.outcome("Library/Caches/com.example.app").isDescend)
    }
}
