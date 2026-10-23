import Foundation

/// A parsed glob. Patterns are stored NFC-normalized.
public struct Glob: Hashable, Sendable {

    public enum Flavor: Sendable {
        /// Matches one entry name: no `/`, no `**`.
        case name
        /// Matches an absolute path; must start with `/` or `~/`.
        case path
    }

    public enum Token: Hashable, Sendable {
        case literal(Unicode.Scalar)
        /// `*`: any run of characters except `/`.
        case anyRun
        /// `?`: one character except `/`.
        case anyCharacter
        /// `**`: any run of characters including `/`.
        case anyPath
        /// `[abc]`, `[a-z]` or `[!abc]`.
        case characterClass(ranges: [ClosedRange<Unicode.Scalar>], isNegated: Bool)
    }

    public let pattern: String
    public let flavor: Flavor
    public let tokens: [Token]
    /// The structure of the glob, as far as the rule index and fast matching care.
    public let shape: Shape

    public init(_ pattern: String, flavor: Flavor) throws(GlobSyntaxError) {
        let normalized = pattern.precomposedStringWithCanonicalMapping
        if flavor == .path, !(normalized.hasPrefix("/") || normalized.hasPrefix("~/")) {
            throw GlobSyntaxError("a path glob must be absolute or start with ~/")
        }
        self.pattern = normalized
        self.flavor = flavor
        self.tokens = try Self.tokenize(Array(normalized.unicodeScalars), flavor: flavor)
        self.shape = Self.shape(of: tokens, flavor: flavor)
    }

    /// Whether the glob contains at least one literal character, which the scanner's index needs.
    public var hasLiteral: Bool {
        tokens.contains { token in
            if case .literal = token { true } else { false }
        }
    }

    private static func tokenize(_ scalars: [Unicode.Scalar], flavor: Flavor) throws(GlobSyntaxError) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\\":
                guard index + 1 < scalars.count else {
                    throw GlobSyntaxError("a trailing \\ escapes nothing")
                }
                tokens.append(.literal(scalars[index + 1]))
                index += 2
            case "*" where index + 1 < scalars.count && scalars[index + 1] == "*":
                guard flavor == .path else {
                    throw GlobSyntaxError("** is only allowed in path globs")
                }
                tokens.append(.anyPath)
                index += 2
            case "*":
                tokens.append(.anyRun)
                index += 1
            case "?":
                tokens.append(.anyCharacter)
                index += 1
            case "[":
                let (token, end) = try characterClass(scalars, openingAt: index)
                tokens.append(token)
                index = end + 1
            case "/" where flavor == .name:
                throw GlobSyntaxError("a name glob cannot contain /")
            default:
                tokens.append(.literal(scalar))
                index += 1
            }
        }
        return tokens
    }

    /// Parses the class opening at `start`, returning it and the index of its closing `]`. A `]`
    /// right after `[` or `[!` is a member, not the end.
    private static func characterClass(
        _ scalars: [Unicode.Scalar],
        openingAt start: Int
    ) throws(GlobSyntaxError) -> (Token, Int) {
        var index = start + 1
        let isNegated = index < scalars.count && scalars[index] == "!"
        if isNegated {
            index += 1
        }
        var ranges: [ClosedRange<Unicode.Scalar>] = []
        let firstMember = index
        while index < scalars.count, scalars[index] != "]" || index == firstMember {
            var lower = scalars[index]
            if lower == "\\", index + 1 < scalars.count {
                index += 1
                lower = scalars[index]
            }
            if index + 2 < scalars.count, scalars[index + 1] == "-", scalars[index + 2] != "]" {
                let upper = scalars[index + 2]
                guard lower <= upper else {
                    throw GlobSyntaxError("the range \(lower)-\(upper) is reversed")
                }
                ranges.append(lower...upper)
                index += 3
            } else {
                ranges.append(lower...lower)
                index += 1
            }
        }
        guard index < scalars.count else {
            throw GlobSyntaxError("the character class has no closing ]")
        }
        return (.characterClass(ranges: ranges, isNegated: isNegated), index)
    }
}

public struct GlobSyntaxError: Error, Sendable {

    public var message: String

    init(_ message: String) {
        self.message = message
    }
}

// MARK: - Matching

extension Glob {

    public enum Shape: Hashable, Sendable {
        /// No wildcards: the glob matches exactly this string.
        case literal(String)
        /// `*` followed by literal characters: the glob matches names ending in this string.
        case suffix(String)
        /// A literal directory path followed by `/*`: the glob matches the directory's children.
        case child(of: String)
        /// Anything else. Every match starts with the literal prefix.
        case other(literalPrefix: String)
    }

    private static func shape(of tokens: [Token], flavor: Flavor) -> Shape {
        let literalPrefix = String(String.UnicodeScalarView(tokens.lazy.prefix { $0.literal != nil }.compactMap(\.literal)))
        let rest = tokens.dropFirst(literalPrefix.unicodeScalars.count)
        if rest.isEmpty {
            return .literal(literalPrefix)
        }
        if flavor == .name, literalPrefix.isEmpty, rest.first == .anyRun, rest.dropFirst().allSatisfy({ $0.literal != nil }) {
            return .suffix(String(String.UnicodeScalarView(rest.dropFirst().compactMap(\.literal))))
        }
        if flavor == .path, rest.count == 1, rest.first == .anyRun, literalPrefix.count > 1, literalPrefix.hasSuffix("/") {
            return .child(of: String(literalPrefix.dropLast()))
        }
        return .other(literalPrefix: literalPrefix)
    }

    /// A path glob with a leading `~` replaced by `home`. Other globs are returned unchanged.
    public func expandingHome(_ home: String) -> Glob {
        guard flavor == .path, pattern.hasPrefix("~/") else {
            return self
        }
        let escapedHome = home.unicodeScalars.map { "*?[\\".unicodeScalars.contains($0) ? "\\\($0)" : String($0) }.joined()
        // The expanded pattern is as valid as the original, so this cannot fail.
        return try! Glob(escapedHome + pattern.dropFirst(), flavor: .path)
    }

    /// Whether the glob matches the whole of `subject`, compared after NFC normalization.
    public func matches(_ subject: String) -> Bool {
        let subject = subject.precomposedForMatching
        switch shape {
        case .literal(let literal):
            return subject == literal
        case .suffix(let suffix):
            return subject.utf8.count >= suffix.utf8.count && subject.utf8.reversed().starts(with: suffix.utf8.reversed())
        case .child(let parent):
            // `parent/*`: everything after `parent/` must be free of slashes.
            let bytes = subject.utf8
            guard bytes.count > parent.utf8.count, bytes.starts(with: parent.utf8) else {
                return false
            }
            let rest = bytes.dropFirst(parent.utf8.count)
            return rest.first == UInt8(ascii: "/") && !rest.dropFirst().contains(UInt8(ascii: "/"))
        case .other(let literalPrefix):
            // Most subjects differ within the literal prefix, which needs no matching.
            guard subject.utf8.starts(with: literalPrefix.utf8) else {
                return false
            }
            return Self.match(tokens, Array(subject.unicodeScalars))
        }
    }

    /// Matches by dynamic programming over subject positions: after each token, `reachable[i]`
    /// says whether the tokens so far can consume exactly the first `i` scalars.
    private static func match(_ tokens: [Token], _ subject: [Unicode.Scalar]) -> Bool {
        var reachable = [Bool](repeating: false, count: subject.count + 1)
        var next = reachable
        reachable[0] = true
        for token in tokens {
            for index in next.indices {
                next[index] = false
            }
            switch token {
            case .anyRun, .anyPath:
                var running = false
                for index in 0...subject.count {
                    let canExtend = index > 0 && (token == .anyPath || subject[index - 1] != "/")
                    running = reachable[index] || (running && canExtend)
                    next[index] = running
                }
            default:
                for index in 0..<subject.count where reachable[index] && token.matches(subject[index]) {
                    next[index + 1] = true
                }
            }
            guard next.contains(true) else {
                return false
            }
            swap(&reachable, &next)
        }
        return reachable[subject.count]
    }
}

private extension Glob.Token {

    var literal: Unicode.Scalar? {
        if case .literal(let scalar) = self { scalar } else { nil }
    }

    /// Whether a single-character token matches `scalar`. No single-character token matches `/`.
    func matches(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .literal(let literal):
            literal == scalar
        case .anyCharacter:
            scalar != "/"
        case .characterClass(let ranges, let isNegated):
            scalar != "/" && ranges.contains { $0.contains(scalar) } != isNegated
        case .anyRun, .anyPath:
            false
        }
    }
}

extension String {

    /// The string in NFC, skipping the work for ASCII, which is already normalized.
    var precomposedForMatching: String {
        utf8.allSatisfy { $0 < 0x80 } ? self : precomposedStringWithCanonicalMapping
    }
}
