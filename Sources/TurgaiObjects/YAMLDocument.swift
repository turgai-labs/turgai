import DiscoverableActors
import Yams

/// YAML as models write it, read strictly into JSON: quoted text is text, and of plain words
/// only `null`, `true`, `false` and numbers are anything else, so `no` or `08:30` stay text.
/// JSON is YAML too, so it reads the same way.
public enum YAMLDocument {
    public static func read(_ text: String) throws(UnreadableYAML) -> JSONValue {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .null }
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw UnreadableYAML(explanation: YAMLExplanation.explain(error))
        }
        return try node.map(json(from:)) ?? .null
    }

    private static func json(from node: Node) throws(UnreadableYAML) -> JSONValue {
        switch node {
        case .scalar(let scalar):
            guard scalar.style == .plain else { return .string(scalar.string) }
            switch scalar.string {
            case "", "~", "null": return .null
            case "true": return true
            case "false": return false
            case let word:
                if let integer = Int64(word) { return .integer(integer) }
                if let number = Double(word), number.isFinite { return .number(number) }
                return .string(word)
            }
        case .mapping(let mapping):
            var members: [String: JSONValue] = [:]
            for (key, value) in mapping {
                guard let name = key.string else {
                    throw UnreadableYAML(explanation: "A key must be text, such as `title`.")
                }
                members[name] = try json(from: value)
            }
            return .object(members)
        case .sequence(let sequence):
            var items: [JSONValue] = []
            for item in sequence { items.append(try json(from: item)) }
            return .array(items)
        case .alias:
            throw UnreadableYAML(
                explanation: "This uses a YAML alias (`*name`). Write the value out where it's used instead.")
        }
    }
}

/// YAML that couldn't be read, explained the way Elm explains a mistake.
public struct UnreadableYAML: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let explanation: String

    public init(explanation: String) {
        self.explanation = explanation
    }

    public var description: String { explanation }
}
