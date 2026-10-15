import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import VirtualActors

/// One owner's kinds and objects, the way an Erlang node holds its modules and a supervisor its
/// processes. There's one per scope, reached by the scope alone.
///
/// It's where a kind is checked before it runs: its Swift reads, its objects start with their
/// checks holding, and what it sends to the objects it names is something they take now. Objects
/// aren't typed, so nothing is checked between kinds: an object checks every message when it
/// arrives. A kind can be shared by several objects; a new version of it reaches each of them,
/// once it's idle, the way a new module reaches every process running it. It keeps its objects
/// running: ``start()`` starts each one, so they stay findable after a restart.
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

    /// Creates an object named `name`, running a new kind, a named kind, or the kind of an object
    /// here, shared from then on.
    /// - Parameter start: Values it holds instead of its kind's starting ones, where given.
    public distributed func create(name: String, description: String? = nil, spec: Spec, start: [String: JSONValue] = [:]) async throws
        -> ObjectIdentity
    {
        guard !state.hasObject(named: name), state.kind(named: name) == nil else {
            throw DynamicObjectsError.nameTaken(name)
        }
        let id: BehaviorID
        let kind: Script
        switch spec {
        case .new(let source):
            try await check(source)
            (id, kind) = (.new(), source)
            try await emit(event: .kindWritten(id, kind))
        case .sameAs(let object):
            let identity = try await object.identity
            guard let entry = state.entries.first(where: { $0.identity == identity }), let shared = state.kinds[entry.kind]
            else { throw DynamicObjectsError.unknownObject(identity) }
            (id, kind) = (entry.kind, shared)
        case .kind(let name):
            guard let shared = state.kind(named: name), let found = state.kinds[shared] else {
                throw DynamicObjectsError.unknownKind(name)
            }
            (id, kind) = (shared, found)
        }
        return try await make(name: name, description: description, kind: kind, id: id, start: start)
    }

    /// The object with id `id`, running the kind whose actor is `type`, made from that kind with
    /// `init()` when there's none yet: the way code reaches an object by its type. Its id is its
    /// name, for now.
    public distributed func object(id: String, type: String) async throws -> ObjectIdentity {
        if let entry = state.entry(named: id) {
            guard state.kinds[entry.kind]?.type == type else {
                throw DynamicObjectsError.otherKind(id, type: type)
            }
            return entry.identity
        }
        guard let kind = state.kind(ofType: type), let source = state.kinds[kind] else {
            throw DynamicObjectsError.unknownKind(type)
        }
        return try await make(name: id, description: nil, kind: source, id: kind, start: [:])
    }

    /// The kinds here no object runs yet, each one's spec by the type its code declares: what an
    /// object made with `Type()` will be.
    public distributed func unmadeKinds() throws -> [String: ObjectDescription] {
        let running = Set(state.entries.map(\.kind))
        var specs: [String: ObjectDescription] = [:]
        for (name, kind) in state.named where !running.contains(kind) {
            guard let source = state.kinds[kind] else { continue }
            specs[source.type] = try source.spec(title: name, description: nil)
        }
        return specs
    }

    /// Makes an object named `name`, running `kind`, holding its starting values, with `start` in
    /// place of those it gives.
    private func make(name: String, description: String?, kind: Script, id: BehaviorID, start: [String: JSONValue]) async throws
        -> ObjectIdentity
    {
        let starts = try await ScriptInstance.starts(kind)
        if let unknown = start.keys.sorted().first(where: { starts[$0] == nil }) {
            throw CodeProblem("It holds no `\(unknown)`. It holds \(starts.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")).")
        }
        let identity = ObjectIdentity.new()
        try await object(identity)
            .create(name: name, description: description, kind: kind, id: id, start: starts.merging(start) { _, given in given }, scope: scope)
        try await emit(event: .added(identity, name: name, kind: id))
        return identity
    }

    /// The other objects running the same kind as the object `identity`, by name.
    public distributed func sharing(_ identity: ObjectIdentity) throws -> [String] {
        guard let entry = state.entries.first(where: { $0.identity == identity }) else {
            throw DynamicObjectsError.unknownObject(identity)
        }
        return state.entries.filter { $0.kind == entry.kind && $0.identity != identity }.map(\.name)
    }

    /// Changes an object's kind, which changes every object sharing it.
    public distributed func update(_ identity: ObjectIdentity, source: Script) async throws {
        guard let entry = state.entries.first(where: { $0.identity == identity }) else {
            throw DynamicObjectsError.unknownObject(identity)
        }
        try await rewrite(entry.kind, as: source)
    }

    /// Defines a kind: one with a name and no object, which objects can share. Defined again, it
    /// changes, and so does every object sharing it.
    public distributed func defineKind(_ name: String, source: Script) async throws {
        if let id = state.kind(named: name) {
            try await rewrite(id, as: source)
            return
        }
        guard !state.hasObject(named: name) else { throw DynamicObjectsError.nameTaken(name) }
        try await check(source)
        let id = BehaviorID.new()
        try await emit(event: .kindWritten(id, source))
        try await emit(event: .kindNamed(name, id))
    }

    /// Gives the kind `id` a new version, checked as a new one is. Each object running it adopts
    /// it once it's idle.
    private func rewrite(_ id: BehaviorID, as source: Script) async throws {
        guard state.kinds[id] != nil else { throw DynamicObjectsError.unknownKind(id.rawValue) }
        try await check(source)
        let starts = try await ScriptInstance.starts(source)
        try await emit(event: .kindWritten(id, source))
        for entry in state.entries where entry.kind == id {
            try await object(entry.identity).adopt(source, starts: starts)
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

    /// What's wrong with a kind's own code before it runs: its Swift reads, an object of it
    /// starts with its checks holding, and what it reads of itself it declares. Other objects
    /// aren't read: each checks the messages it's sent, when they arrive.
    private func check(_ source: Script) async throws {
        _ = try await ScriptInstance.starts(source)
        let problems = source.selfProblems
        if !problems.isEmpty { throw CodeProblem(problems.map(\.description).joined(separator: "\n")) }
    }
}

extension ObjectShape.Message {
    /// The message as its typing: its name, and its parameters' types.
    var signature: Signature {
        Signature(name: name, parameters: parameters.map { Parameter(name: $0.name, type: $0.kind.valueType) }, reply: reply?.valueType)
    }
}

extension ValueKind {
    var valueType: ValueType {
        switch self {
        case .int: .integer
        case .double: .number
        case .string: .string
        case .bool: .boolean
        case .list: .list
        case .map, .object, .other: .object
        }
    }
}

/// Where a new object's kind comes from.
public enum Spec: Codable, Sendable, Equatable {
    /// A new kind, from its source.
    case new(Script)
    /// The kind another object runs, shared from then on.
    case sameAs(DynamicObject)
    /// A named kind, shared from then on.
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

/// What happened to an owner's kinds and objects, as journaled.
public enum DynamicObjectsEvent: Codable, Sendable {
    /// A kind, new or changed.
    case kindWritten(BehaviorID, Script)
    /// A kind named, with no object of its own.
    case kindNamed(String, BehaviorID)
    case added(ObjectIdentity, name: String, kind: BehaviorID)
    case removed(ObjectIdentity)
}

public struct DynamicObjectsState: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let identity: ObjectIdentity
        public let name: String
        public let kind: BehaviorID
    }

    /// Each kind as it is now.
    public var kinds: [BehaviorID: Script] = [:]
    /// The named kinds, with no object of their own.
    public var named: [String: BehaviorID] = [:]
    /// The objects here, oldest first.
    public var entries: [Entry] = []

    public init() {}

    public var identities: [ObjectIdentity] { entries.map(\.identity) }

    /// Whether an object here has this name, ignoring case and surrounding spaces.
    func hasObject(named name: String) -> Bool {
        entry(named: name) != nil
    }

    /// The object here with this name, ignoring case and surrounding spaces.
    func entry(named name: String) -> Entry? {
        entries.first { Self.key($0.name) == Self.key(name) }
    }

    /// The kind whose actor is `type`: an object's here first, then a named one.
    func kind(ofType type: String) -> BehaviorID? {
        entries.lazy.map(\.kind).first { kinds[$0]?.type == type }
            ?? named.values.first { kinds[$0]?.type == type }
    }

    /// The kind called `name`, by its name or its handle.
    func kind(named name: String) -> BehaviorID? {
        named.first { Self.key($0.key) == Self.key(name) || ObjectNames.handle(for: $0.key) == name }?.value
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    mutating func apply(_ event: DynamicObjectsEvent) {
        switch event {
        case .kindWritten(let id, let kind):
            kinds[id] = kind
        case .kindNamed(let name, let id):
            named[name] = id
        case .added(let identity, let name, let kind):
            entries.append(Entry(identity: identity, name: name, kind: kind))
        case .removed(let identity):
            entries.removeAll { $0.identity == identity }
        }
    }
}

public enum DynamicObjectsError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case unknownObject(ObjectIdentity)
    case nameTaken(String)
    case unknownKind(String)
    case otherKind(String, type: String)

    public var description: String {
        switch self {
        case .otherKind(let id, let type):
            "\(id) is an object of another kind, not \(type)."
        case .unknownObject(let identity):
            "There's no object \(identity) here."
        case .nameTaken(let name):
            "An object or kind named \(name) already exists. To change it, write it with its handle, or choose another name."
        case .unknownKind(let name):
            "There's no object or kind \(name) here."
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
