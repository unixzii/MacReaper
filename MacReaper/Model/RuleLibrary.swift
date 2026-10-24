import Foundation
import ReaperEngine
import ReaperRules

/// Every rule set the app scans with, loaded and validated when the app starts.
struct RuleLibrary {

    /// The rule sets, or every problem that keeps them from loading.
    let rules: Result<LoadedRules, RuleDiagnostics>

    init(sources: RuleSources) {
        rules = Result { () throws(RuleDiagnostics) in try RuleLoader.load(sources) }
    }

    /// The rule sets that ship with the app.
    static func builtin() -> RuleLibrary {
        do {
            return RuleLibrary(sources: try RuleSources.builtin())
        } catch {
            fatalError("The built-in rules are missing from the app bundle: \(error)")
        }
    }
}
