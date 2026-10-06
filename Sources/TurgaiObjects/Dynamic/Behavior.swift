import DiscoverableActors
import Foundation

/// How objects of one kind answer messages, the way an Erlang module does: the fields each
/// object keeps, and `receive` clauses that say what to do with a message. Written once, at
/// runtime, and run by any number of objects, each with its own field values.
///
/// It has no code: a clause matches a message by name, guards compare values with a fixed set
/// of operators, and actions are a fixed set too. What it accepts is typed: each message has
/// typed parameters, and the protocols it `speaks` say which messages others can count on.
public struct Behavior: Codable, Sendable, Equatable {
    public let name: String
    /// What it was read from: read again when a protocol it uses changes, and shown back.
    public let source: Written
    /// The protocols it handles in full.
    public let speaks: [MessageProtocol]
    public let fields: [String: Field]
    /// The state an object starts in, or `nil` for one without states.
    public let initial: String?
    public let clauses: [Clause]

    /// A field: a starting value, or another object it talks to, by name.
    public enum Field: Codable, Sendable, Equatable {
        case value(JSONValue)
        /// An object it talks to, by name or handle, such as `shop` or `Ann`.
        case object(String)

        public var initial: JSONValue {
            switch self {
            case .value(let value): value
            case .object(let name): ["object": .string(name)]
            }
        }

        /// The type of what it holds, as far as it's known.
        public var type: ValueType? {
            switch self {
            case .value(let value): ValueType(of: value)
            case .object: .object
            }
        }
    }

    /// One way to handle a message: in a state, if its guards hold, run its actions.
    public struct Clause: Codable, Sendable, Equatable {
        public let state: String?
        public let message: Signature
        public let guards: [Guard]
        public let actions: [Action]
        public let next: String?
    }

    /// A value an action or a guard uses: written as it is, or a parameter, a field, or the object
    /// itself.
    public enum Value: Codable, Sendable, Equatable {
        case literal(JSONValue)
        case parameter(String)
        case field(String)
        case me
        /// Text with values in it, such as `'You have {count} cups'`.
        case text([TextPart])
    }

    /// A piece of text with values in it: text as written, or a value written in braces.
    public enum TextPart: Codable, Sendable, Equatable {
        case text(String)
        case value(Value)
    }

    public struct Guard: Codable, Sendable, Equatable {
        public let left: Value
        public let comparison: Comparison
        public let right: Value?
    }

    public enum Comparison: String, Codable, Sendable, Equatable, CaseIterable {
        case lessThan = "<", atMost = "<=", greaterThan = ">", atLeast = ">=", equal = "==", notEqual = "!="
        case contains, isEmpty = "is empty", isNotEmpty = "is not empty"
    }

    public enum Action: Codable, Sendable, Equatable {
        case set(field: String, to: Value)
        case add(Value, to: String)
        case subtract(Value, from: String)
        case append(Value, to: String)
        case remove(Value, from: String)
        case send(to: Target, message: String, arguments: [Argument])
        case reply(Value)
    }

    public struct Argument: Codable, Sendable, Equatable {
        public let name: String
        public let value: Value
    }

    /// Who a `send` goes to.
    public enum Target: Codable, Sendable, Equatable {
        case parameter(String)
        case field(String)
        case me
        /// Another object, by its name or handle, such as `shop`.
        case object(String)
    }

    /// Every message it takes, in the order first written.
    public var messages: [Signature] {
        var seen: [Signature] = []
        for clause in clauses where !seen.contains(where: { $0.name == clause.message.name }) {
            seen.append(clause.message)
        }
        return seen
    }

    /// The names of the messages it takes in `state`.
    public func messages(in state: String?) -> [String] {
        var names: [String] = []
        for clause in clauses where clause.state == nil || clause.state == state {
            if !names.contains(clause.message.name) { names.append(clause.message.name) }
        }
        return names
    }

    /// Everything it takes, which is what `self` speaks.
    public var accepted: MessageProtocol {
        MessageProtocol(name: name, messages: messages)
    }
}

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

/// The type of a value, as a set of values: `integer` is in `number`, and an object that speaks
/// a protocol is in `object`.
public enum ValueType: Codable, Sendable, Hashable {
    case string, integer, number, boolean, list
    /// Any object, unchecked until a message reaches it.
    case object
    /// An object that speaks the protocol with this name.
    case speaks(String)

    public static let builtin: [ValueType] = [.string, .integer, .number, .boolean, .list, .object]

    public var written: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .list: "list"
        case .object: "object"
        case .speaks(let name): name
        }
    }

    /// `an integer`, `a number`, `an object that speaks salary answers`.
    public var withArticle: String {
        switch self {
        case .integer, .object: "an \(written)"
        case .speaks(let name): "an object that speaks \(name)"
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
        case .speaks(let name): ["x-actor-reference": true, "description": .string("An object that speaks \(name).")]
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
            (.object, .object), (.speaks, .object):
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

    static let example = """
            fields:
              count: 0
            receive:
              - on: addCup()
                do:
                  - add: 1 to count
              - on: howMany()
                reply: count
        """
}
