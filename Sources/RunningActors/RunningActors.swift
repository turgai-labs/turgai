public import Distributed
public import DistributedCluster
public import EventSourcing
public import VirtualActors

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// Keeps virtual actors' long-lived work going across node restarts. An actor keeps its work, a
/// loop or a task, through it: while any of an actor's kept work runs, the actor is on a list kept
/// in the journal, with what it's started with and whom it was kept for; once the last ends, it's
/// off it. A node that stops abruptly leaves its actors on it, and a node starting brings each one
/// back by its own id, as the node is configured to, retrying those it can't until it can or they
/// end. A node shutting down leaves the list as it is, so it all comes back.
public actor RunningActors: Plugin {
    public static let pluginKey: Key = "$runningActors"

    public nonisolated var key: Key { Self.pluginKey }

    /// How an actor of a type is brought back, given it, what it's started with, and whom it was
    /// kept for.
    public struct Recovery: Sendable {
        let typeName: String
        let recover: @Sendable (RunningEntry, ClusterSystem) async throws -> Void

        /// An actor of `type`, started with a `Dependency` and kept for a `KeptFor`, brought back by
        /// `call`: what activates it again.
        public static func of<Actor: VirtualActor, Dependency: Codable & Sendable, KeptFor: Codable & Sendable>(
            _ type: Actor.Type, dependency: Dependency.Type, keptFor: KeptFor.Type,
            _ call: @escaping @Sendable (Actor, Dependency, KeptFor) async throws -> Void
        ) -> Recovery {
            Recovery(typeName: String(reflecting: type)) { entry, system in
                let dependency = try JSONDecoder().decode(Dependency.self, from: entry.dependency)
                let keptFor = try JSONDecoder().decode(KeptFor.self, from: entry.keptFor)
                let actor: Actor = try await system.virtualActors.getActor(
                    identifiedBy: entry.id, dependency: dependency)
                try await call(actor, dependency, keptFor)
            }
        }
    }

    /// What the cluster knows the list by.
    static let singletonName = "running-actors"
    /// How long recovering waits before trying again those it couldn't bring back, at most.
    static let longestRetry: Duration = .seconds(60)

    private let recoveries: [String: Recovery]
    private var system: ClusterSystem?
    private var list: RunningList?
    /// How much kept work runs here now, for each actor.
    private var kept: [VirtualActorID: Int] = [:]
    /// The list's changes, one after another, each until the list has it.
    private var writing: Task<Void, Never>?
    private var recovering: Task<Void, Never>?

    /// Bringing back actors of the types `recovering` says how to.
    public init(recovering: [Recovery]) {
        recoveries = Dictionary(recovering.map { ($0.typeName, $0) }) { first, _ in first }
    }

    public func start(_ system: ClusterSystem) async throws {
        self.system = system
        list = try await system.singleton.host(RunningList.self, name: Self.singletonName) {
            try await RunningList(actorSystem: $0)
        }
    }

    public func stop(_ system: ClusterSystem) async {
        recovering?.cancel()
        recovering = nil
        self.system = nil
    }

    /// `work` of the actor `id`, of `type`, started with `dependency` and kept for `keptFor`, kept
    /// going: run now, and brought back with its actor after a restart. Its task, to cancel.
    public nonisolated func keep<Actor: VirtualActor, Dependency: Codable & Sendable, KeptFor: Codable & Sendable>(
        _ type: Actor.Type, id: VirtualActorID, dependency: Dependency, for keptFor: KeptFor,
        _ work: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let typeName = String(reflecting: type)
        let encoded = try? (dependency: JSONEncoder().encode(dependency), keptFor: JSONEncoder().encode(keptFor))
        return Task {
            await self.began(id, typeName: typeName, encoded)
            await work()
            await self.ended(id)
        }
    }

    /// The actors on the list brought back, each as its type's recovery says, in the background:
    /// those that can't be are tried again, later and later, until they can or they're off the list.
    public func recover() {
        guard self.recovering == nil, let system, let list else { return }
        let recoveries = recoveries
        self.recovering = Task {
            var wait: Duration = .seconds(1)
            while !Task.isCancelled {
                var failed = false
                for entry in (try? await list.entries()) ?? [] {
                    guard let recovery = recoveries[entry.typeName] else { continue }
                    do {
                        try await recovery.recover(entry, system)
                    } catch {
                        failed = true
                        system.log.warning(
                            "A running actor couldn't be brought back yet",
                            metadata: ["id": "\(entry.id)", "error": "\(error)"])
                    }
                }
                guard failed else { return }
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, Self.longestRetry)
            }
        }
    }

    private func began(_ id: VirtualActorID, typeName: String, _ encoded: (dependency: Data, keptFor: Data)?) {
        kept[id, default: 0] += 1
        guard kept[id] == 1, let encoded else { return }
        let entry = RunningEntry(
            id: id, typeName: typeName, dependency: encoded.dependency, keptFor: encoded.keptFor,
            keeper: Self.keeper(on: system))
        write { try await $0.started(entry) }
    }

    private func ended(_ id: VirtualActorID) {
        kept[id, default: 1] -= 1
        guard kept[id] == 0 else { return }
        kept[id] = nil
        // Its node shutting down isn't its work ending: it stays on the list, to come back.
        guard let system, !system.isTerminated else { return }
        let keeper = Self.keeper(on: system)
        write { try await $0.stopped(id, keptBy: keeper) }
    }

    /// The node keeping work here, as the list knows it: this run of it, which a node starting
    /// again is not.
    static func keeper(on system: ClusterSystem?) -> String {
        system.map { "\($0.cluster.node)" } ?? ""
    }

    /// `change` made to the list after those before it, tried again until the list has it.
    private func write(_ change: @escaping @Sendable (RunningList) async throws -> Void) {
        guard let list else { return }
        writing = Task { [before = writing] in
            await before?.value
            var wait: Duration = .milliseconds(100)
            while !Task.isCancelled {
                do {
                    try await change(list)
                    return
                } catch {
                    try? await Task.sleep(for: wait)
                    wait = min(wait * 2, Self.longestRetry)
                }
            }
        }
    }
}

extension ClusterSystem {
    /// The node's running actors.
    public var runningActors: RunningActors {
        guard let plugin = settings.plugins[RunningActors.pluginKey] else {
            fatalError("No plugin found for key: [\(RunningActors.pluginKey)], installed plugins: \(settings.plugins)")
        }
        return plugin
    }
}

/// One actor on the running list: its id, its type, what it's started with, and whom it was kept
/// for, encoded; and the run of the node keeping it, which alone takes it off.
public struct RunningEntry: Codable, Sendable, Hashable {
    public let id: VirtualActorID
    public let typeName: String
    public let dependency: Data
    public let keptFor: Data
    public let keeper: String
}

public enum RunningListEvent: Codable, Sendable {
    case started(RunningEntry)
    case stopped(VirtualActorID)
}

/// The actors running by themselves, one list in the cluster, kept in the journal.
@EventSourced
public distributed actor RunningList: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = RunningListEvent

    public struct State: Codable, Sendable {
        var entries: [VirtualActorID: RunningEntry] = [:]

        public init() {}
    }

    public var state = State()

    public init(actorSystem: ClusterSystem) async throws {
        self.actorSystem = actorSystem
        try await actorSystem.journal.register(actor: self, with: "running-actors")
    }

    distributed func started(_ entry: RunningEntry) async throws {
        guard state.entries[entry.id] != entry else { return }
        try await emit(event: .started(entry))
    }

    /// The actor `id` not running any more, as the node run `keeper` says: only the one keeping it
    /// now takes it off, so one that kept it before, on another node, can't.
    distributed func stopped(_ id: VirtualActorID, keptBy keeper: String) async throws {
        guard state.entries[id]?.keeper == keeper else { return }
        try await emit(event: .stopped(id))
    }

    distributed func entries() -> [RunningEntry] {
        Array(state.entries.values)
    }

    public func handleEvent(_ event: RunningListEvent) {
        switch event {
        case .started(let entry): state.entries[entry.id] = entry
        case .stopped(let id): state.entries[id] = nil
        }
    }
}
