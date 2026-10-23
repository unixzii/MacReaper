import ReaperFS
import ReaperRules

/// `version.superseded`: a sibling of the same group has a higher version, as in an old
/// `iPhone15,2 17.4 (21E219)` next to `iPhone15,2 18.1 (22B83)`.
///
/// The `pattern` argument's named groups `group` and `version` pick both out of a name; versions
/// are dot-separated integers compared component by component.
///
/// Facts:
/// - `supersededBy`: the name of the sibling with the highest version in the group.
struct VersionSuperseded: Check {

    let name = "version.superseded"

    func evaluate(_ entry: EntryContext, arguments: [String: ScalarValue], fileSystem: any FileSystem) -> Facts? {
        // Validation guarantees a pattern that compiles and has both groups.
        guard case .string(let pattern) = arguments["pattern"], let regex = try? Regex(pattern) else {
            return nil
        }
        func key(_ name: String) -> (group: Substring, version: [Int])? {
            guard let match = try? regex.firstMatch(in: name),
                  let group = match.output["group"]?.substring,
                  let version = match.output["version"]?.substring else {
                return nil
            }
            let components = version.split(separator: ".").compactMap { Int($0) }
            return components.isEmpty ? nil : (group, components)
        }

        guard let own = key(entry.name) else {
            return nil
        }
        let newest = entry.siblings.entries
            .compactMap { sibling in key(sibling.name).map { (name: sibling.name, key: $0) } }
            .filter { $0.key.group == own.group && own.version.lexicographicallyPrecedes($0.key.version) }
            .max { $0.key.version.lexicographicallyPrecedes($1.key.version) }
        return newest.map { ["supersededBy": .string($0.name)] }
    }
}
