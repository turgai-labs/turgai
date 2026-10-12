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
        @Guide(description: "The values it remembers, each with its starting value.")
        public let fields: [Field]
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

        }

        @Generable(description: "A parameter of a message.")
        public struct Parameter: SpecPart, Sendable {
            public let name: String
            public let type: Kind
            @Guide(description: "For an object: the handle of an object it behaves like. Messages to it are checked against what that object takes.")
            public let like: String?

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
            case reject(String)
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
