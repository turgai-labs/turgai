import DiscoverableActors

/// Text that is YAML, such as a behavior or an object's field values, kept apart from other
/// strings so a name can't be passed where YAML is meant. To a model it's a string.
public struct YAML: Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public init(stringLiteral text: String) {
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public var description: String { text }

    /// The value it holds, read strictly.
    public func read() throws(UnreadableYAML) -> JSONValue {
        try YAMLDocument.read(text)
    }
}

extension YAML: Describable {
    public static var jsonSchema: JSONValue {
        ["type": "string", "description": "YAML."]
    }
}
