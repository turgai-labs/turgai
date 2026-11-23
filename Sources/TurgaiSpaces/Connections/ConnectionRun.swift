import Distributed
import DistributedCluster
import Hail
import TurgaiDomain
import VirtualActors

/// A space's connection running: one of the space's own, which the space tells how its connection
/// should run each time that changes, as it starts, and to stop. A run that stops by itself starts
/// again a while later.
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
    /// How a file of one of its chats is got, while its platform serves it.
    private var fetch: Fetch?

    /// How a file of one of a connection's chats is got from its platform.
    public typealias Fetch = @Sendable (AttachmentID) async throws -> ToolData

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.config = dependency
    }

    /// `connection` of `space`'s run, wherever and whenever it runs.
    public static func of(_ connection: ConnectionID, in space: SpaceID, on system: ClusterSystem) async throws
        -> ConnectionRun
    {
        try await system.virtualActors.getActor(
            identifiedBy: .owned(by: space, "connection", connection.description),
            dependency: Config(space: space, connection: connection))
    }

    /// It stays while it runs.
    public func shouldDeactivate() async -> Bool { running == nil }

    /// Its run ends with it: as its node shuts down, nothing goes on running a connection no one
    /// holds.
    deinit {
        running?.task.cancel()
    }

    /// How its connection should run from now on, as its space says: run as `connection` is set
    /// up, or stopped when there's none, which its space says when it's off, removed, or the space
    /// isn't active. The same as it runs already changes nothing.
    public distributed func set(_ connection: Connection?) {
        guard connection != running?.connection else { return }
        running?.task.cancel()
        running = nil
        stopped = nil
        if let connection { running = (connection, run(connection)) }
    }

    /// Whether its chats' attachments can be got now: while its platform serves it.
    public distributed var servesAttachments: Bool { fetch != nil }

    /// The file `attachment` is, of a message in one of its chats, got from its platform.
    public distributed func attachment(_ attachment: AttachmentID) async throws -> ToolData {
        guard let fetch else { throw ConnectionNotServing() }
        return try await fetch(attachment)
    }

    /// Whether it's running, and why it last stopped by itself.
    public distributed var status: ConnectionStatus {
        ConnectionStatus(running: running != nil, stopped: stopped)
    }

    /// `connection` run on its platform, and run again a while after it stops by itself, until
    /// it's cancelled. Nothing keeps it across a restart: its space, started again, tells it how to
    /// run then.
    private func run(_ connection: Connection) -> Task<Void, Never> {
        let config = config
        let system = actorSystem
        // How its platform tells it how its chats' files are got, while it serves it.
        let serving: @Sendable (Fetch?) async -> Void = { [weak self] fetch in
            await self?.whenLocal { $0.fetch = fetch }
        }
        return Task { [weak self] in
            while !Task.isCancelled {
                let why =
                    switch connection.platform {
                    case .telegram(let access):
                        await TelegramConnections.run(
                            connection, access: access, of: config.space, on: system,
                            serving: serving)
                    }
                await serving(nil)
                guard !Task.isCancelled else { return }
                await self?.whenLocal { $0.stopped = why }
                system.log.warning(
                    "A space's connection stopped", metadata: ["connection": "\(connection.id)", "why": "\(why)"])
                try? await Task.sleep(for: Self.retry)
            }
        }
    }
}

/// A connection's platform isn't serving it now, so its chats' files can't be got.
public struct ConnectionNotServing: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String { "this chat's bot isn't running" }
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
