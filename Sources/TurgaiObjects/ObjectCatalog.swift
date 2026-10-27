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

    /// What it's called: the last part of a virtual actor's id; the type of the one of its kind
    /// checked in here. One an action returned, of a type there can be many of, is
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
    /// Each action with its arguments, such as `play(query)`.
    public let actions: [String]
    /// What the object announces, such as `RefundRequested`.
    public let events: [String]

    public init(
        id: ObjectID,
        object: DiscoverableObject,
        type: String,
        description: String?,
        actions: [String],
        events: [String] = []
    ) {
        self.id = id
        self.object = object
        self.type = type
        self.description = description
        self.actions = actions
        self.events = events
    }
}

/// Lists the objects: the ones the directory holds, and the ones that check in with the cluster
/// receptionist themselves, each described on behalf of whoever lists them. Actor references are
/// resolved from IDs when requested, so the catalog doesn't keep root actors alive.
public distributed actor ObjectCatalog: LifecycleWatch {
    public typealias ActorSystem = ClusterSystem

    /// The objects that checked in, until each is gone.
    private var checkedIn: Set<ClusterSystem.ActorID> = []
    private var listing: Task<Void, Never>?
    private var observers: [AsyncStream<Void>.Continuation] = []

    public init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem
        self.startListing()
    }

    public func terminated(actor id: ActorID) async {
        self.checkedIn.remove(id)
        self.notifyObservers()
    }

    /// Yields now and whenever an object joins or leaves the catalog.
    public func changes() -> AsyncStream<Void> {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield()
        self.observers.append(continuation)
        return changes
    }

    /// An object the directory holds was made, changed or removed: whoever follows changes looks again.
    public distributed func changed() {
        notifyObservers()
    }

    private func notifyObservers() {
        self.observers.removeAll { observer in
            if case .terminated = observer.yield() { true } else { false }
        }
    }

    deinit {
        self.listing?.cancel()
    }

    private func startListing() {
        let system = actorSystem
        self.listing = Task { [weak self] in
            for await object in await system.receptionist.listing(of: .objects) {
                guard !Task.isCancelled else { return }
                await self?.whenLocal { $0.checkIn(object) }
            }
        }
    }

    /// An object that checked in: listed from now on, until it's gone.
    private func checkIn(_ object: DiscoverableObject) {
        guard checkedIn.insert(object.id).inserted else { return }
        watchTermination(of: object)
        notifyObservers()
    }

    /// An action with its argument names, such as `add(title, notes?)`, so a model
    /// can call it without describing the object first.
    public static func signature(_ key: String, input: JSONValue?) -> String {
        let name = ActionKeys.baseName(of: key)
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

    /// The objects: those the directory holds, and the objects that checked in themselves, from
    /// the receptionist.
    public distributed func entries() async throws -> [ObjectEntry] {
        var entries: [ObjectEntry] = []
        var seen: Set<ClusterSystem.ActorID> = []
        let made = try await DynamicObjects.resolve(on: actorSystem).held()
        for held in made where seen.insert(held.object.id).inserted {
            entries.append(held)
        }
        // Each described on behalf of whoever lists: one they may not read isn't listed to them.
        for id in checkedIn where seen.insert(id).inserted {
            guard let object = try? DiscoverableObject.resolve(id: id, using: actorSystem),
                let description = try? await object.describe()
            else { continue }
            entries.append(
                ObjectEntry(
                    // A virtual actor by its id; any other, the one of its kind here, by its id with
                    // its type, which it's found by.
                    id: id.virtualActorID.map(ObjectID.virtual) ?? .actor(id, type: description.type),
                    object: object,
                    type: description.type,
                    description: description.description,
                    actions: description.actions.map { Self.signature($0.key, input: $0.value.input) }.sorted(),
                    events: description.events.keys.sorted()
                ))
        }
        // By id, which is the same in every run, as an actor's path isn't.
        return entries.sorted { $0.id < $1.id }
    }
}
