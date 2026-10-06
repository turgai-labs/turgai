import AnyLanguageModel
import DiscoverableActors
import Foundation

extension Behavior {
    /// A spec as structure: the one form a behavior is read from. A typed tool hands it over as its
    /// arguments, so a model fills it in the way it fills in any tool's, and a guided decoder keeps
    /// it to the shape; YAML is read into it too. Every part is typed: a value is one of a few
    /// kinds, an action one of seven, each with only what it needs.
    @Generable(description: "An object's spec: the values it remembers, and how it answers each message.")
    public struct Written: SpecPart, Sendable {
        @Guide(description: "The protocols it handles in full, by name.")
        public let speaks: [String]?
        @Guide(description: "The values it remembers, each with its starting value.")
        public let fields: [Field]
        @Guide(description: "The state it starts in, for an object with states.")
        public let initial: String?
        @Guide(description: "How it answers messages: the first clause that matches handles one.")
        public let receive: [Clause]


        @Generable(description: "A value it remembers, with its starting value.")
        public struct Field: SpecPart, Sendable {
            @Guide(description: "The field's name, such as count.")
            public let name: String
            @Guide(description: "Its starting value, or the object it talks to.")
            public let start: Value

        }

        @Generable(description: "How it answers one message. The first clause that matches a message handles it.")
        public struct Clause: SpecPart, Sendable {
            @Guide(description: "The message it handles, such as add.")
            public let on: String
            @Guide(description: "The message's parameters.")
            public let parameters: [Parameter]?
            @Guide(description: "Conditions that must all hold for this clause to handle the message.")
            public let when: [Guard]?
            @Guide(description: "What it does, in order.")
            public let actions: [Action]
            @Guide(description: "For an object with states: the state this clause applies in.")
            public let `in`: String?
            @Guide(description: "For an object with states: the state it moves to.")
            public let then: String?

        }

        @Generable(description: "A parameter of a message.")
        public struct Parameter: SpecPart, Sendable {
            public let name: String
            public let type: Kind
            @Guide(description: "For an object: the protocol it speaks.")
            public let speaks: String?

        }

        @Generable(description: "A parameter's type.")
        public enum Kind: String, Codable, Sendable, Equatable {
            case string, integer, number, boolean, list, object
        }

        /// A value: a name (a parameter, a field, or `self`), a number, text, true or false, a list
        /// of text, or another object by its handle.
        @Generable(description: "A value.")
        public enum Value: Codable, Sendable, Equatable {
            case name(String)
            case number(Double)
            case text(String)
            case boolean(Bool)
            case list([String])
            case object(String)
        }

        /// One thing a clause does, each with only what it needs.
        @Generable(description: "One thing a clause does.")
        public enum Action: Codable, Sendable, Equatable {
            case set(field: String, to: Value)
            case add(Value, to: String)
            case subtract(Value, from: String)
            case append(Value, to: String)
            case remove(Value, from: String)
            case send(message: String, to: Value, arguments: [Argument]?)
            case reply(Value)
        }

        @Generable(description: "A condition: a value compared with another, or a list checked.")
        public struct Guard: SpecPart, Sendable {
            public let left: Value
            public let comparison: Comparison
            @Guide(description: "What it's compared with; none for isEmpty and isNotEmpty.")
            public let right: Value?

        }

        @Generable(description: "How a guard compares.")
        public enum Comparison: String, Codable, Sendable, Equatable {
            case lessThan, atMost, greaterThan, atLeast, equal, notEqual, contains, isEmpty, isNotEmpty
        }

        @Generable(description: "An argument of a message it sends.")
        public struct Argument: SpecPart, Sendable {
            public let name: String
            public let value: Value

        }
    }
}

extension MessageProtocol {
    /// A protocol as structure: its name, and the messages an object that speaks it takes.
    @Generable(description: "A protocol: a named set of messages that objects speaking it take.")
    public struct Written: SpecPart, Sendable {
        @Guide(description: "Its name, such as salary answers.")
        public let name: String
        public let messages: [Message]


        @Generable(description: "A message of a protocol.")
        public struct Message: SpecPart, Sendable {
            public let name: String
            public let parameters: [Behavior.Written.Parameter]?
            @Guide(description: "The type of its reply, for a message that's answered.")
            public let reply: Behavior.Written.Kind?

        }
    }
}

/// A part of a spec, coded and compared as the content a model writes for it, such as
/// `{"name": "count", "start": {"type": "number", "value": 0}}`. The `@Generable` macro keeps what a
/// value was decoded from in a stored property, which synthesized `Codable` and `Equatable` would
/// include.
public protocol SpecPart: Generable, Codable, Equatable {}

extension SpecPart {
    public init(from decoder: any Decoder) throws {
        let json = try DiscoverableActors.JSONValue(from: decoder)
        try self.init(GeneratedContent(json: String(decoding: try JSONEncoder().encode(json), as: UTF8.self)))
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONDecoder().decode(DiscoverableActors.JSONValue.self, from: Data(generatedContent.jsonString.utf8)).encode(to: encoder)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generatedContent == rhs.generatedContent
    }
}
