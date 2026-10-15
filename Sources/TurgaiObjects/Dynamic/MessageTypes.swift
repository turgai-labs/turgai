import DiscoverableActors
import Foundation

// The types of messages: what objects take is typed, as Erlang specs type a module's messages;
// the objects themselves aren't.

/// A message with its typed parameters, and the type of its reply, if it has one:
/// `raiseRequested(amount: number, worker: salary answers)`, `salary() -> number`.
public struct Signature: Codable, Sendable, Equatable {
    public let name: String
    public let parameters: [Parameter]
    public let reply: ValueType?

    public init(name: String, parameters: [Parameter], reply: ValueType? = nil) {
        self.name = name
        self.parameters = parameters
        self.reply = reply
    }

    public var written: String {
        "\(name)(\(parameters.map { "\($0.name): \($0.type.written)" }.joined(separator: ", ")))"
            + (reply.map { " -> \($0.written)" } ?? "")
    }
}

public struct Parameter: Codable, Sendable, Equatable {
    public let name: String
    public let type: ValueType

    public init(name: String, type: ValueType) {
        self.name = name
        self.type = type
    }
}

/// The type of a value, as a set of values: `integer` is in `number`, and an object that behaves
/// like another is in `object`.
public enum ValueType: Codable, Sendable, Hashable {
    case string, integer, number, boolean, list
    /// Any object, unchecked until a message reaches it.
    case object
    /// An object that behaves like the object with this name: it runs the same behavior.
    case like(String)

    public static let builtin: [ValueType] = [.string, .integer, .number, .boolean, .list, .object]

    public var written: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .list: "list"
        case .object: "object"
        case .like(let name): "like \(name)"
        }
    }

    /// `an integer`, `a number`, `an object like Bob`.
    public var withArticle: String {
        switch self {
        case .integer, .object: "an \(written)"
        case .like(let name): "an object like \(name)"
        default: "a \(written)"
        }
    }

    public var schema: JSONValue {
        switch self {
        case .string: ["type": "string"]
        case .integer: ["type": "integer"]
        case .number: ["type": "number"]
        case .boolean: ["type": "boolean"]
        case .list: ["type": "array", "items": ["type": "string"]]
        case .object: ["x-actor-reference": true]
        case .like(let name): ["x-actor-reference": true, "description": .string("An object like \(name).")]
        }
    }

    /// The type of a literal value, if it has one we know.
    init?(of value: JSONValue) {
        switch value {
        case .string: self = .string
        case .integer, .unsignedInteger: self = .integer
        case .number: self = .number
        case .bool: self = .boolean
        case .array: self = .list
        case .object, .null: return nil
        }
    }

    /// Whether a value received for this type is one: checked again on every message.
    func accepts(_ value: JSONValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.boolean, .bool), (.integer, .integer), (.integer, .unsignedInteger),
            (.number, .number), (.number, .integer), (.number, .unsignedInteger), (.list, .array),
            (.object, .object), (.like, .object):
            true
        case (.integer, .number(let number)): number.rounded() == number
        default: false
        }
    }
}

/// A behavior that can't be read, linked or run, explained the way Elm explains a mistake.
public struct BehaviorError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension Signature {
    /// What the message takes, as a JSON schema; nil when it takes nothing.
    public var input: JSONValue? {
        parameters.isEmpty
            ? nil
            : [
                "type": "object",
                "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.type.schema) })),
                "required": .array(parameters.map { .string($0.name) }),
            ]
    }
}

extension JSONValue {
    /// The value on one line, as YAML's flow style writes it: `[1, 2]`, `{number: 2}`, `text`.
    public var inline: String {
        switch self {
        case .null: "null"
        case .bool(let bool): "\(bool)"
        case .integer(let integer): "\(integer)"
        case .unsignedInteger(let integer): "\(integer)"
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? "\(Int64(number))" : "\(number)"
        case .string(let text): text
        case .array(let items): "[\(items.map(\.inline).joined(separator: ", "))]"
        case .object(let members): "{\(members.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.inline)" }.joined(separator: ", "))}"
        }
    }

    var numeric: Double? {
        switch self {
        case .integer(let integer): Double(integer)
        case .unsignedInteger(let integer): Double(integer)
        case .number(let number): number
        default: nil
        }
    }

    var isNumeric: Bool { numeric != nil }

    var negated: JSONValue? {
        switch self {
        case .integer(let integer): .integer(-integer)
        case .unsignedInteger(let integer): .number(-Double(integer))
        case .number(let number): .number(-number)
        default: nil
        }
    }

    var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    /// Equal as values: `2` and `2.0` are the same number.
    func sameValue(as other: JSONValue) -> Bool {
        if let a = numeric, let b = other.numeric { return a == b }
        return self == other
    }

    /// The sum of two numbers, a whole number when both are.
    func adding(_ other: JSONValue) -> JSONValue? {
        switch (self, other) {
        case (.integer(let a), .integer(let b)): return .integer(a + b)
        default:
            guard let a = numeric, let b = other.numeric else { return nil }
            return .number(a + b)
        }
    }
}

extension JSONValue {
    /// The Swift type a value of this schema is, as code writes it: as its code wrote it, when it
    /// says, and otherwise an object is an `Object`.
    public var swiftType: String {
        if case .string(let type)? = self[ObjectShape.Message.swiftTypeKey] { return type }
        if let name = typeName { return name }
        if self["x-actor-reference"] == .bool(true) || self["x-takes"] != nil { return "Object" }
        // A value or nothing: `T?`.
        if case .array(let options)? = self["anyOf"], options.count == 2, let null = options.firstIndex(of: ["type": "null"]) {
            return options[1 - null].declaredType(optional: true)
        }
        switch self["type"] {
        case "string": return "String"
        case "integer": return "Int"
        case "number": return "Double"
        case "boolean": return "Bool"
        case "array": return "[" + (self["items"]?.swiftType ?? "Any") + "]"
        default:
            if let values = self["additionalProperties"], case .object = values { return "[String: \(values.swiftType)]" }
            return "[String: Any]"
        }
    }
}
