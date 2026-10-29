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

public struct TelegramChannelConfig: Codable, Hashable, Sendable {
    public var chatIDs: [Int64]

    public init(chatIDs: [Int64] = []) {
        self.chatIDs = chatIDs
    }
}

public enum ChannelAgentRouting: Codable, Hashable, Sendable {
    case defaultProfile
    case profile(String)

    public var profileID: String? {
        switch self {
        case .defaultProfile: nil
        case .profile(let id): id
        }
    }
}

public enum TurgaiChannelError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidToken
    case unknownChannel(UUID)
}

/// What a channel is of: its provider's configuration, the state it keeps, and the events that
/// change it. What runs a channel's chats is the provider's service on the node, never the channel.
public protocol ChannelProvider: Sendable {
    associatedtype Configuration: Codable & Sendable & Equatable & Hashable
    associatedtype State: Codable & Sendable & Equatable & Hashable
    associatedtype Event: Codable & Sendable & Equatable & Hashable

    static var providerID: String { get }
    static func initialState(configuration: Configuration) -> State
    static func apply(_ event: Event, to state: inout State)
}

public struct ChannelConfiguration<Provider: ChannelProvider>:
    Codable, Identifiable, Hashable, Sendable
{
    public let id: UUID
    public var label: String
    public var enabled: Bool
    public var agentRouting: ChannelAgentRouting
    public var provider: Provider.Configuration

    public init(
        id: UUID,
        label: String,
        enabled: Bool,
        agentRouting: ChannelAgentRouting,
        provider: Provider.Configuration
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.agentRouting = agentRouting
        self.provider = provider
    }

}

public enum ChannelState<Provider: ChannelProvider>: Codable, Sendable, Equatable {
    case uninitialized
    case active(ChannelConfiguration<Provider>, Provider.State)
    case deleted(ChannelConfiguration<Provider>, Provider.State)
}

/// What a channel's provider did, as a call to the channel takes it: in a type of the channel's
/// own generic parameter, since a distributed call can't take an associated type itself
/// (swift#74769).
public struct ProviderEvent<Provider: ChannelProvider>: Codable, Sendable, Equatable {
    public let event: Provider.Event

    public init(_ event: Provider.Event) {
        self.event = event
    }
}

public enum ChannelEvent<Provider: ChannelProvider>: Codable, Sendable, Equatable {
    case created(ChannelConfiguration<Provider>)
    case configurationChanged(ChannelConfiguration<Provider>)
    case provider(Provider.Event)
    case deleted
}

public enum TelegramCursor: Codable, Sendable, Equatable, Hashable {
    case beginning
    case after(Int64)

    public var offset: Int64? {
        guard case .after(let value) = self else { return nil }
        return value
    }
}

public enum TelegramChannelEvent: Codable, Sendable, Equatable, Hashable {
    case cursorAdvanced(Int64)
}

public struct TelegramChannelState: Codable, Sendable, Equatable, Hashable {
    public var cursor: TelegramCursor

    public init(cursor: TelegramCursor = .beginning) {
        self.cursor = cursor
    }
}

public enum TelegramProvider: ChannelProvider {
    public typealias Configuration = TelegramChannelConfig
    public typealias State = TelegramChannelState
    public typealias Event = TelegramChannelEvent

    public static let providerID = "telegram"

    public static func initialState(configuration: Configuration) -> State {
        TelegramChannelState()
    }

    public static func apply(_ event: Event, to state: inout State) {
        switch event {
        case .cursorAdvanced(let offset):
            state.cursor = .after(offset)
        }
    }

}

public typealias TelegramChannel = Channel<TelegramProvider>

public enum ChannelActorError: Error, Codable, Sendable, Equatable {
    case channelIDMismatch
    case invalidLabel
    case deleted
    case notActive
}

/// A channel: its configuration and its provider's state, journaled. It runs nothing itself:
/// its provider's service reads it and tells it what it's done, and each message activates it.
@EventSourced
@VirtualActor
public distributed actor Channel<Provider: ChannelProvider> {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = ChannelEvent<Provider>
    public typealias State = ChannelState<Provider>
    public typealias Dependency = Config

    public enum Config: Codable, Sendable {
        case create(ChannelConfiguration<Provider>)
        case existing(UUID)
    }

    public var state: ChannelState<Provider>

    public let snapshotting: Snapshotting<ChannelEvent<Provider>, ChannelState<Provider>> = .every(
        numberOfEvents: 25,
        retention: .keepLast(2)
    )

    private let channelID: UUID

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        let channelID: UUID
        switch dependency {
        case .create(let requested):
            channelID = requested.id
        case .existing(let id):
            channelID = id
        }
        self.channelID = channelID
        self.state = .uninitialized
        try await actorSystem.journal.register(
            actor: self,
            with: Self.persistenceID(for: channelID)
        )
    }

    public static func actorID(for channelID: UUID) -> VirtualActorID {
        VirtualActorID(rawValue: "channel:\(Provider.providerID):\(channelID.uuidString)")
    }

    public static var persistencePrefix: String {
        "turgai-channel-\(Provider.providerID)-"
    }

    public static func persistenceID(for channelID: UUID) -> PersistenceID {
        "\(persistencePrefix)\(channelID.uuidString)"
    }

    public static func channelID(from persistenceID: String) -> UUID? {
        guard persistenceID.hasPrefix(persistencePrefix) else { return nil }
        return UUID(
            uuidString: String(persistenceID.dropFirst(persistencePrefix.count))
        )
    }

    public static func resolve(
        on actorSystem: ClusterSystem,
        configuration: ChannelConfiguration<Provider>
    ) async throws -> Self {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: configuration.id),
            dependency: Config.create(configuration)
        )
    }

    /// Resolves a channel actor by identity. If no journal exists, the actor
    /// starts uninitialized; an existing actor recovers its event-sourced
    /// configuration.
    public static func resolve(
        on actorSystem: ClusterSystem,
        channelID: UUID
    ) async throws -> Self {
        return try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: channelID),
            dependency: Config.existing(channelID)
        )
    }

    public distributed func currentState() -> ChannelState<Provider> {
        state
    }

    public distributed func replaceConfiguration(_ configuration: ChannelConfiguration<Provider>) async throws {
        guard configuration.id == channelID else {
            throw ChannelActorError.channelIDMismatch
        }
        var accepted = configuration
        accepted.label = try Self.validatedLabel(configuration.label)
        switch state {
        case .uninitialized:
            try await emit(event: .created(accepted))
        case .active(let existing, _):
            guard existing != accepted else { return }
            try await emit(event: .configurationChanged(accepted))
        case .deleted:
            throw ChannelActorError.deleted
        }
    }

    public distributed func emitProviderEvent(_ event: ProviderEvent<Provider>) async throws {
        guard case .active = state else {
            throw ChannelActorError.notActive
        }
        try await emit(event: .provider(event.event))
    }

    public distributed func delete() async throws {
        switch state {
        case .uninitialized:
            throw ChannelActorError.notActive
        case .active:
            try await emit(event: .deleted)
        case .deleted:
            return
        }
    }

    private static func validatedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmed()
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw ChannelActorError.invalidLabel
        }
        return trimmed
    }

    public func handleEvent(_ event: ChannelEvent<Provider>) {
        switch event {
        case .created(let configuration):
            state = .active(
                configuration,
                Provider.initialState(configuration: configuration.provider)
            )
        case .configurationChanged(let configuration):
            guard case .active(_, let providerState) = state else { return }
            state = .active(configuration, providerState)
        case .provider(let providerEvent):
            guard case .active(let configuration, var providerState) = state else { return }
            Provider.apply(providerEvent, to: &providerState)
            state = .active(configuration, providerState)
        case .deleted:
            guard case .active(var configuration, let providerState) = state else { return }
            configuration.enabled = false
            state = .deleted(configuration, providerState)
        }
    }
}
