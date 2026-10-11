import DiscoverableActors
import Distributed

/// Messages as a Swift type: an enumeration whose cases are the messages, each with its
/// arguments, made `@Describable`. Its schema is the spec, so a message's name and arguments are
/// written once, in its case, and sending one encodes the case.
///
/// ```swift
/// @Describable enum RefundManager: Messages { case refundRequested(number: Int, total: Double) }
/// ```
public protocol Messages: Codable, Describable, Sendable {}

extension Messages {
    /// The message as sent: its case's name, and its arguments by name, the way synthesized
    /// `Codable` writes a case, `{"refundRequested": {"number": 1, "total": 40}}`.
    func sent() throws(MessagesError) -> (name: String, arguments: JSONValue) {
        let encoded: JSONValue
        do { encoded = try JSONValue(encoding: self) } catch { throw .unencodable("\(self)", reason: "\(error)") }
        guard case .object(let tagged) = encoded, tagged.count == 1, let (name, arguments) = tagged.first else {
            throw .notACase("\(self)")
        }
        return (name, arguments)
    }
}

extension MessageProtocol {
    /// The messages a `Messages` type has: each case, with its arguments' types, read from its
    /// schema.
    public init<M: Messages>(_ type: M.Type) throws(BehaviorError) {
        try self.init(name: "\(M.self)", schema: M.jsonSchema)
    }

    /// The messages a schema of tagged cases describes, as `@Describable` writes an enumeration
    /// with associated values: one option per case, an object with the case's name as its one key.
    init(name: String, schema: JSONValue) throws(BehaviorError) {
        guard case .array(let options)? = schema["oneOf"] else {
            throw BehaviorError("`\(name)` isn't a set of messages: its schema has no cases.")
        }
        var messages: [Signature] = []
        for option in options {
            guard case .object(let cases)? = option["properties"], cases.count == 1, let (message, arguments) = cases.first
            else { throw BehaviorError("`\(name)` has a case that isn't a message: \(option.inline).") }
            let fields: [String: JSONValue] = if case .object(let fields)? = arguments["properties"] { fields } else { [:] }
            messages.append(
                Signature(
                    name: message,
                    parameters: fields.keys.sorted().map { Parameter(name: $0, type: ValueType(schema: fields[$0] ?? [:])) }))
        }
        self.init(name: name, messages: messages)
    }
}

public enum MessagesError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    case notACase(String)
    case unencodable(String, reason: String)

    public var description: String {
        switch self {
        case .notACase(let value): "`\(value)` isn't a message: a message is one case of an enumeration."
        case .unencodable(let value, let reason): "`\(value)` can't be sent: \(reason)"
        }
    }
}

extension DiscoverableActor {
    /// Sends `message` to this object, as one of its actions.
    public nonisolated func send<M: Messages>(_ message: M) async throws {
        let (name, arguments) = try message.sent()
        try await invoke(name, arguments: arguments)
    }
}

// MARK: - Wanted objects

/// An object given for a parameter that wants one taking `Takes`, and that may answer with
/// `Answers`: what an action asks of an object, written in its signature. As given, it's
/// unchecked; ``checked()`` checks it, once, at the edge, and gives the reference to keep.
///
/// Its schema says what's wanted, so whoever offers objects for the parameter offers only those
/// that fit.
public struct Wanted<Takes: Messages, Answers: Messages>: Codable, Sendable {
    public let object: DynamicObject

    public init(_ object: DynamicObject) {
        self.object = object
    }

    public init(from decoder: any Decoder) throws {
        object = try decoder.singleValueContainer().decode(DynamicObject.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(object)
    }

    /// The object, checked to take every message of `Takes`.
    public func checked() async throws -> ObjectRef<Takes> {
        let want = try Want(takes: MessageProtocol(Takes.self), answers: MessageProtocol(Answers.self))
        let description = try await object.describe()
        if let gap = want.gap(in: description) { throw ObjectDoesNotFit(object: description.title, gap: gap) }
        return ObjectRef(object: object)
    }
}

extension Wanted: Describable {
    public static var jsonSchema: JSONValue {
        guard case .object(var schema) = _DiscoverySupport.actorReferenceSchema else { return [:] }
        schema[Want.takesKey] = Takes.jsonSchema
        schema[Want.answersKey] = Answers.jsonSchema
        return .object(schema)
    }
}

/// An object checked to take every message of `Takes`, to send them to.
public struct ObjectRef<Takes: Messages>: Sendable {
    public let object: DynamicObject

    public func send(_ message: Takes) async throws {
        try await object.send(message)
    }
}

/// An object given where it doesn't fit: it doesn't take a message that's wanted.
public struct ObjectDoesNotFit: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let object: String
    public let gap: String

    public var description: String { "\(object) doesn't fit here: \(gap)." }
}

/// What an action wants of an object given for one of its parameters: the messages it must take,
/// and those it may answer with. Read from the action's schema, for whoever offers objects.
public struct Want: Codable, Sendable, Equatable {
    static let takesKey = "x-takes"
    static let answersKey = "x-answers"

    public let takes: MessageProtocol
    public let answers: MessageProtocol

    public init(takes: MessageProtocol, answers: MessageProtocol) {
        self.takes = takes
        self.answers = answers
    }

    /// What's wanted for each parameter of an action that wants an object, by parameter.
    public static func wants(in input: JSONValue?) throws(BehaviorError) -> [String: Want] {
        guard case .object(let properties)? = input?["properties"] else { return [:] }
        var wants: [String: Want] = [:]
        for (parameter, schema) in properties {
            guard let takes = schema[takesKey], let answers = schema[answersKey] else { continue }
            wants[parameter] = Want(
                takes: try MessageProtocol(name: parameter, schema: takes),
                answers: try MessageProtocol(name: parameter, schema: answers))
        }
        return wants
    }

    /// Why an object, as it describes itself, doesn't take what's wanted; `nil` when it does.
    public func gap(in description: ObjectDescription) -> String? {
        Types(protocols: [:]).firstGap(in: DynamicObjects.accepted(by: description), for: takes)
    }

    /// In a line: `takes refundRequested(order: integer, total: number); may answer
    /// refundApproved(order: integer) or refundDenied(order: integer)`.
    public var written: String {
        let takes = "takes " + self.takes.messages.map(\.written).joined(separator: " and ")
        let answers = self.answers.messages.map(\.written).joined(separator: " or ")
        return answers.isEmpty ? takes : takes + "; may answer " + answers
    }
}
