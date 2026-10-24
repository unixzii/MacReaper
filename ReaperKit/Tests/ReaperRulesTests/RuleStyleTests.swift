import ReaperRules
import Testing
import Yams

/// The house style for the rule files that ship with MacReaper, as the rule format's style
/// section describes it. User rule files should follow it too, but the loader does not enforce it.
@Suite("Shipped rule style")
struct RuleStyleTests {

    static let ruleSetKeys = ["format", "id", "title", "description", "categories", "rules"]
    static let categoryKeys = ["title", "symbol", "detail", "safety"]
    static let ruleKeys = ["id", "description", "when", "action"]
    static let conditionKeys = [
        "kind", "name", "path", "capture", "contains", "containsAny", "sibling", "scope", "olderThan", "check",
    ]

    static let sources = try! RuleSources.builtin()

    @Test("Rule sets", arguments: sources.ruleSets.keys.sorted())
    func ruleSet(_ id: String) throws {
        let text = Self.sources.ruleSets[id]!.text
        #expect(text.hasPrefix("# yaml-language-server: $schema=../schema/rule-set.schema.json\n"))

        let document = try #require(try Yams.compose(yaml: text)?.mapping)
        #expect(Self.isOrdered(Self.keys(document), by: Self.ruleSetKeys), "top-level key order")

        for (name, category) in document["categories"]?.mapping ?? [:] {
            let fields = try #require(category.mapping)
            let categoryID = name.string ?? "?"
            #expect(Self.isOrdered(Self.keys(fields), by: Self.categoryKeys), "\(categoryID): category key order")
            #expect(fields["symbol"] != nil, "\(categoryID): no symbol")
        }

        var stage = 0
        for rule in try #require(document["rules"]?.sequence) {
            let fields = try #require(rule.mapping)
            let ruleID = fields["id"]?.string ?? "?"
            #expect(Self.isOrdered(Self.keys(fields), by: Self.ruleKeys), "\(ruleID): rule key order")
            #expect(fields["description"] != nil, "\(ruleID): no description")
            let when = try #require(fields["when"]?.mapping)
            #expect(Self.isOrdered(Self.keys(when), by: Self.conditionKeys), "\(ruleID): condition key order")

            let action = try #require(fields["action"]?.mapping)
            let kind = Self.keys(action).first ?? ""
            let thisStage = ["skip": 0, "pushScope": 1, "claim": 2][kind] ?? 3
            #expect(thisStage >= stage, "\(ruleID): rules go skips, then scopes, then claims")
            stage = max(stage, thisStage)

            if let long = action[kind]?.mapping {
                let onlyKey = kind == "claim" ? "category" : "name"
                #expect(Self.keys(long) != [onlyKey], "\(ruleID): use the short form of \(kind)")
            }
        }
    }

    private static func keys(_ mapping: Node.Mapping) -> [String] {
        mapping.keys.compactMap(\.string)
    }

    private static func isOrdered(_ keys: [String], by order: [String]) -> Bool {
        let positions = keys.map { order.firstIndex(of: $0) ?? order.count }
        return positions == positions.sorted()
    }
}
