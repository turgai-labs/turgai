import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import VirtualActors

/// One owner's behaviors and objects, the way an Erlang node holds its modules and a supervisor
/// its processes. There's one per scope, reached by the scope alone.
///
/// It's where things are checked before they run. An object's type is its behavior: a spec is
/// linked against what the objects it refers to take, and a new spec against every spec that
/// refers to objects running it. A behavior can be shared by several objects; a new spec for it
/// reloads each of them, once it's idle, the way a new module reaches every process running it. It keeps its objects running:
/// ``start()`` starts each one, so they stay findable after a restart.
@EventSourced
@VirtualActor
public distributed actor DynamicObjects {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = ObjectScope
    public typealias Event = DynamicObjectsEvent
    public typealias State = DynamicObjectsState

    public var state = DynamicObjectsState()
    private let scope: ObjectScope
    /// Stable references to its objects, resolved once each.
    private var resolved: [ObjectIdentity: DynamicObject] = [:]

    public init(actorSystem: ClusterSystem, dependency scope: ObjectScope) async throws {
        self.actorSystem = actorSystem
        self.scope = scope
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: scope))
    }

    /// The objects of `scope`.
    public static func resolve(on system: ClusterSystem, scope: ObjectScope) async throws -> DynamicObjects {
        try await system.virtualActors.getActor(identifiedBy: actorID(for: scope), dependency: scope)
    }

    static func actorID(for scope: ObjectScope) -> VirtualActorID {
        VirtualActorID(rawValue: "dynamic-objects:\(scope.name)")
    }

    static func persistenceID(for scope: ObjectScope) -> String {
        "turgai-objects-\(scope.name)"
    }

    // MARK: Objects

    /// Creates an object named `name`, running a new behavior from its spec, or the behavior of
    /// an object here, shared from then on.
    /// - Parameter start: Values it starts with instead of the behavior's, where given.
    public distributed func create(name: String, spec: Spec, start: [String: JSONValue] = [:]) async throws
        -> ObjectIdentity
    {
        guard !state.hasObject(named: name), state.kind(named: name) == nil else {
            throw DynamicObjectsError.nameTaken(name)
        }
        let id: BehaviorID
        let behavior: Behavior
        switch spec {
        case .written(let written):
            behavior = try Behavior(name: name, written: written, objects: knownObjects)
            try await checkSends(of: behavior)
            id = .new()
        case .sameAs(let object):
            let identity = try await object.identity
            guard let entry = state.entries.first(where: { $0.identity == identity }), let shared = state.behaviors[entry.behavior]
            else { throw DynamicObjectsError.unknownObject(identity) }
            (id, behavior) = (entry.behavior, shared)
        case .kind(let kind):
            guard let shared = state.kind(named: kind), let found = state.behaviors[shared] else {
                throw DynamicObjectsError.unknownKind(kind)
            }
            (id, behavior) = (shared, found)
        }
        try DynamicObject.check(start, against: behavior)

        if case .written = spec { try await emit(event: .behaviorWritten(id, behavior)) }
        let identity = ObjectIdentity.new()
        try await object(identity)
            .create(name: name, behavior: behavior, id: id, start: start, scope: scope)
        try await emit(event: .added(identity, name: name, behavior: id))
        return identity
    }

    /// The other objects running the same behavior as the object `identity`, by name.
    public distributed func sharing(_ identity: ObjectIdentity) throws -> [String] {
        guard let entry = state.entries.first(where: { $0.identity == identity }) else {
            throw DynamicObjectsError.unknownObject(identity)
        }
        return state.entries.filter { $0.behavior == entry.behavior && $0.identity != identity }.map(\.name)
    }

    /// Changes an object's spec, which changes every object sharing it. Every spec that refers to
    /// those objects is checked against the new one, and the change is refused if one would break.
    public distributed func update(_ identity: ObjectIdentity, spec written: Behavior.Written) async throws {
        guard let entry = state.entries.first(where: { $0.identity == identity }) else {
            throw DynamicObjectsError.unknownObject(identity)
        }
        try await rewrite(entry.behavior, as: written)
    }

    /// Defines a kind: a behavior with a name and no object, which objects can share and others
    /// can be typed like. Defined again, it changes, and so does every object sharing it.
    public distributed func defineKind(_ name: String, spec written: Behavior.Written) async throws {
        if let id = state.kind(named: name) {
            try await rewrite(id, as: written)
            return
        }
        guard !state.hasObject(named: name) else { throw DynamicObjectsError.nameTaken(name) }
        let behavior = try Behavior(name: name, written: written, objects: knownObjects)
        try await checkSends(of: behavior)
        let id = BehaviorID.new()
        try await emit(event: .behaviorWritten(id, behavior))
        try await emit(event: .kindNamed(name, id))
    }

    /// Gives the behavior `id` a new spec: checked as a new one is, and against every spec that
    /// refers to the objects or kind running it. Each object running it adopts it once it's idle.
    private func rewrite(_ id: BehaviorID, as written: Behavior.Written) async throws {
        guard let old = state.behaviors[id] else { throw DynamicObjectsError.unknownBehavior }
        let new = try Behavior(name: old.name, written: written, objects: knownObjects)
        try await checkSends(of: new)
        // The names this behavior goes by, and what they'll take.
        let names = state.entries.filter { $0.behavior == id }.map(\.name) + state.kinds.filter { $0.value == id }.map(\.key)
        let sharing = Set(names.flatMap { [$0, ObjectNames.handle(for: $0)] })
        var objects = knownObjects
        for name in sharing { objects[name] = MessageProtocol(name: name, messages: new.messages) }
        for (other, behavior) in state.behaviors where other != id && behavior.refers(to: sharing) {
            do {
                _ = try Behavior(name: behavior.name, written: behavior.source, objects: objects)
            } catch {
                throw BehaviorError("This breaks the spec of \(behavior.name): \(error.description)")
            }
        }
        try await emit(event: .behaviorWritten(id, new))
        try await adopt(id)
    }

    /// What each object and kind here takes, by its name and its handle: an object's type is its
    /// behavior.
    private var knownObjects: [String: MessageProtocol] {
        var objects: [String: MessageProtocol] = [:]
        for (kind, id) in state.kinds {
            guard let behavior = state.behaviors[id] else { continue }
            let messages = MessageProtocol(name: kind, messages: behavior.messages)
            objects[kind] = messages
            objects[ObjectNames.handle(for: kind)] = messages
        }
        for entry in state.entries {
            guard let behavior = state.behaviors[entry.behavior] else { continue }
            let messages = MessageProtocol(name: entry.name, messages: behavior.messages)
            objects[entry.name] = messages
            objects[ObjectNames.handle(for: entry.name)] = messages
        }
        return objects
    }

    /// Removes one of these objects for good.
    public distributed func remove(_ identity: ObjectIdentity) async throws {
        guard state.identities.contains(identity) else { throw DynamicObjectsError.unknownObject(identity) }
        try await object(identity).remove()
        try await emit(event: .removed(identity))
    }

    /// Starts every object here. The server does this when it starts.
    public distributed func start() async throws {
        for identity in state.identities {
            try await object(identity).start()
        }
    }

    /// The object with `identity`: a stable reference, resolved once.
    private func object(_ identity: ObjectIdentity) async throws -> DynamicObject {
        if let object = resolved[identity] { return object }
        let object = try await DynamicObject.resolve(on: actorSystem, identity: identity)
        resolved[identity] = object
        return object
    }

    /// Every object here, by identity, oldest first.
    public distributed var identities: [ObjectIdentity] { state.identities }

    /// It keeps its objects running, so it keeps running itself.
    public func shouldDeactivate() async -> Bool { false }

    public func handleEvent(_ event: DynamicObjectsEvent) {
        state.apply(event)
    }

    // MARK: Checks

    /// Hands the behavior `id`, as it is now, to every object running it, each once it's idle.
    private func adopt(_ id: BehaviorID) async throws {
        guard let behavior = state.behaviors[id] else { return }
        for entry in state.entries where entry.behavior == id {
            try await object(entry.identity).adopt(behavior)
        }
    }

    /// Sends to objects by name go to objects that exist, with messages they take and arguments
    /// they accept.
    private func checkSends(of behavior: Behavior) async throws {
        for clause in behavior.clauses {
            for case .send(let target, let message, let arguments) in clause.actions {
                let name: String
                switch target {
                case .object(let object): name = object
                case .field(let field):
                    guard case .object(let object)? = behavior.fields[field] else { continue }
                    name = object
                default: continue
                }
                guard let accepted = await accepted(by: name) else { continue }
                guard let expected = accepted.messages.first(where: { $0.name == message }) else {
                    throw BehaviorError(
                        "`\(clause.message.name)` sends `\(message)` to \(accepted.name), which doesn't take it. \(accepted.name) takes \(accepted.messages.map { "`\($0.written)`" }.joined(separator: ", ")).")
                }
                let given = arguments.map(\.name).sorted()
                guard given == expected.parameters.map(\.name).sorted() else {
                    throw BehaviorError(
                        "`\(clause.message.name)` sends \(accepted.name) `\(message)` with \(given.isEmpty ? "nothing" : given.map { "`\($0)`" }.joined(separator: ", ")), but it's `\(expected.written)`.")
                }
            }
        }
    }

    /// What the object named `name` accepts: its whole behavior if it's one of these objects, or
    /// what it describes, for any other. `nil` for an object not defined yet, which is checked when
    /// a message reaches it.
    private func accepted(by name: String) async -> MessageProtocol? {
        if let entry = state.entries.first(where: { ObjectNames.matches(name, title: $0.name) }),
            let behavior = state.behaviors[entry.behavior]
        {
            return MessageProtocol(name: entry.name, messages: behavior.messages)
        }
        guard let (_, description) = await ObjectNames.object(
            named: name, in: DynamicObject.scopes(around: scope), using: actorSystem)
        else { return nil }
        return Self.accepted(by: description)
    }

    /// What an object accepts, read from how it describes itself: each action with its
    /// parameters' types, whatever the object is made of.
    static func accepted(by description: ObjectDescription) -> MessageProtocol {
        let messages = description.actions.keys.sorted().map { action -> Signature in
            let input = description.actions[action]?.input
            let properties: [String: JSONValue] = if case .object(let members)? = input?["properties"] { members } else { [:] }
            let parameters = properties.keys.sorted().map { name in
                Parameter(name: name, type: ValueType(schema: properties[name] ?? .null))
            }
            return Signature(name: action, parameters: parameters)
        }
        return MessageProtocol(name: description.title, messages: messages)
    }
}

/// Where a new object's behavior comes from.
public enum Spec: Codable, Sendable, Equatable {
    /// A new behavior, from its spec.
    case written(Behavior.Written)
    /// The behavior another object runs, shared from then on.
    case sameAs(DynamicObject)
    /// A kind's behavior, shared from then on.
    case kind(String)
}

extension ValueType {
    /// The type a JSON Schema describes, as far as ours go: anything else is `object`.
    init(schema: JSONValue) {
        if schema["x-actor-reference"] == .bool(true) {
            self = .object
            return
        }
        switch schema["type"] {
        case "string": self = .string
        case "integer": self = .integer
        case "number": self = .number
        case "boolean": self = .boolean
        case "array": self = .list
        default: self = .object
        }
    }
}

extension Behavior {
    /// Whether it refers to any of the objects `names`: as a field, a parameter's type, or where
    /// it sends.
    func refers(to names: Set<String>) -> Bool {
        fields.values.contains { if case .object(let name) = $0 { names.contains(name) } else { false } }
            || clauses.contains { clause in
                clause.message.parameters.contains { if case .like(let name) = $0.type { names.contains(name) } else { false } }
                    || clause.actions.contains { if case .send(.object(let name), _, _) = $0 { names.contains(name) } else { false } }
            }
    }
}

/// What happened to an owner's behaviors and objects, as journaled.
public enum DynamicObjectsEvent: Codable, Sendable {
    /// A behavior's spec, new or changed.
    case behaviorWritten(BehaviorID, Behavior)
    /// A behavior named as a kind.
    case kindNamed(String, BehaviorID)
    case added(ObjectIdentity, name: String, behavior: BehaviorID)
    case removed(ObjectIdentity)
}

public struct DynamicObjectsState: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let identity: ObjectIdentity
        public let name: String
        public let behavior: BehaviorID
    }

    /// Each behavior as it is now.
    public var behaviors: [BehaviorID: Behavior] = [:]
    /// The kinds: behaviors named, with no object of their own.
    public var kinds: [String: BehaviorID] = [:]
    /// The objects here, oldest first.
    public var entries: [Entry] = []

    public init() {}

    public var identities: [ObjectIdentity] { entries.map(\.identity) }

    /// Whether an object here has this name, ignoring case and surrounding spaces.
    func hasObject(named name: String) -> Bool {
        entries.contains { Self.key($0.name) == Self.key(name) }
    }

    /// The kind called `name`, by its name or its handle.
    func kind(named name: String) -> BehaviorID? {
        kinds.first { Self.key($0.key) == Self.key(name) || ObjectNames.handle(for: $0.key) == name }?.value
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    mutating func apply(_ event: DynamicObjectsEvent) {
        switch event {
        case .behaviorWritten(let id, let behavior):
            behaviors[id] = behavior
        case .kindNamed(let name, let id):
            kinds[name] = id
        case .added(let identity, let name, let behavior):
            entries.append(Entry(identity: identity, name: name, behavior: behavior))
        case .removed(let identity):
            entries.removeAll { $0.identity == identity }
        }
    }
}

public enum DynamicObjectsError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case unknownObject(ObjectIdentity)
    case nameTaken(String)
    case unknownKind(String)
    case unknownBehavior

    public var description: String {
        switch self {
        case .unknownObject(let identity):
            "There's no object \(identity) here."
        case .nameTaken(let name):
            "An object or kind named \(name) already exists. To change it, define it with its handle, or choose another name."
        case .unknownKind(let name):
            "There's no object or kind \(name) here."
        case .unknownBehavior:
            "That behavior is gone."
        }
    }
}

extension ObjectScope {
    /// A name for keys and journals: `shared`, or `owned.<user>`.
    var name: String {
        switch self {
        case .shared: "shared"
        case .owned(let user): "owned.\(user.rawValue)"
        }
    }
}
