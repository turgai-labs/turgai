import Distributed
import DistributedCluster
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Why a connection stopped by itself: its platform refused it, say. It's run again a while later.
public struct ConnectionStopped: Hashable, Codable, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension Space {
    /// Its connections, as `person`, who may configure them, sees them.
    public distributed func connections(for person: UserID) throws -> [Connection] {
        let space = try made()
        guard space.permissions(of: person)?.connections == true else { throw SpaceRefusal.notAllowed }
        return space.connections.values.sorted { $0.label.rawValue < $1.label.rawValue }
    }

    /// Tells its connection `id`'s run how it should run now: as it's set up, or to stop when
    /// it's off, removed, or the space isn't active.
    func tellRun(of id: ConnectionID) async throws {
        var wanted: Connection?
        if case .active(let space) = state, let connection = space.connections[id], connection.enabled {
            wanted = connection
        }
        try await ConnectionRun.of(id, in: state.id, on: actorSystem).set(wanted)
    }

    /// Tells each of its connections' runs how it should run now: all stop while it's archived.
    func tellRuns() async throws {
        for id in state.space.map({ Array($0.connections.keys) }) ?? [] { try await tellRun(of: id) }
    }

    /// Its connection `id`, as it's set up now: none once it's removed.
    public distributed func connection(_ id: ConnectionID) -> Connection? {
        state.space?.connections[id]
    }

    /// `connection` a way into it, as `person`, who may configure its connections, adds it: it runs
    /// from now on, while it's enabled.
    public distributed func addConnection(_ connection: Connection, by person: UserID) async throws {
        try await run(.addConnection(connection, by: person))
        try await tellRun(of: connection.id)
    }

    /// Its connection as `connection` says from now on, as `person`, who may configure them,
    /// changes it: run again as it is now.
    public distributed func changeConnection(_ connection: Connection, by person: UserID) async throws {
        try await run(.changeConnection(connection, by: person))
        try await tellRun(of: connection.id)
    }

    /// Its connection `id` removed, as `person`, who may configure them, asks: it stops.
    public distributed func removeConnection(_ id: ConnectionID, by person: UserID) async throws {
        try await run(.removeConnection(id, by: person))
        try await tellRun(of: id)
    }

}
