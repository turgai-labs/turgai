import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import VirtualActors

/// An object that runs a ``Behavior`` instead of compiled Swift, the way an Erlang process runs
/// a module: a name, the behavior it runs, and its own fields. To other objects and to models,
/// it's an object like any other: each message its behavior takes is one of its actions.
///
/// It's a virtual actor keyed by its ``ObjectIdentity``: whoever has the identity can always
/// reach it, and it starts on demand, on any node. What happens to it is journaled, so it comes
/// back after a restart with the same fields. ``DynamicObjects`` creates, upgrades and removes
/// them.
@EventSourced
@VirtualActor
public distributed actor DynamicObject: DiscoverableActor {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = ObjectIdentity
    public typealias Event = DynamicObjectEvent
    public typealias State = DynamicObjectState

    public var state = DynamicObjectState()
    private let ownIdentity: ObjectIdentity
    /// Messages it's handling right now: a new spec waits for none.
    private var handling = 0
    private var idle: [CheckedContinuation<Void, Never>] = []
    private var stable: Stable?

    /// Its stable reference, kept in a struct: a `DynamicObject?` property would have its deinit
    /// read the stored properties of the remote proxy it holds
    /// (https://github.com/swiftlang/swift/issues/92961).
    private struct Stable {
        let object: DynamicObject
    }

    public init(actorSystem: ClusterSystem, dependency identity: ObjectIdentity) async throws {
        self.actorSystem = actorSystem
        self.ownIdentity = identity
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: identity))
        if let created = state.created, !created.removed {
            try await checkIn(created.scope)
        }
    }

    /// The object with `identity`, started if it isn't running.
    public static func resolve(on system: ClusterSystem, identity: ObjectIdentity) async throws -> DynamicObject {
        try await system.virtualActors.getActor(identifiedBy: actorID(for: identity), dependency: identity)
    }

    static func actorID(for identity: ObjectIdentity) -> VirtualActorID {
        VirtualActorID(rawValue: "dynamic-object:\(identity.rawValue)")
    }

    static func persistenceID(for identity: ObjectIdentity) -> String {
        "turgai-object-\(identity.rawValue)"
    }

    /// Which object this is: its own, kept across restarts, unlike its actor ID.
    public distributed var identity: ObjectIdentity { ownIdentity }

    /// The state it's in, for a new spec to be checked against.
    distributed var current: String? { state.current }

    /// Makes this object `name`, running `behavior`, with `start` values instead of the
    /// behavior's starting ones where given. An object is created once.
    distributed func create(
        name: String, behavior: Behavior, id: BehaviorID, start: [String: JSONValue], scope: ObjectScope
    ) async throws {
        guard state.created == nil else { throw DynamicObjectError.alreadyCreated }
        try Self.check(start, against: behavior)
        try await emit(event: .created(name: name, behavior: behavior, id: id, start: start, scope: scope, at: Date()))
        try await checkIn(scope)
    }

    /// Runs a new spec of the behavior it shares, from its next message on, once it isn't handling
    /// one: the way a new module reaches an Erlang process.
    distributed func adopt(_ behavior: Behavior) async throws {
        _ = try existing
        if handling > 0 { await withCheckedContinuation { idle.append($0) } }
        try await emit(event: .adopted(behavior))
    }

    /// Starts it if it isn't running: being called is what starts a virtual actor, and starting
    /// checks it in, so it's findable.
    distributed func start() {}

    /// It runs until it's removed, so it stays findable.
    public func shouldDeactivate() async -> Bool {
        state.created.map(\.removed) ?? true
    }

    /// Ends the object for good: it answers nothing from now on, and the next idle sweep stops
    /// it, which takes it out of the catalog.
    distributed func remove() async throws {
        try await emit(event: .removed)
    }

    public func handleEvent(_ event: DynamicObjectEvent) {
        state.apply(event)
    }

    /// Checks in under its stable reference, the one ``resolve(on:identity:)`` returns, which
    /// keeps reaching it after it restarts.
    private func checkIn(_ scope: ObjectScope) async throws {
        let object = try DiscoverableObject.resolve(id: try await reference().id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
    }

    /// Its own stable reference, which keeps reaching it after it restarts: what it checks in
    /// under, and passes on as `self`.
    private func reference() async throws -> DynamicObject {
        if let stable { return stable.object }
        let resolved = try await Self.resolve(on: actorSystem, identity: ownIdentity)
        stable = Stable(object: resolved)
        return resolved
    }

    private var existing: DynamicObjectState.Created {
        get throws { try state.existing }
    }

    private var behavior: Behavior {
        get throws { try existing.behavior }
    }

    /// Its fields as its behavior has them: values it has, and starting values for fields it hasn't
    /// had yet, such as ones a newer spec added.
    private var fields: [String: JSONValue] {
        get throws {
            let behavior = try behavior
            return behavior.fields.mapValues(\.initial).merging(state.fields.filter { behavior.fields[$0.key] != nil }) {
                _, own in own
            }
        }
    }

    /// The state it's in, or the behavior's first, if a newer spec no longer has it.
    private var currentState: String? {
        get throws {
            let behavior = try behavior
            let states = Set(behavior.clauses.compactMap(\.state) + [behavior.initial].compactMap { $0 })
            return state.current.flatMap { states.contains($0) ? $0 : nil } ?? behavior.initial
        }
    }

    static func check(_ start: [String: JSONValue], against behavior: Behavior) throws(BehaviorError) {
        if let unknown = start.keys.sorted().first(where: { behavior.fields[$0] == nil }) {
            let known = behavior.fields.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
            throw BehaviorError("Its spec has no field `\(unknown)`. Its fields are \(known.isEmpty ? "none" : known).")
        }
    }

    // MARK: DiscoverableActor
    //
    // Every requirement is implemented `async`: a sync implementation can be bypassed by the
    // library's async `invoke` overloads (https://github.com/swiftlang/swift/issues/92795).

    /// Its fields, and the messages it takes now, in the state it's in.
    public distributed func describe() async throws -> ObjectDescription {
        let created = try existing
        let behavior = try behavior
        let fields = try fields
        var properties: [String: JSONValue] = [:]
        for name in behavior.fields.keys {
            var schema = Self.schema(of: fields[name] ?? .null)
            schema["readOnly"] = true
            properties[name] = .object(schema)
        }
        let current = try currentState
        let taking = Set(behavior.messages(in: current))
        var actions: [String: ObjectAction] = [:]
        for message in behavior.messages where taking.contains(message.name) {
            let input: JSONValue? =
                message.parameters.isEmpty
                ? nil
                : [
                    "type": "object",
                    "properties": .object(
                        Dictionary(uniqueKeysWithValues: message.parameters.map { ($0.name, $0.type.schema) })),
                    "required": .array(message.parameters.map { .string($0.name) }),
                ]
            actions[message.name] = ObjectAction(description: nil, input: input)
        }
        let made = created.createdAt.formatted(date: .abbreviated, time: .omitted)
        let now = current.map { " It's \($0) now." } ?? ""
        return ObjectDescription(
            title: created.name,
            description: "Made with objects on \(made).\(now) Its spec:\n\(behavior.source.yaml.text)",
            properties: properties,
            actions: actions
        )
    }

    /// Handles a message the way its behavior says: the first clause that matches changes its
    /// fields, all at once, then its sends go out and its reply comes back.
    @discardableResult
    public distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue {
        let created = try existing
        let fields = try fields
        let current = try currentState
        let outcome = try behavior.handle(action, arguments: arguments, state: current, fields: fields)
        handling += 1
        defer {
            handling -= 1
            if handling == 0 {
                idle.forEach { $0.resume() }
                idle = []
            }
        }
        var changes: [String: JSONValue] = [:]
        for (name, value) in outcome.fields where fields[name] != value { changes[name] = value }
        if !changes.isEmpty || outcome.state != state.current {
            try await emit(event: .handled(changes: changes, state: outcome.state))
        }
        let me = try JSONValue.reference(to: try await reference())
        for send in outcome.sends {
            let scopes = Self.scopes(around: created.scope)
            let system = actorSystem
            let from = created.name
            // Like an Erlang send: it doesn't wait for the other object, and can't fail this one.
            Task { await Self.deliver(send, from: from, me: me, scopes: scopes, using: system) }
        }
        return Self.replacingSelf(in: outcome.reply, with: me)
    }

    public distributed func read(property name: String) async throws -> JSONValue {
        guard try behavior.fields[name] != nil, let value = try fields[name] else {
            throw DiscoveryError.unknownProperty(name)
        }
        return value
    }

    public distributed func _subscribe(_ subscriber: UUID, to event: String) async throws {
        throw DiscoveryError.unknownEvent(event)
    }

    public distributed func _nextEvent(for subscriber: UUID) async throws -> _EventDelivery {
        .ended
    }

    public distributed func _unsubscribe(_ subscriber: UUID) async throws {}

    // MARK: Sending

    private static func deliver(
        _ send: Behavior.Send, from name: String, me: JSONValue, scopes: [ObjectScope], using system: ClusterSystem
    ) async {
        do {
            let recipient = try await recipient(send.recipient, me: me, scopes: scopes, using: system)
            try await recipient.invoke(send.message, arguments: replacingSelf(in: send.arguments, with: me))
        } catch {
            system.log.warning(
                "A dynamic object's message wasn't delivered",
                metadata: ["object": "\(name)", "message": "\(send.message)", "error": "\(error)"])
        }
    }

    private static func recipient(
        _ recipient: Behavior.Send.Recipient, me: JSONValue, scopes: [ObjectScope], using system: ClusterSystem
    ) async throws -> DiscoverableObject {
        switch recipient {
        case .me:
            return try me.decode(ActorReference.self).resolve(using: system)
        case .named(let name):
            return try await named(name, scopes: scopes, using: system)
        case .reference(let value):
            // A field written `{object: Name}` holds a name until it's sent to.
            if case .string(let name)? = value["object"] { return try await named(name, scopes: scopes, using: system) }
            guard value != .null, let reference = try? value.decode(ActorReference.self) else {
                throw DynamicObjectError.noReference("`\(value.inline)`")
            }
            return try reference.resolve(using: system)
        }
    }

    private static func named(_ name: String, scopes: [ObjectScope], using system: ClusterSystem) async throws
        -> DiscoverableObject
    {
        guard let found = await ObjectNames.object(named: name, in: scopes, using: system) else {
            throw DynamicObjectError.noObjectNamed(name)
        }
        return found.object
    }

    /// The scopes an object of `scope` can name objects in: its own, and the machine's.
    static func scopes(around scope: ObjectScope) -> [ObjectScope] {
        switch scope {
        case .shared: [.shared]
        case .owned(let user): ObjectScope.visible(to: user)
        }
    }

    /// `self` in a value is this object's own reference, to pass on as a reply-to.
    private static func replacingSelf(in value: JSONValue, with me: JSONValue) -> JSONValue {
        switch value {
        case ["self": true]: me
        case .object(let members): .object(members.mapValues { replacingSelf(in: $0, with: me) })
        case .array(let items): .array(items.map { replacingSelf(in: $0, with: me) })
        default: value
        }
    }

    private static func schema(of value: JSONValue) -> [String: JSONValue] {
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

/// What happened to a dynamic object, as journaled.
public enum DynamicObjectEvent: Codable, Sendable {
    case created(name: String, behavior: Behavior, id: BehaviorID, start: [String: JSONValue], scope: ObjectScope, at: Date)
    /// One message handled: the fields it changed, and the state it left the object in.
    case handled(changes: [String: JSONValue], state: String?)
    /// A new spec of the behavior it shares.
    case adopted(Behavior)
    case removed
}

/// A dynamic object's journaled state: the behavior it runs, its state, and the field values it
/// has set. The behavior is shared with other objects running the same one, through its directory.
public struct DynamicObjectState: Codable, Sendable {
    public struct Created: Codable, Sendable {
        public let name: String
        public var behavior: Behavior
        public let id: BehaviorID
        public let scope: ObjectScope
        public let createdAt: Date
        public var removed: Bool
    }

    /// `nil` until the object is created.
    public var created: Created?
    /// The behavior's state it's in, or `nil` for a behavior without states.
    public var current: String?
    /// The values it has set: its start values, and every change since.
    public var fields: [String: JSONValue] = [:]

    public init() {}

    var existing: Created {
        get throws {
            guard let created else { throw DynamicObjectError.notCreated }
            guard !created.removed else { throw DynamicObjectError.removed }
            return created
        }
    }

    mutating func apply(_ event: DynamicObjectEvent) {
        switch event {
        case .created(let name, let behavior, let id, let start, let scope, let at):
            created = Created(name: name, behavior: behavior, id: id, scope: scope, createdAt: at, removed: false)
            fields = start
        case .adopted(let behavior):
            created?.behavior = behavior
        case .handled(let changes, let state):
            fields.merge(changes) { _, changed in changed }
            current = state
        case .removed:
            created?.removed = true
        }
    }
}

/// Which behavior an object runs, shared with every object running the same one.
public struct BehaviorID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func new() -> BehaviorID {
        BehaviorID(rawValue: UUID().uuidString.lowercased())
    }
}

/// A dynamic object's own identity, given when it's created and kept across restarts.
public struct ObjectIdentity: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new, unique identity.
    public static func new() -> ObjectIdentity {
        ObjectIdentity(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

/// A dynamic object in a signature, such as an object to change, is a reference to it.
extension DynamicObject: Describable {
    public static var jsonSchema: JSONValue {
        _DiscoverySupport.actorReferenceSchema
    }
}

/// An identity in a signature is its string.
extension ObjectIdentity: Describable {
    public static var jsonSchema: JSONValue {
        ["type": "string", "description": "An object's identity."]
    }
}

public enum DynamicObjectError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case notCreated
    case alreadyCreated
    case removed
    case noReference(String)
    case noObjectNamed(String)

    public var description: String {
        switch self {
        case .notCreated: "This object hasn't been created yet."
        case .alreadyCreated: "This object already exists."
        case .removed: "This object was removed."
        case .noReference(let value): "\(value) isn't an object to send to."
        case .noObjectNamed(let name): "There's no object named `\(name)`."
        }
    }
}
