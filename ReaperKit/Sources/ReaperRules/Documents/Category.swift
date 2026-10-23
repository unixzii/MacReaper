import Yams

/// How much care a category needs before cleanup. Ordered from least to most.
public enum Safety: String, Hashable, Comparable, Sendable, CaseIterable {
    case safe
    case review
    case dangerous

    public static func < (lhs: Safety, rhs: Safety) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct Category: Sendable {

    public var id: Located<String>
    public var title: String
    /// The name of an SF Symbol for the app to show with the category.
    public var symbol: String?
    public var detail: String?
    public var safety: Safety
}

// MARK: - Reading

extension Category {

    /// Reads one entry of a rule set's `categories` map.
    init?(id key: Located<String>, _ node: Node, reader: inout DocumentReader) {
        let id = reader.identifier(key, "the category id", form: .id)
        guard let fields = reader.mapping(
            node,
            "category `\(key.value)`",
            allowed: ["title", "symbol", "detail", "safety"],
            required: ["title", "safety"]
        ) else {
            return nil
        }
        let title = fields["title"].flatMap { reader.text($0, "`title`") }
        let symbol = fields["symbol"].flatMap { reader.text($0, "`symbol`") }
        let detail = fields["detail"].flatMap { reader.string($0, "`detail`") }
        let safety = fields["safety"].flatMap { reader.safety($0, "`safety`") }
        guard let id, let title, let safety else {
            return nil
        }
        self.init(id: id, title: title.value, symbol: symbol?.value, detail: detail?.value, safety: safety.value)
    }
}
