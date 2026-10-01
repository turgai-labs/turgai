import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Discovery's DiscoveryJSON; AnyLanguageModel has its own `JSONValue`.
typealias DiscoveryJSON = DiscoverableActors.JSONValue

/// The objects a model has met during one turn, behind readable handles such as
/// `mac` or `reminder-list-2`.
///
/// The model never sees actor IDs, so it can only use objects it was given:
/// the directory's roots and whatever their actions return. A handle points at
/// one incarnation of an object; when that object stops, the model lists again
/// and walks back to it.
public actor ObjectSession {
    let actorSystem: ClusterSystem
    private var objectCatalog: ObjectCatalog?
    let scopes: [ObjectScope]

    private var objects: [String: DiscoverableObject] = [:]
    private var handles: [ClusterSystem.ActorID: String] = [:]
    /// How many handles each kind of object has, to number the second one on.
    private var kinds: [String: Int] = [:]

    public init(
        actorSystem: ClusterSystem,
        objectCatalog: ObjectCatalog? = nil,
        scopes: [ObjectScope]
    ) {
        self.actorSystem = actorSystem
        self.objectCatalog = objectCatalog
        self.scopes = scopes
    }

    /// The directory's roots, with handles, titles, and descriptions.
    func list() async throws -> DiscoveryJSON {
        .array(
            try await entries().map { entry in
                [
                    "handle": .string(handle(for: entry.object)),
                    "title": .string(entry.title),
                    "description": entry.description.map(DiscoveryJSON.string) ?? .null,
                    "actions": .array(entry.actions.map(DiscoveryJSON.string)),
                    "events": .array(entry.events.map(DiscoveryJSON.string)),
                ]
            })
    }

    /// The roots that best match `query`, so a model doesn't read the whole directory.
    ///
    /// Each query word that starts a word of a root's title counts twice, and of its
    /// description once, so "reminder" matches "Reminders". Short and filler words are
    /// ignored, and roots that match nothing are left out.
    func find(_ query: String, limit: Int = 5) async throws -> DiscoveryJSON {
        let words = Self.words(query).filter { $0.count >= 3 && !Self.fillerWords.contains($0) }
        guard !words.isEmpty, case .array(let entries) = try await list() else { return [] }
        func text(_ value: DiscoveryJSON?) -> String {
            if case .string(let text)? = value { text } else { "" }
        }
        func matches(_ word: String, in text: String) -> Bool {
            Self.words(text).contains { $0.hasPrefix(word) }
        }
        let ranked =
            entries
            .map { entry -> (entry: DiscoveryJSON, score: Int) in
                let title = text(entry["title"])
                let description = text(entry["description"])
                let score = words.reduce(0) { total, word in
                    total + (matches(word, in: title) ? 2 : 0) + (matches(word, in: description) ? 1 : 0)
                }
                return (entry, score)
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entry)
        return .array(Array(ranked))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Words that say nothing about which object is meant.
    private static let fillerWords: Set<String> = [
        "the", "and", "for", "with", "what", "how", "set", "get", "show", "make", "please", "can", "you",
        "your", "this", "that", "into", "from", "about",
    ]

    /// An object's properties and actions, with actor references shown as handles.
    func describe(_ handle: String) async throws -> DiscoveryJSON {
        let description = try await call(handle) { try await $0.describe() }
        return Self.presentingReferences(try DiscoveryJSON(encoding: description))
    }

    /// Runs an action. The Mac's objects are guarded by macOS's own permissions,
    /// which ask the user the first time an app is used; Turgai doesn't ask again.
    func invoke(_ handle: String, action name: String, arguments text: String?) async throws -> DiscoveryJSON {
        do {
            let result = try await perform(handle, action: name, arguments: text)
            actorSystem.log.info(
                "Object call",
                metadata: ["handle": .string(handle), "action": .string(name), "arguments": .string(text ?? "")]
            )
            return result
        } catch {
            actorSystem.log.info(
                "Object call failed",
                metadata: [
                    "handle": .string(handle), "action": .string(name), "arguments": .string(text ?? ""),
                    "error": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }

    private func perform(_ handle: String, action name: String, arguments text: String?) async throws -> DiscoveryJSON {
        let object = try await object(handle)
        let description = try await call(handle) { try await $0.describe() }
        guard let action = description.actions[name] else {
            throw ObjectToolError.unknownAction(name, available: description.actions.keys.sorted())
        }
        let given = try Self.arguments(text, schema: action.input)
        let missing = Self.missingArguments(given, schema: action.input)
        guard missing.isEmpty else {
            throw ObjectToolError.missingArguments(
                "\(description.title).\(name)", missing: missing,
                unexpected: Self.unexpectedArguments(given, schema: action.input))
        }
        let arguments = try await translate(given, schema: action.input, reference: resolveHandle)
        let result = try await call(handle) { _ in try await object.invoke(name, arguments: arguments) }
        return try await translate(result, schema: action.output, reference: mintHandle)
    }

    /// Reads a property, with actor references shown as handles.
    func read(_ handle: String, property: String) async throws -> DiscoveryJSON {
        let description = try await call(handle) { try await $0.describe() }
        let value = try await call(handle) { try await $0.read(property: property) }
        return try await translate(value, schema: description.properties[property], reference: mintHandle)
    }

    // MARK: Handles

    private func handle(for object: DiscoverableObject) -> String {
        if let handle = handles[object.id] { return handle }
        let kind = Self.kind(of: object.id)
        let count = kinds[kind, default: 0] + 1
        kinds[kind] = count
        let handle = count == 1 ? kind : "\(kind)-\(count)"
        objects[handle] = object
        handles[object.id] = handle
        return handle
    }

    /// The object's kind in kebab case, such as `reminder-list`, from its actor name
    /// (`ReminderList-b`): the cluster names an actor after its type, then a dash and a
    /// unique suffix. Type names can't contain a dash, so the suffix starts at the first one.
    static func kind(of id: ClusterSystem.ActorID) -> String {
        let name = id.name.prefix { $0 != "-" }
        var kind = ""
        for character in name where character.isLetter || character.isNumber {
            if character.isUppercase, !kind.isEmpty { kind.append("-") }
            kind.append(Character(character.lowercased()))
        }
        return kind.isEmpty ? "object" : kind
    }

    /// The roots this session can see, from the cluster receptionist, in the same
    /// order every time, so each gets the same handle in every session, including the
    /// summary shown to the model.
    private func entries() async throws -> [ObjectEntry] {
        if objectCatalog == nil { objectCatalog = await ObjectCatalog(actorSystem: actorSystem) }
        guard let objectCatalog else { return [] }
        return try await objectCatalog.entries(in: scopes)
    }

    /// The object behind `handle`. A root's handle works without listing first, since
    /// the model may know it from the turn's summary.
    private func object(_ handle: String) async throws -> DiscoverableObject {
        if let object = objects[handle] { return object }
        for entry in try await entries() { _ = self.handle(for: entry.object) }
        guard let object = objects[handle] else { throw ObjectToolError.unknownHandle(handle) }
        return object
    }

    /// Reference lines for a turn: each root's handle, title, and description, so the
    /// model knows what the `objects` tool reaches without calling it.
    static func turnContext(
        actorSystem: ClusterSystem,
        objectCatalog: ObjectCatalog? = nil,
        conversationID: ConversationID,
        limit: Int = 20
    ) async -> [String] {
        let session = ObjectSession(
            actorSystem: actorSystem,
            objectCatalog: objectCatalog,
            scopes: conversationID.participantUserID.map(ObjectScope.visible(to:)) ?? [.shared]
        )
        guard case .array(let entries)? = try? await session.list(), !entries.isEmpty else { return [] }
        let lines = entries.prefix(limit).map { entry in
            let handle = entry["handle"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? ""
            let title = entry["title"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? ""
            let description =
                entry["description"].flatMap { if case .string(let text) = $0 { ": \(text)" } else { nil } } ?? ""
            let actions =
                entry["actions"].flatMap { value -> [String]? in
                    guard case .array(let values) = value else { return nil }
                    return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
                } ?? []
            let events = entry["events"].flatMap { value -> [String]? in
                guard case .array(let values) = value else { return nil }
                return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
            } ?? []
            let affordances =
                (actions.isEmpty ? "" : "; actions: \(actions.joined(separator: ", "))")
                + (events.isEmpty ? "" : "; events: \(events.joined(separator: ", "))")
            return "- `\(handle)`, \(title)\(description)\(affordances)"
        }
        let more = entries.count > limit ? ["…and \(entries.count - limit) more; use objects find."] : []
        return ["Objects you can use with the objects tool, by handle:"] + lines + more
    }

    /// Runs a call on a handle's object, explaining a failure the model can recover from.
    private func call<Value>(
        _ handle: String,
        _ body: (DiscoverableObject) async throws -> Value
    ) async throws -> Value {
        let object = try await object(handle)
        do {
            return try await body(object)
        } catch let error as DiscoveryError {
            throw error
        } catch let error as ObjectToolError {
            throw error
        } catch let error as DeadLetterError {
            throw ObjectToolError.unreachable(handle, reason: String(describing: error))
        } catch let error as RemoteCallError {
            throw ObjectToolError.unreachable(handle, reason: String(describing: error))
        } catch let error as GenericRemoteCallError {
            // The object failed with an error the cluster couldn't send back as it was.
            throw ObjectToolError.failed(error.message)
        } catch {
            // The object's own error, such as missing access: the model can act on it.
            throw ObjectToolError.failed(String(describing: error))
        }
    }

    /// A reference in a result becomes a handle.
    private func mintHandle(_ value: DiscoveryJSON) throws -> DiscoveryJSON {
        let reference = try value.decode(ActorReference.self)
        return .string(handle(for: try reference.resolve(using: actorSystem)))
    }

    /// A handle in the model's arguments becomes a reference.
    private func resolveHandle(_ value: DiscoveryJSON) async throws -> DiscoveryJSON {
        guard case .string(let handle) = value else { throw ObjectToolError.expectedHandle }
        return try DiscoveryJSON.reference(to: try await object(handle))
    }

    // MARK: References

    /// Rewrites each actor reference in `value`, wherever `schema` marks one.
    private func translate(
        _ value: DiscoveryJSON,
        schema: DiscoveryJSON?,
        reference: (DiscoveryJSON) async throws -> DiscoveryJSON
    ) async throws -> DiscoveryJSON {
        guard let schema, case .object(let fields) = schema, value != .null else { return value }
        if Self.isReference(schema) { return try await reference(value) }
        if case .array(let options)? = fields["anyOf"] ?? fields["oneOf"] {
            guard let option = options.first(where: { Self.matches($0, value) }) else { return value }
            return try await translate(value, schema: option, reference: reference)
        }
        switch value {
        case .array(let elements):
            var translated: [DiscoveryJSON] = []
            for element in elements {
                translated.append(try await translate(element, schema: fields["items"], reference: reference))
            }
            return .array(translated)
        case .object(let members):
            var translated: [String: DiscoveryJSON] = [:]
            for (key, member) in members {
                let memberSchema = fields["properties"]?[key] ?? fields["additionalProperties"]
                translated[key] = try await translate(member, schema: memberSchema, reference: reference)
            }
            return .object(translated)
        default:
            return value
        }
    }

    /// The call's arguments. An action with a single argument also takes its bare
    /// value, such as `gorillaz` for `play(query)`, or one misnamed key, such as
    /// `{"artist": "gorillaz"}`; small models often write either.
    static func arguments(_ text: String?, schema: DiscoveryJSON?) throws -> DiscoveryJSON {
        guard case .object(let properties)? = schema?["properties"], properties.count == 1,
            let name = properties.keys.first
        else { return try parse(text) }
        let value = (try? parse(text)) ?? text.map(DiscoveryJSON.string) ?? .null
        switch value {
        case .null: return value
        case .object(let members) where members[name] == nil && members.count == 1:
            return [name: members.values.first!]
        case .object: return value
        default: return [name: value]
        }
    }

    /// The arguments `value` names that the action doesn't take.
    static func unexpectedArguments(_ value: DiscoveryJSON, schema: DiscoveryJSON?) -> [String] {
        guard case .object(let members) = value else { return [] }
        let known: Set<String> =
            if case .object(let properties)? = schema?["properties"] { Set(properties.keys) } else { [] }
        return members.keys.filter { !known.contains($0) }.sorted()
    }

    /// The required arguments `value` leaves out.
    static func missingArguments(_ value: DiscoveryJSON, schema: DiscoveryJSON?) -> [String] {
        guard case .array(let required)? = schema?["required"] else { return [] }
        let given: [String: DiscoveryJSON] = if case .object(let members) = value { members } else { [:] }
        return required.compactMap { field in
            guard case .string(let name) = field else { return nil }
            return given[name] == nil || given[name] == .null ? name : nil
        }
    }

    static func isReference(_ schema: DiscoveryJSON) -> Bool {
        schema["x-actor-reference"] == true
    }

    /// Whether `value` could be an instance of `option`, to pick a branch of `anyOf`.
    private static func matches(_ option: DiscoveryJSON, _ value: DiscoveryJSON) -> Bool {
        if isReference(option) {
            switch value {
            case .object(let fields): return fields["id"] != nil
            case .string: return true
            default: return false
            }
        }
        guard case .string(let type)? = option["type"] else { return true }
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
            ("integer", .integer), ("integer", .unsignedInteger),
            ("number", .number), ("number", .integer), ("number", .unsignedInteger):
            return true
        default:
            return false
        }
    }

    /// Replaces reference schemas with handle schemas, which is what the model passes and gets.
    static func presentingReferences(_ value: DiscoveryJSON) -> DiscoveryJSON {
        switch value {
        case .object(let fields):
            if isReference(value) {
                return ["type": "string", "description": "An object handle, such as reminder-list."]
            }
            return .object(fields.mapValues(presentingReferences))
        case .array(let elements):
            return .array(elements.map(presentingReferences))
        default:
            return value
        }
    }

    // MARK: DiscoveryJSON text

    static func parse(_ text: String?) throws -> DiscoveryJSON {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .null }
        do {
            return try JSONDecoder().decode(DiscoveryJSON.self, from: Data(text.utf8))
        } catch {
            throw ObjectToolError.invalidJSON
        }
    }

    static func text(_ value: DiscoveryJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum ObjectToolError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownHandle(String)
    case unknownAction(String, available: [String])
    case unreachable(String, reason: String)
    case expectedHandle
    case invalidJSON
    case missingArguments(String, missing: [String], unexpected: [String])
    case failed(String)

    public var description: String {
        switch self {
        case .unknownHandle(let handle):
            "unknown handle \(handle); use find or list to get handles for this turn"
        case .unknownAction(let action, let available):
            "no action \(action); available: \(available.joined(separator: ", "))"
        case .unreachable(let handle, let reason):
            "the object behind \(handle) can't be reached (\(reason)); use list and walk back to it"
        case .expectedHandle:
            "expected an object handle, such as reminder-list"
        case .invalidJSON:
            "arguments must be a JSON object, such as {\"title\": \"Milk\"}"
        case .missingArguments(let action, let missing, let unexpected):
            "\(action) needs \(missing.joined(separator: ", "))"
                + (unexpected.isEmpty ? "" : ", not \(unexpected.joined(separator: ", "))")
                + "; pass them in arguments as a JSON object, such as {\"\(missing[0])\": …}"
        case .failed(let reason):
            reason
        }
    }
}

// MARK: - Effects

public struct ListObjectsEffect: ScopedEffect, Sendable {
    public let name = "objects.list"
    let session: ObjectSession
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let session = token.withConfiguration { $0.session }
        return try ObjectSession.text(try await session.list())
    }
}

public struct FindObjectsEffect: ScopedEffect, Sendable {
    public let name = "objects.find"
    let session: ObjectSession
    let query: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, query) = token.withConfiguration { ($0.session, $0.query) }
        return try ObjectSession.text(try await session.find(query))
    }
}

public struct DescribeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.describe"
    let session: ObjectSession
    let handle: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle) = token.withConfiguration { ($0.session, $0.handle) }
        return try ObjectSession.text(try await session.describe(handle))
    }
}

public struct InvokeObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.invoke"
    let session: ObjectSession
    let handle: String
    let action: String
    let arguments: String?
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle, action, arguments) = token.withConfiguration {
            ($0.session, $0.handle, $0.action, $0.arguments)
        }
        return try ObjectSession.text(try await session.invoke(handle, action: action, arguments: arguments))
    }
}

public struct ReadObjectEffect: ScopedEffect, Sendable {
    public let name = "objects.read"
    let session: ObjectSession
    let handle: String
    let property: String
    public static func run(in token: borrowing EffectToken<Self>) async throws -> String {
        let (session, handle, property) = token.withConfiguration { ($0.session, $0.handle, $0.property) }
        return try ObjectSession.text(try await session.read(handle, property: property))
    }
}

// MARK: - Tool

@Tool("objects")
public struct ObjectTools: Sendable {
    let session: ObjectSession

    public init(session: ObjectSession) {
        self.session = session
    }

    @Command(
        "list",
        description:
            "List every object you can use, such as this Mac or the Reminders app, with a handle for each. Prefer find when you know what you need; list again when a handle stops working."
    )
    public func list(_ input: ObjectToolsListInput) throws -> ListObjectsEffect {
        ListObjectsEffect(session: session)
    }

    @Command(
        "find",
        description:
            "Find the objects that match what you need, such as \"reminders\" or \"battery\", with a handle for each. Includes the Mac's own apps, like Reminders."
    )
    public func find(_ input: ObjectToolsFindInput) throws -> FindObjectsEffect {
        FindObjectsEffect(session: session, query: input.query)
    }

    @Command(
        "describe",
        description:
            "Describe an object: its properties, and the actions you can call on it now with their arguments."
    )
    public func describe(_ input: ObjectToolsDescribeInput) throws -> DescribeObjectEffect {
        DescribeObjectEffect(session: session, handle: input.handle)
    }

    @Command(
        "invoke",
        description:
            "Call an action on an object, such as play on music with arguments {\"query\": \"Gorillaz\"}. For an action with one argument, arguments can be just its value. Objects in results come back as new handles, and you pass objects as arguments by their handles."
    )
    public func invoke(_ input: ObjectToolsInvokeInput) throws -> InvokeObjectEffect {
        InvokeObjectEffect(session: session, handle: input.handle, action: input.action, arguments: input.arguments)
    }

    @Command("read", description: "Read one property of an object.")
    public func read(_ input: ObjectToolsReadInput) throws -> ReadObjectEffect {
        ReadObjectEffect(session: session, handle: input.handle, property: input.property)
    }

    public func render(_ output: String) -> ToolOutput { .text(output) }
}

@Generable
public struct ObjectToolsListInput: Sendable {}

@Generable
public struct ObjectToolsFindInput: Sendable {
    /// Words describing what you need, such as "reminders" or "battery".
    public let query: String
}

@Generable
public struct ObjectToolsDescribeInput: Sendable {
    /// The object's handle, such as mac or reminder-list.
    public let handle: String
}

@Generable
public struct ObjectToolsInvokeInput: Sendable {
    /// The object's handle, such as mac or reminder-list.
    public let handle: String
    /// The action's name, as listed by describe.
    public let action: String
    /// The arguments as a JSON object, such as {"title": "Milk"}, or just the value for an action with one argument. Omit for actions without arguments.
    public let arguments: String?
}

@Generable
public struct ObjectToolsReadInput: Sendable {
    /// The object's handle, such as mac or reminder-list.
    public let handle: String
    /// The property's name, as listed by describe.
    public let property: String
}
