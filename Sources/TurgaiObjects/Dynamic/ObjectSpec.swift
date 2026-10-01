import DiscoverableActors

/// What a ``DynamicObject`` is, held as data: its properties and its actions. Written by
/// a person or a model, not compiled.
///
/// A property can hold a reference to another object, which actions call directly. Who
/// it listens to is decided outside it: whoever subscribes it to another object's event
/// names one of its actions, and that action receives the event.
public struct ObjectSpec: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var description: String?
    public var properties: [String: Property]
    public var actions: [String: Action]

    public init(
        id: String,
        title: String,
        description: String? = nil,
        properties: [String: Property] = [:],
        actions: [String: Action] = [:]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.properties = properties
        self.actions = actions
    }

    public struct Property: Codable, Sendable, Equatable {
        public var description: String?
        /// JSON Schema for the value. A reference to another object uses
        /// `{"x-actor-reference": true}`, and its value is the reference, `{"id": …}`.
        public var schema: JSONValue
        public var initial: JSONValue

        public init(description: String? = nil, schema: JSONValue, initial: JSONValue) {
            self.description = description
            self.schema = schema
            self.initial = initial
        }
    }

    public struct Action: Codable, Sendable, Equatable {
        public var description: String?
        /// JSON Schema for the arguments, an object; `nil` when it takes none.
        public var input: JSONValue?
        public var steps: [Step]

        public init(description: String? = nil, input: JSONValue? = nil, steps: [Step]) {
            self.description = description
            self.input = input
            self.steps = steps
        }
    }

    /// One thing an action does.
    public enum Step: Sendable, Equatable {
        /// Replace a property's value.
        case set(property: String, to: Value)
        /// Add a value to a property holding an array.
        case append(property: String, value: Value)
        /// Run an action of the object referenced by `property`. Its result becomes `result`.
        case call(property: String, action: String, arguments: [String: Value])
        /// Finish, answering with a value.
        case `return`(Value)
    }

    /// A value in a step: JSON as written, or taken from what the step can see, such as
    /// `{"from": "arguments.order"}`. The roots are `arguments`, `properties`, and `result`.
    public enum Value: Sendable, Equatable {
        case literal(JSONValue)
        case from([String])
    }
}

// MARK: - Coding

extension ObjectSpec.Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case set, to, append, value, call, action, arguments, `return`
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let property = try values.decodeIfPresent(String.self, forKey: .set) {
            self = .set(property: property, to: try values.decode(ObjectSpec.Value.self, forKey: .to))
        } else if let property = try values.decodeIfPresent(String.self, forKey: .append) {
            self = .append(property: property, value: try values.decode(ObjectSpec.Value.self, forKey: .value))
        } else if let property = try values.decodeIfPresent(String.self, forKey: .call) {
            self = .call(
                property: property,
                action: try values.decode(String.self, forKey: .action),
                arguments: try values.decodeIfPresent([String: ObjectSpec.Value].self, forKey: .arguments) ?? [:]
            )
        } else if values.contains(.return) {
            self = .return(try values.decode(ObjectSpec.Value.self, forKey: .return))
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A step is one of set, append, call, or return"
                ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .set(let property, let value):
            try values.encode(property, forKey: .set)
            try values.encode(value, forKey: .to)
        case .append(let property, let value):
            try values.encode(property, forKey: .append)
            try values.encode(value, forKey: .value)
        case .call(let property, let action, let arguments):
            try values.encode(property, forKey: .call)
            try values.encode(action, forKey: .action)
            if !arguments.isEmpty { try values.encode(arguments, forKey: .arguments) }
        case .return(let value):
            try values.encode(value, forKey: .return)
        }
    }
}

extension ObjectSpec.Value: Codable {
    public init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        if case .object(let members) = json, members.count == 1, case .string(let path)? = members["from"] {
            self = .from(path.split(separator: ".").map(String.init))
        } else {
            self = .literal(json)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .literal(let json): try json.encode(to: encoder)
        case .from(let path): try JSONValue.object(["from": .string(path.joined(separator: "."))]).encode(to: encoder)
        }
    }
}

// MARK: - Checking

public enum ObjectSpecError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case unknownProperty(String, in: String)

    public var description: String {
        switch self {
        case .unknownProperty(let property, let action): "\(action) uses \(property), which isn't a property"
        }
    }
}

extension ObjectSpec {
    /// Checks what can be checked before running: steps only use declared properties.
    public func validate() throws {
        for (name, action) in actions {
            for step in action.steps {
                switch step {
                case .set(let property, _), .append(let property, _), .call(let property, _, _):
                    guard properties[property] != nil else { throw ObjectSpecError.unknownProperty(property, in: name) }
                case .return:
                    break
                }
            }
        }
    }
}
