import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import VirtualActors

/// One owner's protocols, behaviors and objects, the way an Erlang node holds its modules and a
/// supervisor its processes. There's one per scope, reached by the scope alone.
///
/// It's where things are checked before they run: a spec is linked against the protocols here
/// and the objects it names, and a new protocol or spec against everything that uses it. A
/// behavior can be shared by several objects; a new spec for it reloads each of them, once it's
/// idle, the way a new module reaches every process running it. It keeps its objects running:
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

    /// Creates an object named `name`, running a new behavior from its spec, with any new
    /// protocols it introduces, or the behavior of an object here, shared from then on.
    /// - Parameter start: Values it starts with instead of the behavior's, where given.
    public distributed func create(name: String, spec: Spec, start: [String: JSONValue] = [:]) async throws
        -> ObjectIdentity
    {
        guard !state.hasObject(named: name) else { throw DynamicObjectsError.nameTaken(name) }
        var introduced: [MessageProtocol] = []
        if case .written(_, let protocols) = spec, !protocols.isEmpty {
            introduced = try MessageProtocol.read(protocols, known: state.protocols)
            if let taken = introduced.first(where: { state.protocols[$0.name] != nil }) {
                throw BehaviorError(
                    "There's a protocol `\(taken.name)` already. Use it by name in the spec, or change it with update.")
            }
        }
        var known = state.protocols
        for written in introduced { known[written.name] = written }

        let id: BehaviorID
        let behavior: Behavior
        switch spec {
        case .written(let written, _):
            behavior = try Behavior(name: name, written: written, protocols: known)
            try await checkSends(of: behavior)
            id = .new()
        case .sameAs(let object):
            let identity = try await object.identity
            guard let entry = state.entries.first(where: { $0.identity == identity }), let shared = state.behaviors[entry.behavior]
            else { throw DynamicObjectsError.unknownObject(identity) }
            (id, behavior) = (entry.behavior, shared)
        }
        try DynamicObject.check(start, against: behavior)

        if !introduced.isEmpty { try await emit(event: .protocolsWritten(introduced)) }
        if case .sameAs = spec {} else { try await emit(event: .behaviorWritten(id, behavior)) }
        let identity = ObjectIdentity.new()
        try await object(identity)
            .create(name: name, behavior: behavior, id: id, start: start, scope: scope)
        try await emit(event: .added(identity, name: name, behavior: id))
        return identity
    }

    /// Changes an object's spec, which changes every object sharing it, or protocols, which are
    /// checked against every spec that uses them.
    public distributed func update(_ identity: ObjectIdentity, change: Change) async throws {
        guard let entry = state.entries.first(where: { $0.identity == identity }), let old = state.behaviors[entry.behavior]
        else { throw DynamicObjectsError.unknownObject(identity) }
        switch change {
        case .spec(let written):
            let new = try Behavior(name: old.name, written: written, protocols: state.protocols)
            try new.check(replacing: old)
            try await checkSends(of: new)
            try await checkStates(of: entry.behavior, against: new)
            try await emit(event: .behaviorWritten(entry.behavior, new))
            try await adopt(entry.behavior)
        case .protocols(let protocols):
            let written = try MessageProtocol.read(protocols, known: state.protocols)
            var known = state.protocols
            for protocolWritten in written { known[protocolWritten.name] = protocolWritten }
            var relinked: [(BehaviorID, Behavior)] = []
            for (id, behavior) in state.behaviors where written.contains(where: { behavior.uses($0.name) }) {
                do {
                    relinked.append((id, try Behavior(name: behavior.name, written: behavior.source, protocols: known)))
                } catch {
                    throw BehaviorError("This version breaks the spec of \(behavior.name): \(error.description)")
                }
            }
            try await emit(event: .protocolsWritten(written))
            for (id, behavior) in relinked {
                try await emit(event: .behaviorWritten(id, behavior))
                try await adopt(id)
            }
        }
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

    /// Every object running `id` is in a state the new spec still has, so none is stranded.
    private func checkStates(of id: BehaviorID, against new: Behavior) async throws {
        let states = Set(new.clauses.compactMap(\.state) + [new.initial].compactMap { $0 })
        for entry in state.entries where entry.behavior == id {
            guard let current = try await object(entry.identity).current else { continue }
            guard states.contains(current) else {
                throw BehaviorError(
                    "\(entry.name) is in `\(current)`, which the new spec doesn't have, so it would lose where it is. Keep a clause `in: \(current)`.")
            }
        }
    }

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
                let accepted = try await accepted(by: name, from: clause)
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
    /// what it describes, for any other.
    private func accepted(by name: String, from clause: Behavior.Clause) async throws -> MessageProtocol {
        if let entry = state.entries.first(where: { ObjectNames.matches(name, title: $0.name) }),
            let behavior = state.behaviors[entry.behavior]
        {
            return MessageProtocol(name: entry.name, messages: behavior.messages)
        }
        guard let (_, description) = await ObjectNames.object(
            named: name, in: DynamicObject.scopes(around: scope), using: actorSystem)
        else {
            throw BehaviorError(
                "`\(clause.message.name)` sends to `\(name)`, but there's no object named \(name). Send to an object by its handle, such as `shop`, or to a parameter.")
        }
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
    /// A new behavior, from its spec, with any protocols it introduces.
    case written(Behavior.Written, protocols: [MessageProtocol.Written])
    /// The behavior another object runs, shared from then on.
    case sameAs(DynamicObject)
}

/// One change to an object.
public enum Change: Codable, Sendable, Equatable {
    /// Its spec: every object sharing its behavior changes too.
    case spec(Behavior.Written)
    /// Protocols, new or changed: checked against every spec that uses them.
    case protocols([MessageProtocol.Written])
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
    /// Whether it speaks, or types a parameter with, the protocol `name`.
    func uses(_ name: String) -> Bool {
        speaks.contains { $0.name == name }
            || clauses.contains { clause in clause.message.parameters.contains { $0.type == .speaks(name) } }
    }
}

/// What happened to an owner's protocols, behaviors and objects, as journaled.
public enum DynamicObjectsEvent: Codable, Sendable {
    case protocolsWritten([MessageProtocol])
    /// A behavior's spec, new or changed.
    case behaviorWritten(BehaviorID, Behavior)
    case added(ObjectIdentity, name: String, behavior: BehaviorID)
    case removed(ObjectIdentity)
}

public struct DynamicObjectsState: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let identity: ObjectIdentity
        public let name: String
        public let behavior: BehaviorID
    }

    /// The protocols, by name.
    public var protocols: [String: MessageProtocol] = [:]
    /// Each behavior as it is now.
    public var behaviors: [BehaviorID: Behavior] = [:]
    /// The objects here, oldest first.
    public var entries: [Entry] = []

    public init() {}

    public var identities: [ObjectIdentity] { entries.map(\.identity) }

    /// Whether an object here has this name, ignoring case and surrounding spaces.
    func hasObject(named name: String) -> Bool {
        entries.contains { Self.key($0.name) == Self.key(name) }
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    mutating func apply(_ event: DynamicObjectsEvent) {
        switch event {
        case .protocolsWritten(let written):
            for protocolWritten in written { protocols[protocolWritten.name] = protocolWritten }
        case .behaviorWritten(let id, let behavior):
            behaviors[id] = behavior
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

    public var description: String {
        switch self {
        case .unknownObject(let identity):
            "There's no object \(identity) here."
        case .nameTaken(let name):
            "An object named \(name) already exists. To change it, define it with its handle, or choose another name."
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
