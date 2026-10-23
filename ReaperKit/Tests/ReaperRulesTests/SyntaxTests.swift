import ReaperRules
import Testing

@Suite("Glob syntax")
struct GlobTests {

    @Test("Tokens")
    func tokens() throws {
        let glob = try Glob("~/a*b?[!x-z]\\*", flavor: .path)

        #expect(glob.tokens == [
            .literal("~"), .literal("/"), .literal("a"), .anyRun, .literal("b"), .anyCharacter,
            .characterClass(ranges: ["x"..."z"], isNegated: true), .literal("*"),
        ])
    }

    @Test("A ] right after [ is a member")
    func leadingBracketInClass() throws {
        let glob = try Glob("[]a]", flavor: .name)

        #expect(glob.tokens == [.characterClass(ranges: ["]"..."]", "a"..."a"], isNegated: false)])
    }

    @Test("Literal characters", arguments: [("*", false), ("?*", false), ("[ab]", false), ("*.app", true), ("\\*", true)])
    func hasLiteral(pattern: String, expected: Bool) throws {
        #expect(try Glob(pattern, flavor: .name).hasLiteral == expected)
    }

    @Test("Patterns are NFC-normalized")
    func normalization() throws {
        #expect(try Glob("Cafe\u{301}", flavor: .name).pattern == "Caf\u{E9}")
    }

    @Test("Invalid globs", arguments: [
        ("a/b", Glob.Flavor.name), ("a**", .name), ("[abc", .name), ("[z-a]", .name), ("a\\", .name),
        ("Library/Caches", .path), ("relative/**", .path),
    ])
    func invalid(pattern: String, flavor: Glob.Flavor) {
        #expect(throws: GlobSyntaxError.self) { try Glob(pattern, flavor: flavor) }
    }

    @Test("** is allowed in path globs")
    func doubleStarInPath() throws {
        #expect(try Glob("~/Developer/**/build", flavor: .path).tokens.contains(.anyPath))
    }
}

@Suite("Template syntax")
struct TemplateTests {

    @Test("Segments")
    func segments() throws {
        let template = try Template("{stem}.tex in {{braces}} at {scope.project.root}")

        #expect(template.segments == [
            .variable("stem"), .literal(".tex in {braces} at "), .variable("scope.project.root"),
        ])
        #expect(template.variables == ["stem", "scope.project.root"])
    }

    @Test("Malformed templates", arguments: ["{name", "name}", "{}", "{a{b}"])
    func malformed(text: String) {
        #expect(throws: TemplateSyntaxError.self) { try Template(text) }
    }
}

@Suite("Glob matching")
struct GlobMatchingTests {

    @Test("Name globs", arguments: [
        ("target", "target", true), ("target", "targets", false),
        ("*.app", "Tool.app", true), ("*.app", ".app", true), ("*.app", "Tool.apps", false),
        ("a?c", "abc", true), ("a?c", "ac", false),
        ("[!x-z]b", "ab", true), ("[!x-z]b", "yb", false),
        ("\\*", "*", true), ("\\*", "a", false),
        ("IntelliJIdea*", "IntelliJIdea2025.2", true), ("IntelliJIdea*", "PyCharm2025.1", false),
        ("a*b*c", "aXbYc", true), ("a*b*c", "aXbY", false),
        ("*", "anything", true),
        ("Caf\u{E9}", "Cafe\u{301}", true),
    ])
    func names(pattern: String, subject: String, expected: Bool) throws {
        #expect(try Glob(pattern, flavor: .name).matches(subject) == expected)
    }

    @Test("Path globs", arguments: [
        ("/u/Library/Caches/*", "/u/Library/Caches/Homebrew", true),
        ("/u/Library/Caches/*", "/u/Library/Caches/Homebrew/downloads", false),
        ("/u/**/build", "/u/a/b/build", true),
        ("/u/**/build", "/u/build", false),
        ("/u/*DeviceSupport/*", "/u/iOS DeviceSupport/17.4 (21E219)", true),
        ("/u/?", "/u//", false),
        ("/u/[!x]", "/u//", false),
    ])
    func paths(pattern: String, subject: String, expected: Bool) throws {
        #expect(try Glob(pattern, flavor: .path).matches(subject) == expected)
    }

    @Test("Shapes")
    func shapes() throws {
        #expect(try Glob("node_modules", flavor: .name).shape == .literal("node_modules"))
        #expect(try Glob("*.csproj", flavor: .name).shape == .suffix(".csproj"))
        #expect(try Glob("~/Library/Caches/*", flavor: .path).shape == .child(of: "~/Library/Caches"))
        #expect(try Glob("~/Library/*DeviceSupport/*", flavor: .path).shape == .other(literalPrefix: "~/Library/"))
        #expect(try Glob("IntelliJ*", flavor: .name).shape == .other(literalPrefix: "IntelliJ"))
    }

    @Test("~ expands to the home directory, with glob characters in it escaped")
    func homeExpansion() throws {
        let glob = try Glob("~/Library/*", flavor: .path).expandingHome("/Users/a[1]")

        #expect(glob.matches("/Users/a[1]/Library/Caches"))
        #expect(!glob.matches("/Users/a1/Library/Caches"))
        #expect(glob.shape == .child(of: "/Users/a[1]/Library"))
    }
}
