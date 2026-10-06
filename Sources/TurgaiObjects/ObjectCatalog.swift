import DiscoverableActors
import Distributed
import DistributedCluster

/// A catalog entry ready to show to a model.
public struct ObjectEntry: Codable, Sendable {
    public let object: DiscoverableObject
    public let title: String
    public let description: String?
    public let scope: ObjectScope
    /// Each action with its arguments, such as `play(query)`.
    public let actions: [String]
    /// What the object announces, such as `RefundRequested`.
    public let events: [String]

    public init(
        object: DiscoverableObject,
        title: String,
        description: String?,
        scope: ObjectScope,
        actions: [String],
        events: [String] = []
    ) {
        self.object = object
        self.title = title
        self.description = description
        self.scope = scope
        self.actions = actions
        self.events = events
    }
}

/// Follows the cluster receptionist's listings and caches descriptions for roots.
/// Actor references are resolved from IDs when requested, so the catalog doesn't
/// keep root actors alive.
public distributed actor ObjectCatalog: LifecycleWatch {
    public typealias ActorSystem = ClusterSystem

    public struct Record: Sendable {
        public let id: ClusterSystem.ActorID
        public let title: String
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

    distributed func record(_ object: DiscoverableObject, in scope: ObjectScope) async {
        do {
            let description = try await object.describe()
            self.records[scope, default: [:]][object.id] = Record(
                id: object.id,
                title: description.title,
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
        let optional = properties.keys.filter { !required.contains($0) }.sorted().map { "\($0)?" }
        return "\(name)(\((required + optional).joined(separator: ", ")))"
    }

    public distributed func entries(in scopes: [ObjectScope]) -> [ObjectEntry] {
        for scope in scopes { startListing(for: scope) }
        var entries: [ObjectEntry] = []
        var seen: Set<ClusterSystem.ActorID> = []
        for scope in scopes {
            for record in self.records[scope, default: [:]].values where seen.insert(record.id).inserted {
                guard let object = try? DiscoverableObject.resolve(id: record.id, using: actorSystem) else { continue }
                entries.append(
                    ObjectEntry(
                        object: object,
                        title: record.title,
                        description: record.description,
                        scope: scope,
                        actions: record.actions,
                        events: record.events
                    ))
            }
        }
        return entries.sorted { $0.object.id.description < $1.object.id.description }
    }
}
