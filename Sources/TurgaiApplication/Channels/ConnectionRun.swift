import Distributed
import DistributedCluster
import EventSourcing
import RunningActors
import TurgaiDomain
import TurgaiSpaces
import VirtualActors

/// A space's connection running: a job of its own, apart from its space, whose facts say how it's
/// set up. It runs while its connection is added, enabled and its space active, reading them from
/// the space each time it starts; a run that stops by itself starts again a while later. Its node
/// keeps its run going, so a node starting brings it back.
@VirtualActor
public distributed actor ConnectionRun {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = Config

    /// Which connection, of which space.
    public struct Config: Codable, Hashable, Sendable {
        public let space: SpaceID
        public let connection: ConnectionID
    }

    /// How long a run that stopped by itself waits before it starts again.
    static let retry: Duration = .seconds(30)

    private let config: Config
    /// The connection as it runs now, and its run: none while it isn't running.
    private var running: (connection: Connection, task: Task<Void, Never>)?
    /// Why it last stopped by itself, until it runs again as set up anew.
    private var stopped: ConnectionStopped?

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.config = dependency
    }

    /// `connection` of `space`'s run, wherever and whenever it runs.
    public static func of(_ connection: ConnectionID, in space: SpaceID, on system: ClusterSystem) async throws
        -> ConnectionRun
    {
        try await system.virtualActors.getActor(
            identifiedBy: VirtualActorID(rawValue: "connection-run:\(space.rawValue.uuidString)/\(connection)"),
            dependency: Config(space: space, connection: connection))
    }

    /// It stays while it runs.
    public func shouldDeactivate() async -> Bool { running == nil }

    /// Its run ends with it: as its node shuts down, nothing goes on running a connection no one
    /// holds.
    deinit {
        running?.task.cancel()
    }

    /// Brought back after a restart, as it was running: its connection read again, and run.
    public distributed func recovered() async throws {
        try await refresh()
    }

    /// Its connection read again from its space: run as it's set up now, or stopped when it's off,
    /// removed, or its space isn't active.
    public distributed func refresh() async throws {
        let wanted = try await Space.identified(by: config.space, on: actorSystem).runnable(config.connection)
        guard wanted != running?.connection else { return }
        running?.task.cancel()
        running = nil
        stopped = nil
        if let wanted { running = (wanted, run(wanted)) }
    }

    /// Whether it's running, and why it last stopped by itself.
    public distributed var status: ConnectionStatus {
        ConnectionStatus(running: running != nil, stopped: stopped)
    }

    private static func actorID(_ config: Config) -> VirtualActorID {
        VirtualActorID(rawValue: "connection-run:\(config.space.rawValue.uuidString)/\(config.connection)")
    }

    /// `connection` run on its platform, and run again a while after it stops by itself, until
    /// it's cancelled: kept going by its node, so it comes back after a restart.
    private func run(_ connection: Connection) -> Task<Void, Never> {
        let space = config.space
        let system = actorSystem
        return actorSystem.runningActors.keep(
            ConnectionRun.self, id: Self.actorID(config), dependency: config, for: config
        ) { [weak self] in
            while !Task.isCancelled {
                let why =
                    switch connection.platform {
                    case .telegram(let access):
                        await TelegramConnections.run(connection, access: access, of: space, on: system)
                    }
                guard !Task.isCancelled else { return }
                await self?.whenLocal { $0.stopped = why }
                system.log.warning(
                    "A space's connection stopped", metadata: ["connection": "\(connection.id)", "why": "\(why)"])
                try? await Task.sleep(for: Self.retry)
            }
        }
    }
}

/// Whether a connection runs, and why it last stopped by itself.
public struct ConnectionStatus: Codable, Hashable, Sendable {
    public let running: Bool
    public let stopped: ConnectionStopped?

    public init(running: Bool, stopped: ConnectionStopped?) {
        self.running = running
        self.stopped = stopped
    }
}

/// Keeps each space's connections running as the space says: when one is added, changed or
/// removed, or its space is archived or made active again, that connection's run reads its facts
/// again. The space doesn't know its connections run; this follows what it decides. One in the
/// cluster, from where it read up to.
public distributed actor ConnectionPolicy: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    /// What the cluster knows it by.
    public static let singletonName = "turgai-connection-policy"

    private let offset: ProjectionOffset
    private let journal: any EventStore
    private let refreshInterval: Duration
    private var following: Task<Void, Never>?

    /// Following the spaces' events in `journal`, from where `offset` says it read up to, and again
    /// every `refreshInterval` once it's caught up.
    public init(
        actorSystem: ClusterSystem, offset: ProjectionOffset, journal: any EventStore,
        refreshInterval: Duration = .seconds(1)
    ) {
        self.actorSystem = actorSystem
        self.offset = offset
        self.journal = journal
        self.refreshInterval = refreshInterval
    }

    public func activateSingleton() async {
        let system = actorSystem
        let offset = offset
        following = Task {
            await Projection<SpaceEvent>(tag: .space).runRestarting(
                on: journal, refreshInterval: refreshInterval,
                offset: { try await offset.read() },
                process: { envelope in
                    let space = try Space.space(persistedAs: envelope.persistenceID)
                    for id in try await Self.connections(changedBy: envelope.event, in: space, on: system) {
                        try await ConnectionRun.of(id, in: space, on: system).refresh()
                    }
                    try await offset.keep(envelope.offset)
                },
                failed: { error in
                    system.log.error(
                        "The connection policy failed to follow the spaces' events; it starts again shortly",
                        metadata: ["error": .string(String(describing: error))])
                })
        }
    }

    public func passivateSingleton() async {
        following?.cancel()
        following = nil
    }

    /// The connections of `space` whose runs `event` changes: none for what doesn't touch them.
    private static func connections(changedBy event: SpaceEvent, in space: SpaceID, on system: ClusterSystem)
        async throws -> [ConnectionID]
    {
        switch event {
        case .connectionAdded(let connection), .connectionChanged(let connection): [connection.id]
        case .connectionRemoved(let id): [id]
        case .archived, .unarchived: try await Space.identified(by: space, on: system).connectionIDs()
        default: []
        }
    }
}
