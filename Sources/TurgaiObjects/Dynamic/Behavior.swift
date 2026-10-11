import DiscoverableActors
import Foundation

/// How objects of one kind answer messages, the way an Erlang module does: the fields each
/// object keeps, and `receive` clauses that say what to do with a message. Written once, at
/// runtime, and run by any number of objects, each with its own field values.
///
/// It has no code: a clause matches a message by name, guards compare values with a fixed set
/// of operators, and actions are a fixed set too. What it accepts is typed: each message has
/// typed parameters, and an object's type is its behavior, so references to it are checked
/// against what it takes.
public struct Behavior: Codable, Sendable, Equatable {
    public let name: String
    /// What it was read from: read again when a behavior it refers to changes, and shown back.
    public let source: Written
    public let fields: [String: Field]
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
            case .object(let name): .like(name)
            }
        }
    }

    /// One way to handle a message: if its guards hold, run its actions.
    public struct Clause: Codable, Sendable, Equatable {
        public let message: Signature
        public let guards: [Guard]
        public let actions: [Action]
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

    /// Everything it takes: what `self` is, as a type.
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

extension Behavior {
    /// What a message does, in plain words: each clause's actions, and when it runs, such as
    /// "adds the given amount to cups" or "gives back cups". What the message is given reads as
    /// given, so it isn't mistaken for a value of that name.
    public func summary(of message: String) -> String {
        source.receive.filter { $0.on == message }.map { clause in
            let given = Set((clause.parameters ?? []).map(\.name))
            let doing = clause.actions.map { Self.phrase($0, given: given) }.joined(separator: ", then ")
            let when = clause.when.map { " when " + $0.map { Self.phrase($0, given: given) }.joined(separator: " and ") } ?? ""
            return (doing.isEmpty ? "does nothing" : doing) + when
        }.joined(separator: "; otherwise ")
    }

    /// A message's rules as Erlang reads its clauses, top to bottom: each with its condition, if
    /// it has one, and what it does in plain words, such as `if total <= limit → tells shop
    /// refundApproved(order: the given order)`, ending `otherwise → nothing` when nothing else
    /// takes it.
    public func rules(of message: String) -> [String] {
        let clauses = source.receive.filter { $0.on == message }
        var rules = clauses.map { clause -> String in
            let given = Set((clause.parameters ?? []).map(\.name))
            let doing = clause.actions.isEmpty ? "nothing" : clause.actions.map { Self.phrase($0, given: given) }.joined(separator: ", then ")
            guard let when = clause.when, !when.isEmpty else { return (clauses.count > 1 ? "otherwise → " : "→ ") + doing }
            return "if " + when.map { Self.written($0) }.joined(separator: " and ") + " → " + doing
        }
        if clauses.allSatisfy({ !($0.when ?? []).isEmpty }) { rules.append("otherwise → nothing") }
        return rules
    }

    /// A guard as it's chosen: `total <= limit`.
    static func written(_ condition: Written.Guard) -> String {
        func shown(_ value: Written.Value) -> String { phrase(value, given: []) }
        return [shown(condition.left), condition.comparison.symbol, condition.right.map(shown)].compactMap { $0 }.joined(separator: " ")
    }

    private static func phrase(_ action: Written.Action, given: Set<String>) -> String {
        func phrase(_ value: Written.Value) -> String { Self.phrase(value, given: given) }
        return switch action {
        case .set(let field, let value): "sets \(field) to \(phrase(value))"
        case .add(let value, let field): "adds \(phrase(value)) to \(field)"
        case .subtract(let value, let field): "subtracts \(phrase(value)) from \(field)"
        case .append(let value, let field): "appends \(phrase(value)) to \(field)"
        case .remove(let value, let field): "removes \(phrase(value)) from \(field)"
        case .send(let message, let target, let arguments):
            "tells \(phrase(target)) \(message)(\((arguments ?? []).map { "\($0.name): \(phrase($0.value))" }.joined(separator: ", ")))"
        case .reply(let value): "gives back \(phrase(value))"
        }
    }

    private static func phrase(_ condition: Written.Guard, given: Set<String>) -> String {
        func phrase(_ value: Written.Value) -> String { Self.phrase(value, given: given) }
        let comparison: String =
            switch condition.comparison {
            case .lessThan: "is less than"
            case .atMost: "is at most"
            case .greaterThan: "is more than"
            case .atLeast: "is at least"
            case .equal: "is"
            case .notEqual: "isn't"
            case .contains: "contains"
            case .isEmpty: "is empty"
            case .isNotEmpty: "isn't empty"
            }
        return [phrase(condition.left), comparison, condition.right.map(phrase)].compactMap { $0 }.joined(separator: " ")
    }

    static func phrase(_ value: Written.Value, given: Set<String>) -> String {
        switch value {
        case .name(let name) where given.contains(name): "the given \(name)"
        case .name(let name), .object(let name): name
        case .number(let number): number.rounded() == number ? String(Int(number)) : String(number)
        case .text(let text): "'\(text)'"
        case .boolean(let flag): String(flag)
        case .list(let items): "[" + items.joined(separator: ", ") + "]"
        }
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

extension Behavior {
    /// An object running this behavior, holding `values`, as a model reads it: what it holds, and
    /// each action with what it does in plain words. A runtime object and a draft answer alike.
    public func description(title: String, values: [String: JSONValue]) -> ObjectDescription {
        var properties: [String: JSONValue] = [:]
        for name in fields.keys {
            var schema = Self.schema(of: values[name] ?? .null)
            schema["readOnly"] = true
            properties[name] = .object(schema)
        }
        var actions: [String: ObjectAction] = [:]
        for message in messages {
            actions[message.name] = ObjectAction(
                description: summary(of: message.name), input: message.input, output: message.reply?.schema)
        }
        return ObjectDescription(title: title, description: nil, properties: properties, actions: actions)
    }

    static func schema(of value: JSONValue) -> [String: JSONValue] {
        switch value {
        case .array: ["type": "array"]
        case .string: ["type": "string"]
        case .bool: ["type": "boolean"]
        case .integer, .unsignedInteger: ["type": "integer"]
        case .number: ["type": "number"]
        case .object(let members) where members["object"] != nil || members["id"] != nil: ["x-actor-reference": true]
        case .object: ["type": "object"]
        case .null: [:]
        }
    }
}
