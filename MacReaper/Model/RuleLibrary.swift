import Foundation
import ReaperRules

/// The profiles the app can scan with, each loaded and compiled when the app starts.
struct RuleLibrary {

    struct Profile: Identifiable {

        let id: String
        let title: String
        /// The compiled rules, or every problem that keeps the profile's rule files from loading.
        let rules: Result<CompiledRules, RuleDiagnostics>
    }

    /// Sorted by id.
    let profiles: [Profile]

    init(sources: RuleSources, home: String) {
        profiles = sources.profiles.keys.sorted().map { id in
            do throws(RuleDiagnostics) {
                let loaded = try RuleLoader.loadProfile(id, from: sources)
                return Profile(id: id, title: loaded.profile.title, rules: .success(CompiledRules(loaded, home: home)))
            } catch {
                return Profile(id: id, title: id, rules: .failure(error))
            }
        }
    }

    /// The rule sets and profiles that ship with the app.
    static func builtin(home: String) -> RuleLibrary {
        do {
            return RuleLibrary(sources: try RuleSources.builtin(), home: home)
        } catch {
            fatalError("The built-in rules are missing from the app bundle: \(error)")
        }
    }

    subscript(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }
}
