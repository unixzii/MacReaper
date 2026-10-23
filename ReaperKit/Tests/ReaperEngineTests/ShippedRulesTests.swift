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

        #expect(harness.names(claim.categories) == ["rust.target"])
        #expect(harness.names(claim.rules) == ["rust.target"])
        #expect(claim.group == "dua-cli")
        #expect(claim.isPreselected)
    }

    @Test("A target with only .rustc_info.json is still Rust output")
    func rustTargetWithoutTag() throws {
        #expect(try harness.claim("Developer/napi-mod/target").map { harness.names($0.categories) } == ["rust.target"])
    }

    @Test("node_modules is claimed with its package as the group")
    func nodeModules() throws {
        let claim = try #require(try harness.claim("Developer/webapp/node_modules"))

        #expect(harness.names(claim.categories) == ["node.modules"])
        #expect(claim.group == "webapp")
    }

    @Test("A tagged cache with no specific rule falls back to the generic category")
    func genericCache() throws {
        let claim = try #require(try harness.claim("Developer/tool-out/fancy-cache"))

        #expect(harness.names(claim.categories) == ["core.cachedir-tagged"])
        #expect(claim.safety == .review)
        #expect(!claim.isPreselected)
    }

    @Test("Skips", arguments: [
        ("Developer/repo/.git", "core.skip-vcs"),
        ("Developer/Tool.app", "core.skip-app-bundles"),
        ("Library/Mobile Documents", "core.skip-cloud"),
    ])
    func skips(path: String, rule: String) throws {
        guard case .skip(let rules) = try harness.outcome(path) else {
            Issue.record("\(path) should be skipped")
            return
        }
        #expect(harness.names(rules).contains(rule))
    }

    @Test("A folder named like a bundle is not a bundle")
    func bundleLookalike() throws {
        #expect(try harness.outcome("Library/Caches/com.example.app").isDescend)
    }
}
