import Distributed
import DistributedCluster
import EventSourcing
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// How far a Telegram connection has read its bot's updates: Telegram's offset after the last one
/// it took.
public enum TelegramOffset: Codable, Sendable, Equatable, Hashable {
    case beginning
    case after(Int64)

    /// The offset to read from next: none from the beginning.
    public var next: Int64? {
        guard case .after(let offset) = self else { return nil }
        return offset
    }
}

/// That a Telegram connection read its bot's updates up to `offset`.
public struct TelegramOffsetAdvanced: Codable, Sendable, Equatable {
    public let offset: Int64
}

/// Where a space's Telegram connection keeps how far it has read, so a restart reads on from there:
/// its connection's, scoped by its space.
@EventSourced
@VirtualActor
public distributed actor TelegramCursor {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = TelegramOffsetAdvanced
    public typealias State = TelegramOffset
    public typealias Dependency = Address

    /// Whose cursor it is: a connection of a space.
    public struct Address: Codable, Sendable, Hashable {
        public let space: SpaceID
        public let connection: ConnectionID
    }

    public var state: TelegramOffset = .beginning

    public let snapshotting: Snapshotting<TelegramOffsetAdvanced, TelegramOffset> = .every(
        numberOfEvents: 100, retention: .keepLast(1))

    public init(actorSystem: ClusterSystem, dependency address: Address) async throws {
        self.actorSystem = actorSystem
        try await actorSystem.journal.register(
            actor: self,
            with: "turgai-telegram-cursor-\(address.space.rawValue.uuidString)/\(address.connection)")
    }

    /// The cursor of `connection`, one of `space`'s.
    public static func identified(by connection: ConnectionID, of space: SpaceID, on actorSystem: ClusterSystem)
        async throws -> TelegramCursor
    {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: VirtualActorID(
                "cursor", "telegram", in: .owned(by: space, "connection", connection.description)),
            dependency: Address(space: space, connection: connection))
    }

    /// How far it has read.
    public distributed func offset() -> TelegramOffset {
        state
    }

    /// Read up to `offset`: nothing changes when it's read that far already.
    public distributed func advance(to offset: Int64) async throws {
        if case .after(let current) = state, current >= offset { return }
        try await emit(event: TelegramOffsetAdvanced(offset: offset))
    }

    public func handleEvent(_ event: TelegramOffsetAdvanced) {
        state = .after(event.offset)
    }
}
