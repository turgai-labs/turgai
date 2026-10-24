import DiscoverableActors
import Distributed
import DistributedCluster
import VirtualActors

/// Which object something is, as the system knows it, and as models and people are shown it: the
/// system's own id, and nothing else.
public enum ObjectID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    /// A virtual actor, by its id: the same wherever and whenever it runs.
    case virtual(VirtualActorID)
    /// Any other actor, by its id: which it is while it lives. With the type it's found by when
    /// it's the one of its kind checked in here.
    case actor(ClusterSystem.ActorID, type: String?)

    /// What it's called: a virtual actor's id within its scope, the part after it; the type of the
    /// one of its kind checked in here. One an action returned, of a type there can be many of, is
    /// called by its id.
    public var name: String {
        switch self {
        case .virtual(let id): id.rawValue.split(separator: "/").last.map(String.init) ?? id.rawValue
        case .actor(_, let type?): ObjectNames.handle(for: type)
        case .actor(let id, nil): "\(id.node)\(id.path)"
        }
    }

    /// How it's written: its name, which reads back as it.
    public var description: String { name }

    /// In the order they're written in, as they're listed.
    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool {
        lhs.description < rhs.description
    }
}

/// A catalog entry ready to show to a model.
public struct ObjectEntry: Codable, Sendable {
    public let id: ObjectID
    public let object: DiscoverableObject
    /// The type it is of.
    public let type: String
    public let description: String?
    public let scope: ObjectScope
    /// Each action with its arguments, such as `play(query)`.
    public let actions: [String]
    /// What the object announces, such as `RefundRequested`.
    public let events: [String]

    public init(
        id: ObjectID,
        object: DiscoverableObject,
        type: String,
        description: String?,
        scope: ObjectScope,
        actions: [String],
        events: [String] = []
    ) {
        self.id = id
        self.object = object
        self.type = type
        self.description = description
        self.scope = scope
        self.actions = actions
        self.events = events
    }
}

/// Lists the objects of each scope: the ones its directory holds, and the ones that check in
/// with the cluster receptionist themselves, whose descriptions it follows and caches.
/// Actor references are resolved from IDs when requested, so the catalog doesn't
/// keep root actors alive.
public distributed actor ObjectCatalog: LifecycleWatch {
    public typealias ActorSystem = ClusterSystem

    public struct Record: Sendable {
        public let id: ClusterSystem.ActorID
        public let type: String
        public let description: String?
        public let actions: [String]
        public let events: [String]
    }

    private var records: [ObjectScope: [ClusterSystem.ActorID: Record]] = [:]
    private var listingTasks: [ObjectScope: Task<Void, Never>] = [:]
    private var observers: [AsyncStream<Void>.Continuation] = []

    public init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem
        self.startListing(for: .shared)
    }

    public func terminated(actor id: ActorID) async {
        for scope in Array(self.records.keys) { self.records[scope]?.removeValue(forKey: id) }
        self.notifyObservers()
    }

    /// Yields now and whenever an object joins or leaves the catalog.
    public func changes() -> AsyncStream<Void> {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield()
        self.observers.append(continuation)
        return changes
    }

    /// An object a scope holds was made, changed or removed: whoever follows changes looks again.
    public distributed func changed() {
        notifyObservers()
    }

    private func notifyObservers() {
        self.observers.removeAll { observer in
            if case .terminated = observer.yield() { true } else { false }
        }
    }

    deinit {
        for task in self.listingTasks.values { task.cancel() }
    }

    private func startListing(for scope: ObjectScope) {
        guard self.listingTasks[scope] == nil else { return }
        let system = actorSystem
        let key = scope.receptionistKey
        self.listingTasks[scope] = Task { [weak self] in
            for await object in await system.receptionist.listing(of: key) {
                guard !Task.isCancelled else { return }
                try? await self?.record(object, in: scope)
            }
        }
    }

    /// Records an object as it is now: what the receptionist lists, and what was just made or
    /// changed, which its listing only shows later.
    public distributed func record(_ object: DiscoverableObject, in scope: ObjectScope) async {
        do {
            let description = try await object.describe()
            self.records[scope, default: [:]][object.id] = Record(
                id: object.id,
                type: description.type,
                description: description.description,
                actions: description.actions.map { Self.signature($0.key, input: $0.value.input) }.sorted(),
                events: description.events.keys.sorted()
            )
            self.watchTermination(of: object)
            self.notifyObservers()
        } catch {
            actorSystem.log.warning(
                "Could not add object to the catalog",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    /// An action with its argument names, such as `add(title, notes?)`, so a model
    /// can call it without describing the object first.
    public static func signature(_ name: String, input: JSONValue?) -> String {
        guard case .object(let properties)? = input?["properties"], !properties.isEmpty else { return "\(name)()" }
        let required: [String] =
            if case .array(let names)? = input?["required"] {
                names.compactMap { if case .string(let name) = $0 { name } else { nil } }
            } else { [] }
        // As Swift declares it, with its label, when its schema keeps it.
        func declared(_ name: String, _ schema: JSONValue) -> String {
            let type = schema.swiftType.map { ": \($0)" } ?? ""
            guard case .string(let label)? = schema[ObjectShape.Message.labelKey], label != name else {
                return name + type
            }
            return "\(label) \(name)\(type)"
        }
        let written =
            required.compactMap { name in properties[name].map { declared(name, $0) } }
            + properties.keys.filter { !required.contains($0) }.sorted().map { name in
                "\(name)" + (properties[name]!.swiftType.map { ": \($0)?" } ?? "?")
            }
        return "\(name)(\(written.joined(separator: ", ")))"
    }

    /// The objects in `scopes`: those each scope holds, from its own directory, and the objects
    /// that checked in there themselves, from the receptionist.
    public distributed func entries(in scopes: [ObjectScope]) async throws -> [ObjectEntry] {
        for scope in scopes { startListing(for: scope) }
        var entries: [ObjectEntry] = []
        var seen: Set<ClusterSystem.ActorID> = []
        for scope in scopes {
            for held in try await DynamicObjects.resolve(on: actorSystem, scope: scope).held()
            where seen.insert(held.object.id).inserted {
                entries.append(held)
            }
        }
        for scope in scopes {
            for record in self.records[scope, default: [:]].values where seen.insert(record.id).inserted {
                guard let object = try? DiscoverableObject.resolve(id: record.id, using: actorSystem) else { continue }
                entries.append(
                    ObjectEntry(
                        // A virtual actor by its id; any other, the one of its kind here, by its
                        // id with its type, which it's found by.
                        id: record.id.virtualActorID.map(ObjectID.virtual) ?? .actor(record.id, type: record.type),
                        object: object,
                        type: record.type,
                        description: record.description,
                        scope: scope,
                        actions: record.actions,
                        events: record.events
                    ))
            }
        }
        // By id, which is the same in every run, as an actor's path isn't.
        return entries.sorted { $0.id < $1.id }
    }
}
