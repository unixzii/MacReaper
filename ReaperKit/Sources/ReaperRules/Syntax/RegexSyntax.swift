/// Validation of the regular expressions in rules, and in check arguments.
public enum RegexSyntax {

    /// Compiles `pattern` with Swift `Regex` and returns the names of its named groups.
    ///
    /// - Returns: The group names, or the compiler's complaint.
    public static func groupNames(in pattern: String) -> Result<Set<String>, RegexSyntaxError> {
        do {
            _ = try Regex(pattern)
        } catch {
            return .failure(RegexSyntaxError(message: "\(error)"))
        }
        return .success(scanGroupNames(pattern))
    }

    /// `Regex` does not expose its capture names before matching, so read them from the
    /// pattern: `(?<name>` and `(?P<name>`, but not the lookbehinds `(?<=` and `(?<!`, and not
    /// inside character classes or after a backslash.
    private static func scanGroupNames(_ pattern: String) -> Set<String> {
        var names: Set<String> = []
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        var inClass = false
        while index < scalars.count {
            switch scalars[index] {
            case "\\":
                index += 2
                continue
            case "[":
                inClass = true
            case "]":
                inClass = false
            case "(" where !inClass:
                var nameStart = -1
                if scalars[index...].starts(with: "(?<".unicodeScalars) {
                    nameStart = index + 3
                } else if scalars[index...].starts(with: "(?P<".unicodeScalars) {
                    nameStart = index + 4
                }
                if nameStart >= 0, nameStart < scalars.count, scalars[nameStart] != "=", scalars[nameStart] != "!",
                   let end = scalars[nameStart...].firstIndex(of: ">") {
                    names.insert(String(String.UnicodeScalarView(scalars[nameStart..<end])))
                }
            default:
                break
            }
            index += 1
        }
        return names
    }
}

public struct RegexSyntaxError: Error {

    public var message: String
}
